import AppKit
import CoreServices
import CoreText

// MARK: - Session state model (written by hooks/ccglance-hook.js)

struct AgentTask: Codable {
    var id: String?          // tool_use_id (correlation key; must survive re-encoding)
    var description: String?
    var type: String?       // subagent_type ("Explore", "general-purpose", …)
    var startedAt: Double?
}

struct PRInfo: Codable {
    var number: Int?
    var state: String?    // "OPEN" | "MERGED" | "CLOSED"
    var isDraft: Bool?
    var url: String?
    var checkedAt: Double?
}

struct HostInfo: Codable {
    var bundleId: String?        // __CFBundleIdentifier of the GUI ancestor
    var termProgram: String?     // TERM_PROGRAM ("Apple_Terminal" | "iTerm.app" | "vscode" | "tmux" | …)
    var itermSessionId: String?  // ITERM_SESSION_ID ("w0t2p0:<UUID>")
    var tty: String?             // "/dev/ttysNNN" (captured for Terminal.app only)
}

struct SessionState: Codable {
    var sessionId: String
    var project: String?
    var title: String?      // session name from the transcript (editable in Claude Desktop)
    var cwd: String?
    var status: String        // "thinking" | "tool" | "permission" | "idle"
    var tool: String?
    var message: String?
    var turnStartedAt: Double?
    var createdAt: Double?   // set once at SessionStart (optional: older files lack it)
    var updatedAt: Double
    var agents: [AgentTask]?  // running subagents (optional: older files lack it)
    var pr: PRInfo?           // fetched via gh by the hook's --fetch-pr mode
    var host: HostInfo?       // jump-to-session target (optional: older files lack it)
}

enum StateStore {
    static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ccglance/sessions", isDirectory: true)
    }

    /// Load all session files. Prunes files not updated for 12h (crashed sessions).
    static func load() -> [SessionState] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        let now = Date().timeIntervalSince1970
        var result: [SessionState] = []
        for url in files {
            guard url.pathExtension == "json" else {
                // .lock/.tmp residue from hook processes killed mid-write; live
                // ones never survive more than seconds, so an hour is safe
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantFuture
                if now - mtime.timeIntervalSince1970 > 3600 {
                    try? fm.removeItem(at: url)
                }
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let state = try? JSONDecoder().decode(SessionState.self, from: data) else { continue }
            if now - state.updatedAt > 12 * 3600 {
                try? fm.removeItem(at: url)
                continue
            }
            result.append(state)
        }
        // Active sessions first, then by project name
        return result.sorted {
            let a = $0.status != "idle", b = $1.status != "idle"
            if a != b { return a }
            return ($0.project ?? "") < ($1.project ?? "")
        }
    }

    /// Look up the Desktop-app session titles (editable in Claude Desktop) for
    /// a set of CLI session ids in a single store walk. Store layout:
    ///   ~/Library/Application Support/Claude/claude-code-sessions/<ws>/<x>/local_<id>.json
    ///   { "title": ..., "cliSessionId": ..., "bridgeSessionIds": [...] }
    static var desktopStoreDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// Parse one Desktop store file into the session ids it maps and its title.
    private static func parseStoreFile(_ url: URL) -> (ids: [String], title: String)? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["title"] as? String else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var ids: [String] = []
        for key in ["cliSessionId", "sessionId", "id"] {
            if let v = obj[key] as? String { ids.append(v) }
        }
        if let bridged = obj["bridgeSessionIds"] as? [String] { ids += bridged }
        return ids.isEmpty ? nil : (ids, title)
    }

    static func desktopTitles(for sessionIds: Set<String>) -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: desktopStoreDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var best: [String: (title: String, mtime: Date)] = [:]
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard let (ids, title) = parseStoreFile(url) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            for id in ids where sessionIds.contains(id) {
                if best[id] == nil || mtime > best[id]!.mtime {
                    best[id] = (title, mtime)
                }
            }
        }
        return best.mapValues { $0.title }
    }

    /// Re-resolve titles and persist them into the state files (hooks preserve
    /// the field afterwards). Pass `only` to restrict to specific session ids.
    static func refreshTitles(only: Set<String>? = nil) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return }
        // State files are named <session_id>.json, so ids resolve without decoding
        var targets = Set(files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent })
        if let only { targets.formIntersection(only) }
        guard !targets.isEmpty else { return }
        persist(titles: desktopTitles(for: targets))
    }

    /// Re-resolve titles for the sessions referenced by specific store files
    /// (FSEvents-changed paths). Delegates to refreshTitles so the store-wide
    /// mtime-newest rule decides, exactly like the hook does — a touched stale
    /// file must not win over a fresher one just because it was touched.
    /// refreshTitles intersects with tracked sessions and returns early when
    /// none match, so changes to untracked sessions cost only the parse here.
    static func applyTitles(fromStoreFiles urls: [URL]) {
        var ids = Set<String>()
        for url in urls {
            guard let (fileIds, _) = parseStoreFile(url) else { continue }
            ids.formUnion(fileIds)
        }
        guard !ids.isEmpty else { return }
        refreshTitles(only: ids)
    }

    private static func persist(titles: [String: String]) {
        guard !titles.isEmpty else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "json" {
            guard let title = titles[url.deletingPathExtension().lastPathComponent] else { continue }
            // Read right before writing: resolving titles takes a while and
            // hooks may have rewritten (or removed) the file meanwhile — merge
            // only the title into the freshest state to keep the race window tiny
            guard let data = try? Data(contentsOf: url),
                  var state = try? JSONDecoder().decode(SessionState.self, from: data),
                  state.title != title else { continue }
            state.title = title
            if let out = try? JSONEncoder().encode(state) {
                try? out.write(to: url, options: .atomic)
            }
        }
    }

    static func clearIdle() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let state = try? JSONDecoder().decode(SessionState.self, from: data),
               state.status == "idle" {
                try? fm.removeItem(at: url)
            }
        }
    }
}

// MARK: - Desktop store watcher

/// Watches the Claude Desktop session store with FSEvents so renames made in
/// the Desktop app land on the panel immediately, without waiting for the next
/// hook turn boundary. Event-driven: zero cost while nothing changes. The
/// untitled-session poll in AppDelegate stays as a fallback for dropped events.
final class TitleStoreWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "ccglance.title-watcher", qos: .utility)

    func start() {
        guard stream == nil else { return }
        // The context retains self so an in-flight callback can never race a
        // deallocation; the stream holds the watcher alive until stop()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<TitleStoreWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<TitleStoreWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<TitleStoreWatcher>.fromOpaque(info).takeUnretainedValue()
            var mustRescan = false
            for i in 0..<count where flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                mustRescan = true
            }
            // paths is a CFArray of CFString (kFSEventStreamCreateFlagUseCFTypes)
            let all = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handle(paths: all, mustRescan: mustRescan)
        }
        // 0.5s latency coalesces edit bursts into one callback
        guard let s = FSEventStreamCreate(
            nil, callback, &context,
            [StateStore.desktopStoreDir.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return
        }
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func handle(paths: [String], mustRescan: Bool) {
        if mustRescan {
            // Kernel dropped events — fall back to the full store walk
            StateStore.refreshTitles()
            return
        }
        let changed = paths.filter { $0.hasSuffix(".json") }.map { URL(fileURLWithPath: $0) }
        if !changed.isEmpty {
            StateStore.applyTitles(fromStoreFiles: changed)
        }
    }
}

// MARK: - Theme

enum Theme {
    static let orange = NSColor(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
    static let yellow = NSColor(red: 0xE8 / 255.0, green: 0xC4 / 255.0, blue: 0x4A / 255.0, alpha: 1)
    static let idle = NSColor.tertiaryLabelColor
    static let sparkFrames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

    // PR state colors matching GitHub's dark palette (the panel appearance
    // is pinned to darkAqua in buildPanel, so no light variants are needed)
    static let prOpen = hex(0x3FB950)
    static let prMerged = hex(0xA371F7)
    static let prClosed = hex(0xF85149)
    static let prDraft = NSColor.tertiaryLabelColor

    // Font Awesome 6 Free Solid glyphs (font bundled in Resources)
    static let faPullRequest = "\u{E13C}"   // code-pull-request
    static let faMerge = "\u{F387}"         // code-merge
    static func faFont(size: CGFloat) -> NSFont? {
        NSFont(name: "FontAwesome6Free-Solid", size: size)
    }

    private static func hex(_ rgb: Int) -> NSColor {
        NSColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1
        )
    }
}

// MARK: - Jump to session host
//
// The hook records which GUI app hosts each session (bundle id, tty, iTerm
// session id). The row's hover button resolves that into the most precise jump
// available: exact Terminal.app/iTerm2 tab via AppleScript, the cwd's window
// for VS Code-family editors, or plain app activation for everything else.

enum JumpTarget {
    case terminalTab(tty: String)                        // Terminal.app: select tab by tty
    case itermSession(uuid: String)                      // iTerm2: select session by id
    case editorWorkspace(bundleId: String, cwd: String)  // VS Code family: refocus the cwd window
    case claudeSession(sessionId: String)                // Claude Desktop: open the exact session
    case app(bundleId: String)                           // any other GUI host

    init?(session: SessionState) {
        guard let host = session.host else { return nil }
        // Under tmux the recorded tty belongs to the tmux pane, not a terminal
        // tab, so tab matching can never work — activate the app at best.
        if host.termProgram == "tmux" {
            guard let b = host.bundleId else { return nil }
            self = .app(bundleId: b)
            return
        }
        if host.bundleId == "com.apple.Terminal", let tty = host.tty {
            self = .terminalTab(tty: tty)
            return
        }
        if host.bundleId == "com.googlecode.iterm2", let raw = host.itermSessionId {
            // ITERM_SESSION_ID is "w0t2p0:<UUID>"; AppleScript's session id is the UUID
            let uuid = raw.split(separator: ":").last.map(String.init) ?? raw
            self = .itermSession(uuid: uuid)
            return
        }
        if host.termProgram == "vscode", let b = host.bundleId, let cwd = session.cwd {
            self = .editorWorkspace(bundleId: b, cwd: cwd)
            return
        }
        if host.bundleId == HostJumper.claudeDesktopBundleId {
            self = .claudeSession(sessionId: session.sessionId)
            return
        }
        guard let b = host.bundleId else { return nil }  // ssh / CLI-launched: no target
        self = .app(bundleId: b)
    }

    /// Hover-button label, e.g. "Open in Claude Desktop".
    var buttonTitle: String {
        "Open in " + appName
    }

    private var appName: String {
        switch self {
        case .terminalTab: return "Terminal"
        case .itermSession: return "iTerm2"
        case .claudeSession: return "Claude Desktop"
        case .editorWorkspace(let bundleId, _), .app(let bundleId):
            return Self.appName(forBundleId: bundleId)
        }
    }

    // Cached: rows recompute their target every 0.1s tick, and the
    // NSWorkspace lookup for unknown bundle ids hits the disk.
    private static var appNameCache: [String: String] = [:]

    private static func appName(forBundleId bundleId: String) -> String {
        if let cached = appNameCache[bundleId] { return cached }
        let name: String
        switch bundleId {
        case "com.apple.Terminal": name = "Terminal"
        case "com.googlecode.iterm2": name = "iTerm2"
        case "com.microsoft.VSCode": name = "VS Code"
        case "com.anthropic.claudefordesktop": name = "Claude Desktop"
        default:
            // Resolve e.g. Cursor/Ghostty from the app bundle on disk;
            // fall back to the last bundle-id component.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                name = url.deletingPathExtension().lastPathComponent
            } else {
                name = bundleId.split(separator: ".").last.map(String.init) ?? bundleId
            }
        }
        appNameCache[bundleId] = name
        return name
    }
}

enum HostJumper {
    /// Serial so repeated clicks while the first-run automation consent dialog
    /// blocks an osascript child queue up instead of parking extra threads.
    private static let queue = DispatchQueue(label: "ccglance.jump", qos: .userInitiated)

    /// AppleScript can take 100ms+ (and the first-run automation consent
    /// dialog blocks the osascript child until answered) — never on main.
    static func jump(to target: JumpTarget) {
        queue.async {
            switch target {
            case .terminalTab(let tty):
                jumpScript(bundleId: "com.apple.Terminal", value: tty, script: """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected tab of w to t
                                set index of w to 1
                            end if
                        end repeat
                    end repeat
                end tell
                """)
            case .itermSession(let uuid):
                jumpScript(bundleId: "com.googlecode.iterm2", value: uuid, script: """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if id of s is "\(uuid)" then
                                    select s
                                    select t
                                    select w
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """)
            case .editorWorkspace(let bundleId, let cwd):
                openWorkspace(bundleId: bundleId, cwd: cwd)
            case .claudeSession(let sessionId):
                openClaudeSession(sessionId: sessionId)
            case .app(let bundleId):
                activate(bundleId: bundleId)
            }
        }
    }

    static let claudeDesktopBundleId = "com.anthropic.claudefordesktop"

    /// Claude Desktop keeps every session inside one window, so activation
    /// alone is a no-op when the app is already frontmost. Navigate to the
    /// existing desktop session; claude://resume is only a fallback because
    /// it imports a fresh untitled copy ("General coding session") instead
    /// of focusing the session the user is already running.
    private static func openClaudeSession(sessionId: String) {
        guard isRunning(claudeDesktopBundleId) else { return }
        if sessionId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
            let link: String
            if let desktopId = desktopSessionId(forCliSessionId: sessionId) {
                link = "claude://claude.ai/claude-code-desktop/\(desktopId)"
            } else {
                link = "claude://resume?session=\(sessionId)"
            }
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }
        activate(bundleId: claudeDesktopBundleId)
    }

    /// Claude Desktop persists one JSON record per session under Application
    /// Support; each stores the CLI session id it wraps. Runs on the jump
    /// queue, only on click.
    private static func desktopSessionId(forCliSessionId cliId: String) -> String? {
        let root = ("~/Library/Application Support/Claude/claude-code-sessions" as NSString)
            .expandingTildeInPath
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return nil }
        var best: (id: String, score: Int, activity: Double)?
        for case let relPath as String in enumerator {
            guard relPath.hasSuffix(".json"),
                  let data = FileManager.default.contents(atPath: root + "/" + relPath),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  record["cliSessionId"] as? String == cliId,
                  let id = record["sessionId"] as? String,
                  id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
            else { continue }
            // Prefer the native session over an untitled resume-import copy
            // (whose id is always local_<cliId>), then unarchived, then the
            // most recently active.
            var score = 0
            if id != "local_\(cliId)" { score += 2 }
            if (record["isArchived"] as? Bool) != true { score += 1 }
            let activity = (record["lastActivityAt"] as? Double) ?? 0
            if best == nil || (score, activity) > (best!.score, best!.activity) {
                best = (id, score, activity)
            }
        }
        return best?.id
    }

    /// Runs the tab-selection script, then activates the app regardless of the
    /// outcome — a closed tab or a denied automation prompt still front the app.
    /// Never launches an app that has quit since the session started.
    private static func jumpScript(bundleId: String, value: String, script: String) {
        guard isRunning(bundleId) else { return }
        // Values come from our own hook, but they are interpolated into
        // AppleScript source — allowlist them so a corrupted state file
        // cannot inject script.
        if value.range(of: "^[A-Za-z0-9/_.:-]+$", options: .regularExpression) != nil {
            runOSAScript(script)
        }
        activate(bundleId: bundleId)
    }

    private static func openWorkspace(bundleId: String, cwd: String) {
        guard isRunning(bundleId) else { return }  // never launch an app that has quit
        // An already-open folder window is reused and focused; otherwise the
        // editor opens it. Same out-of-process reasoning as activate().
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", bundleId, cwd]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            activate(bundleId: bundleId)
            return
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 { activate(bundleId: bundleId) }
    }

    /// Needs no automation permission — the universal fallback. Plain
    /// NSWorkspace/NSRunningApplication activation requests from this app are
    /// ignored by cooperative activation (the non-activating .accessory panel
    /// is never the active app), but explicitly yielding our activation claim
    /// to the target first makes its activate() honored.
    private static func activate(bundleId: String) {
        DispatchQueue.main.async {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return }
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: app)
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    /// osascript child rather than NSAppleScript: NSAppleScript is main-thread
    /// bound, so the first-run consent dialog would freeze the panel. TCC
    /// attributes the child to ccglance (responsible process), so the app's
    /// usage description and consent entry apply.
    private static func runOSAScript(_ script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        p.waitUntilExit()
    }
}

enum CrabState {
    case working, permission, idle
}

// MARK: - Clawd (Claude Code crab mascot) — real frames from Clawd-CrabWalking.gif
// Frames come from m1ckc3s/claude-status-bar (MIT), see Sources/CrabFrames.swift.

final class ClawdView: NSView {
    static let topMargin: CGFloat = 30    // margin above the crab
    static let bottomMargin: CGFloat = 30 // margin below the crab

    private static let frames: [NSImage] = clawdCrabFramePNGs.compactMap {
        guard let data = Data(base64Encoded: $0) else { return nil }
        return NSImage(data: data)
    }

    var state: CrabState = .idle
    var frameIndex: Int = 0

    static var displaySize: NSSize {
        frames.first?.size ?? NSSize(width: 51, height: 36)
    }

    override var intrinsicContentSize: NSSize {
        var s = Self.displaySize
        s.height += 4 // headroom for the permission bounce
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !Self.frames.isEmpty else { return }
        let image: NSImage
        let alpha: CGFloat
        var yOffset: CGFloat = 0

        switch state {
        case .working:
            image = Self.frames[frameIndex % Self.frames.count]
            alpha = 1.0
        case .permission:
            image = Self.frames[frameIndex % Self.frames.count]
            alpha = 1.0
            yOffset = frameIndex % 2 == 0 ? 0 : 3 // bounce while waiting
        case .idle:
            image = Self.frames[0]
            alpha = 1.0   // opaque — the translucent idle crab read as "see-through"
        }

        let size = Self.displaySize
        let x = (bounds.width - size.width) / 2
        image.draw(
            in: NSRect(x: x, y: yOffset, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: alpha
        )
    }
}

// MARK: - Project group header

final class GroupHeaderView: NSView {
    static let height: CGFloat = 24

    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            // Bottom-aligned: the space above doubles as the gap between groups
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Jump button: accepts the first click even though the panel is never key,
/// and is recognized by RootView's cursor tracking to show a pointing hand.
final class HoverButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Session row view (table-style)

final class SessionRowView: NSView {
    static let height: CGFloat = 28

    let glyph = NSTextField(labelWithString: "")
    let projectLabel = NSTextField(labelWithString: "")
    let rightLabel = NSTextField(labelWithString: "")   // elapsed time if available, otherwise status name
    private let highlight = NSView()
    private let separator = NSBox()
    private let jumpButton = HoverButton()
    private var jumpTarget: JumpTarget?
    private var jumpTitle = ""
    private var hovering = false
    // Active only while the button shows: the text button is usually wider
    // than the right label, so the title must yield to it — but only then,
    // or the hidden button's width would squeeze titles permanently.
    private var titleClearsButton: NSLayoutConstraint?

    /// Separator drawn only between rows (hidden on the last row)
    var showsSeparator: Bool = true {
        didSet { separator.isHidden = !showsSeparator }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 4
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        glyph.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        glyph.alignment = .center
        projectLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        projectLabel.lineBreakMode = .byTruncatingTail
        rightLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        rightLabel.alignment = .right

        // Long session names must truncate with an ellipsis, never push the
        // right column: the name compresses first, the time/status never does.
        projectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        rightLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        for v in [glyph, projectLabel, rightLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),

            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),

            // [icon][project] ......... [time or status name]
            projectLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            projectLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            projectLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightLabel.leadingAnchor, constant: -8),

            rightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Hover-revealed jump button ("Open in <app>"). It swaps in for the
        // right label (same slot), so the row keeps its fixed height; the
        // session title truncates first, the button text never does.
        jumpButton.isBordered = false
        jumpButton.refusesFirstResponder = true
        jumpButton.toolTip = "Jump to this session's window"
        jumpButton.target = self
        jumpButton.action = #selector(jumpClicked)
        jumpButton.isHidden = true
        jumpButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        jumpButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(jumpButton)
        NSLayoutConstraint.activate([
            jumpButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            jumpButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        titleClearsButton = projectLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: jumpButton.leadingAnchor, constant: -8)

        // .inVisibleRect keeps the area glued to the row across resizes (no
        // updateTrackingAreas needed); .activeAlways is required because the
        // panel is non-activating and never the key window.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshHoverUI()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshHoverUI()
    }

    private func refreshHoverUI() {
        let show = hovering && jumpTarget != nil
        jumpButton.isHidden = !show
        rightLabel.isHidden = show
        titleClearsButton?.isActive = show
    }

    @objc private func jumpClicked() {
        guard let target = jumpTarget else { return }
        HostJumper.jump(to: target)
    }

    func update(_ s: SessionState, sparkIndex: Int, now: TimeInterval) {
        // Rows are reused and re-mapped positionally each tick, so the jump
        // target must track whichever session is currently displayed here.
        jumpTarget = JumpTarget(session: s)
        let title = jumpTarget?.buttonTitle ?? ""
        if title != jumpTitle {
            jumpTitle = title
            jumpButton.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: Theme.orange,
            ])
        }
        refreshHoverUI()
        // The project name lives in the group header; the row shows the
        // session title (editable in Claude Desktop). While the title is
        // still being generated (fresh session) show a placeholder instead
        // of the raw id; fall back to the id once the grace period passes.
        let name: String
        if s.title?.isEmpty == false {
            name = s.title!
        } else if let created = s.createdAt, now - created < 30 {
            name = "New session…"
        } else {
            name = "Session " + String(s.sessionId.prefix(8))
        }
        projectLabel.stringValue = name

        func elapsedString() -> String {
            guard let start = s.turnStartedAt else { return "" }
            let sec = max(0, Int(now - start))
            return sec >= 60 ? "\(sec / 60)m \(sec % 60)s" : "\(sec)s"
        }

        switch s.status {
        case "thinking", "tool":
            setGlyph(font: Self.systemGlyphFont, tooltip: nil)
            glyph.stringValue = Theme.sparkFrames[sparkIndex % Theme.sparkFrames.count]
            glyph.textColor = Theme.orange
            // Elapsed time when available; fall back to status name when it isn't
            let elapsed = elapsedString()
            if elapsed.isEmpty {
                rightLabel.stringValue = s.status == "thinking" ? "Thinking…" : (s.tool ?? "Using tool")
            } else {
                rightLabel.stringValue = elapsed
            }
            rightLabel.textColor = .labelColor
            highlight.layer?.backgroundColor = nil
        case "permission":
            setGlyph(font: Self.systemGlyphFont, tooltip: nil)
            glyph.stringValue = "●"
            glyph.textColor = Theme.yellow
            rightLabel.stringValue = "Waiting"
            rightLabel.textColor = Theme.yellow
            let pulse = 0.10 + 0.10 * (0.5 + 0.5 * sin(now * 4))
            highlight.layer?.backgroundColor = Theme.yellow.withAlphaComponent(pulse).cgColor
        default: // idle
            if let pr = prGlyph(for: s), let faFont = Self.faGlyphFont {
                setGlyph(font: faFont, tooltip: pr.tooltip)
                glyph.stringValue = pr.icon
                glyph.textColor = pr.color
            } else {
                setGlyph(font: Self.systemGlyphFont, tooltip: nil)
                glyph.stringValue = "●"
                glyph.textColor = Theme.idle
            }
            rightLabel.stringValue = "Idle"
            rightLabel.textColor = .tertiaryLabelColor
            highlight.layer?.backgroundColor = nil
        }
    }

    // The glyph font switches between the system font (dot/spark) and Font
    // Awesome (PR icon while idle). Fonts are resolved once — the FA lookup
    // runs after registration at launch — and reassigned only on change:
    // this runs on the 0.1s tick, and font/toolTip setters don't short-circuit.
    private static let systemGlyphFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let faGlyphFont = Theme.faFont(size: 11)

    private func setGlyph(font: NSFont, tooltip: String?) {
        if glyph.font != font { glyph.font = font }
        if glyph.toolTip != tooltip { glyph.toolTip = tooltip }
    }

    /// Icon, color and tooltip for the session's PR state; nil falls back to
    /// the plain idle dot (no PR / unknown state).
    private func prGlyph(for s: SessionState) -> (icon: String, color: NSColor, tooltip: String)? {
        guard let pr = s.pr, let state = pr.state else { return nil }
        let icon: String
        let color: NSColor
        let label: String
        switch state {
        case "OPEN" where pr.isDraft == true:
            (icon, color, label) = (Theme.faPullRequest, Theme.prDraft, "draft")
        case "OPEN":
            (icon, color, label) = (Theme.faPullRequest, Theme.prOpen, "open")
        case "MERGED":
            (icon, color, label) = (Theme.faMerge, Theme.prMerged, "merged")
        case "CLOSED":
            (icon, color, label) = (Theme.faPullRequest, Theme.prClosed, "closed")
        default:
            return nil
        }
        let number = pr.number.map { "PR #\($0)" } ?? "PR"
        return (icon, color, "\(number) · \(label)")
    }
}

// MARK: - Agent row view (running subagent, indented under its session row)

final class AgentRowView: NSView {
    static let height: CGFloat = 24

    let treeGlyph = NSTextField(labelWithString: "└")
    let spark = NSTextField(labelWithString: "")
    let descLabel = NSTextField(labelWithString: "")
    let timeLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()

    var showsSeparator: Bool = false {
        didSet { separator.isHidden = !showsSeparator }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        // Same font sizes as SessionRowView; dimmer colors keep the hierarchy
        treeGlyph.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        treeGlyph.textColor = .tertiaryLabelColor
        treeGlyph.alignment = .center
        spark.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        spark.textColor = Theme.orange
        spark.alignment = .center
        descLabel.font = NSFont.systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right

        // Same rule as SessionRowView: the description compresses first, the
        // elapsed time on the right never does.
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        separator.boxType = .separator
        separator.isHidden = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        for v in [treeGlyph, spark, descLabel, timeLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            // Same column as the session row's glyph
            treeGlyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            treeGlyph.widthAnchor.constraint(equalToConstant: 16),
            treeGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),

            spark.leadingAnchor.constraint(equalTo: treeGlyph.trailingAnchor, constant: 4),
            spark.widthAnchor.constraint(equalToConstant: 16),
            spark.centerYAnchor.constraint(equalTo: centerYAnchor),

            descLabel.leadingAnchor.constraint(equalTo: spark.trailingAnchor, constant: 5),
            descLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            descLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ agent: AgentTask, sparkIndex: Int, now: TimeInterval) {
        spark.stringValue = Theme.sparkFrames[sparkIndex % Theme.sparkFrames.count]
        let name = (agent.description?.isEmpty == false) ? agent.description!
            : (agent.type?.isEmpty == false) ? agent.type! : "agent"
        descLabel.stringValue = name
        if let start = agent.startedAt {
            let sec = max(0, Int(now - start))
            timeLabel.stringValue = sec >= 60 ? "\(sec / 60)m \(sec % 60)s" : "\(sec)s"
        } else {
            timeLabel.stringValue = ""
        }
    }
}

// MARK: - Floating panel

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Root view — shows ⇔ cursor over the resizable left/right edges

// The window server silently ignores NSCursor.set() from apps that are not
// frontmost, and this app is never frontmost (the panel is non-activating by
// design), so the tracking-area cursor logic below has no visible effect
// without this. The private-but-longstanding "SetsCursorInBackground"
// connection property tells the window server to honor our cursor sets anyway.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSSetConnectionProperty")
@discardableResult
private func CGSSetConnectionProperty(
    _ cid: UInt32, _ targetCID: UInt32, _ key: CFString, _ value: CFTypeRef
) -> Int32

private func enableCursorSettingInBackground() {
    let cid = CGSMainConnectionID()
    CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}

final class RootView: NSView {
    static let edgeWidth: CGFloat = 8

    // The panel never becomes key (it must not steal focus), so cursor rects
    // are never honored. Instead: track the mouse with .activeAlways +
    // .cursorUpdate and set the cursor manually on every event — which only
    // takes effect thanks to enableCursorSettingInBackground() above.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    private func applyCursor(for event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if x <= Self.edgeWidth || x >= bounds.width - Self.edgeWidth {
            NSCursor.resizeLeftRight.set()
        } else if hoveredView(for: event) is HoverButton {
            // Cursor rects are never honored (the panel is never key), so the
            // pointing hand over jump buttons must be set manually here too.
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func hoveredView(for event: NSEvent) -> NSView? {
        // hitTest expects the point in the receiver's superview coordinates
        let p = superview?.convert(event.locationInWindow, from: nil)
            ?? convert(event.locationInWindow, from: nil)
        return hitTest(p)
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        applyCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        applyCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

// Transparent strips over the left/right edges that implement the width
// resize themselves. The system resize band of a borderless .resizable
// window is narrower than the 8px zone the ⇔ cursor advertises, so
// .resizable is off and the drag is handled here — the cursor zone and the
// draggable zone are the same strips by construction.
final class ResizeHandleView: NSView {
    enum Edge { case left, right }
    private let edge: Edge
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private var startFrame = NSRect.zero
    private var startMouseX: CGFloat = 0

    init(edge: Edge, minWidth: CGFloat, maxWidth: CGFloat) {
        self.edge = edge
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Opt out of move-by-window-background so the drag resizes instead of moves
    override var mouseDownCanMoveWindow: Bool { false }

    // NSEvent.mouseLocation is already in global screen coordinates —
    // converting event.locationInWindow would go stale mid-drag because our
    // own setFrame moves the window between events on left-edge drags.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startFrame = window.frame
        startMouseX = NSEvent.mouseLocation.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let dx = NSEvent.mouseLocation.x - startMouseX
        // Start from the current frame: the content-height tick may adjust
        // y/height mid-drag, and only x/width belong to this drag.
        var f = window.frame
        switch edge {
        case .right:
            f.size.width = max(minWidth, min(maxWidth, startFrame.width + dx))
            f.origin.x = startFrame.origin.x
        case .left:
            f.size.width = max(minWidth, min(maxWidth, startFrame.width - dx))
            f.origin.x = startFrame.maxX - f.width
        }
        NSCursor.resizeLeftRight.set()  // mouseMoved pauses during drags
        window.setFrame(f, display: true)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: StatusPanel!
    private var crab: ClawdView!
    private var stack: NSStackView!
    private var emptyLabel: NSTextField!
    private var updateBanner: NSButton!
    private var updateMenuItem: NSMenuItem!
    private let updateChecker = UpdateChecker()
    private var rows: [SessionRowView] = []
    private var agentRows: [AgentRowView] = []
    private var groupHeaders: [GroupHeaderView] = []
    private var lastSignature = ""
    private var animTimer: Timer?
    private var tickCount = 0
    private var sparkIndex = 0
    private var crabFrame = 0
    private var sessions: [SessionState] = []
    private var isRefreshingUntitled = false
    private let titleWatcher = TitleStoreWatcher()

    private let defaultWidth: CGFloat = 300
    private let minWidth: CGFloat = 220
    private let maxWidth: CGFloat = 900
    private let originKey = "ccglancePanelOrigin"
    private let widthKey = "ccglancePanelWidth"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Font Awesome glyphs are used for the idle-row PR status icon
        if let fontURL = Bundle.main.url(forResource: "Font Awesome 6 Free-Solid-900", withExtension: "otf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
        try? FileManager.default.createDirectory(
            at: StateStore.sessionsDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Run on every launch: idempotent, and re-copies the hook script so the
        // deployed copy in ~/.claude/ccglance/hooks/ always matches this build.
        runInstaller()
        buildPanel()

        updateChecker.onUpdateAvailable = { [weak self] release in
            self?.showUpdateAvailable(release)
            // Install automatically; failures keep the banner for a manual retry
            self?.updateChecker.installAvailableUpdate(interactive: false)
        }
        updateChecker.onPhaseChange = { [weak self] phase in
            self?.showUpdatePhase(phase)
        }
        updateChecker.start()

        // Pick up session renames made in Claude Desktop as they happen
        titleWatcher.start()

        // 0.1s: crab animation; sessions reloaded every 0.5s
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(animTimer!, forMode: .common)
        sessions = StateStore.load()
        tick()
    }

    private func buildPanel() {
        let savedWidth = UserDefaults.standard.double(forKey: widthKey)
        let width = savedWidth >= minWidth ? min(savedWidth, maxWidth) : defaultWidth
        panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        enableCursorSettingInBackground()

        // Frosted-glass background as a SIBLING underneath the content, not as the
        // content's parent: subviews of NSVisualEffectView get macOS "vibrancy"
        // compositing, which blends text/images with the background and makes the
        // whole view look see-through. With the blur underneath and content in a
        // plain view on top, only the background is translucent.
        panel.acceptsMouseMovedEvents = true

        let root = RootView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        // Hairline border so the panel edge reads against dark backgrounds
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        panel.contentView = root
        // Fix appearance so text is always solid white on the dark glass —
        // in light mode labelColor would otherwise be near-black and sink into
        // the dark blur, which reads as "the content is transparent".
        panel.appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(blur)

        // Dark tint over the blur: dials the background translucency down so
        // what's behind the panel only faintly shows through.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tint)

        let effect = NSView()   // content layer — keeps the name used below
        effect.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(effect)

        for v in [blur, tint, effect] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: root.topAnchor),
                v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }

        crab = ClawdView()
        crab.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(crab)

        stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        emptyLabel = NSTextField(labelWithString: "No active sessions")
        emptyLabel.font = NSFont.systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(emptyLabel)

        // Update banner — hidden until a newer release is found; click installs it
        updateBanner = NSButton(title: "", target: self, action: #selector(installUpdate))
        updateBanner.isBordered = false
        updateBanner.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        updateBanner.contentTintColor = Theme.orange
        updateBanner.isHidden = true
        updateBanner.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(updateBanner)

        NSLayoutConstraint.activate([
            crab.topAnchor.constraint(equalTo: effect.topAnchor, constant: ClawdView.topMargin),
            crab.centerXAnchor.constraint(equalTo: effect.centerXAnchor),

            stack.topAnchor.constraint(equalTo: crab.bottomAnchor, constant: ClawdView.bottomMargin),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),

            emptyLabel.topAnchor.constraint(equalTo: crab.bottomAnchor, constant: ClawdView.bottomMargin + 2),
            emptyLabel.centerXAnchor.constraint(equalTo: effect.centerXAnchor),

            updateBanner.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
            updateBanner.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
        ])

        // Context menu (right click) — version block first
        let menu = NSMenu()
        let versionItem = menu.addItem(
            withTitle: "ccglance v\(UpdateChecker.currentVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        updateMenuItem = menu.addItem(withTitle: "", action: #selector(installUpdate), keyEquivalent: "")
        updateMenuItem.isHidden = true
        menu.addItem(withTitle: "Check for updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh session names", action: #selector(refreshTitles), keyEquivalent: "")
        menu.addItem(withTitle: "Clear finished sessions", action: #selector(clearIdle), keyEquivalent: "")
        menu.addItem(withTitle: "Reinstall Claude Code hooks", action: #selector(reinstallHooks), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ccglance", action: #selector(quit), keyEquivalent: "")
        for item in menu.items { item.target = self }
        effect.menu = menu

        // Edge resize handles — added last so they sit above the content
        for edge in [ResizeHandleView.Edge.left, .right] {
            let handle = ResizeHandleView(edge: edge, minWidth: minWidth, maxWidth: maxWidth)
            handle.menu = menu  // keep the right-click menu working over the edges
            handle.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(handle)
            NSLayoutConstraint.activate([
                handle.topAnchor.constraint(equalTo: root.topAnchor),
                handle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                handle.widthAnchor.constraint(equalToConstant: RootView.edgeWidth),
                edge == .left
                    ? handle.leadingAnchor.constraint(equalTo: root.leadingAnchor)
                    : handle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }

        restoreOrigin()
        panel.orderFrontRegardless()
    }

    // MARK: Tick

    private func tick() {
        tickCount += 1
        let now = Date().timeIntervalSince1970

        // Reload session files every 0.5s; animate every 0.1s
        if tickCount % 5 == 0 {
            sessions = StateStore.load()
        }
        if tickCount % 3 == 0 { sparkIndex += 1 }

        // Refresh PR status every 60s so merges/closes done outside a session
        // show up without waiting for the next turn boundary
        if tickCount % 600 == 0 { refreshPRStatuses() }

        // Fresh sessions start without a title (Claude Desktop generates it a
        // few seconds after the first prompt, but hooks only re-resolve it on
        // turn boundaries). Poll the Desktop store every 2s for recently
        // created untitled sessions so the name lands mid-turn. Capped at 5min
        // so sessions that never get a title stop triggering the store walk.
        if tickCount % 20 == 0, !isRefreshingUntitled {
            let untitled = Set(sessions.compactMap { s -> String? in
                guard s.title?.isEmpty != false,
                      let created = s.createdAt, now - created < 300 else { return nil }
                return s.sessionId
            })
            if !untitled.isEmpty {
                isRefreshingUntitled = true
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    StateStore.refreshTitles(only: untitled)
                    DispatchQueue.main.async { self?.isRefreshingUntitled = false }
                }
            }
        }

        // Group sessions by project (directory name)
        let grouped = Dictionary(grouping: sessions) { $0.project ?? "\u{2014}" }
            .map { (name: $0.key, sessions: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

        // Rebuild views only when the group structure (or agent counts) changes
        let signature = grouped.map { group in
            let agentCounts = group.sessions.map { String($0.agents?.count ?? 0) }.joined(separator: ",")
            return "\(group.name)#\(group.sessions.count)#\(agentCounts)"
        }.joined(separator: "|")
        if signature != lastSignature {
            lastSignature = signature
            for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
            groupHeaders = []
            rows = []
            agentRows = []
            for group in grouped {
                let header = GroupHeaderView(frame: .zero)
                header.label.stringValue = group.name
                header.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(header)
                NSLayoutConstraint.activate([
                    header.heightAnchor.constraint(equalToConstant: GroupHeaderView.height),
                    header.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                    header.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
                ])
                groupHeaders.append(header)
                for session in group.sessions {
                    let row = SessionRowView(frame: .zero)
                    row.translatesAutoresizingMaskIntoConstraints = false
                    stack.addArrangedSubview(row)
                    NSLayoutConstraint.activate([
                        row.heightAnchor.constraint(equalToConstant: SessionRowView.height),
                        row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                        row.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
                    ])
                    rows.append(row)
                    for _ in session.agents ?? [] {
                        let agentRow = AgentRowView(frame: .zero)
                        agentRow.translatesAutoresizingMaskIntoConstraints = false
                        stack.addArrangedSubview(agentRow)
                        NSLayoutConstraint.activate([
                            agentRow.heightAnchor.constraint(equalToConstant: AgentRowView.height),
                            agentRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                            agentRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
                        ])
                        agentRows.append(agentRow)
                    }
                }
            }
        }
        var rowIndex = 0
        var agentRowIndex = 0
        for group in grouped {
            for (j, session) in group.sessions.enumerated() {
                guard rowIndex < rows.count else { break }
                rows[rowIndex].update(session, sparkIndex: sparkIndex, now: now)
                let agents = session.agents ?? []
                // border after every visual row except the group's last one
                let isLastInGroup = j == group.sessions.count - 1
                rows[rowIndex].showsSeparator = !agents.isEmpty || !isLastInGroup
                for (k, agent) in agents.enumerated() {
                    guard agentRowIndex < agentRows.count else { break }
                    agentRows[agentRowIndex].update(agent, sparkIndex: sparkIndex, now: now)
                    agentRows[agentRowIndex].showsSeparator = !(isLastInGroup && k == agents.count - 1)
                    agentRowIndex += 1
                }
                rowIndex += 1
            }
        }
        emptyLabel.isHidden = !sessions.isEmpty

        // Crab reflects the most urgent status; walk animation runs while working
        let newState: CrabState
        if sessions.contains(where: { $0.status == "permission" }) {
            newState = .permission
        } else if sessions.contains(where: { $0.status == "thinking" || $0.status == "tool" }) {
            newState = .working
        } else {
            newState = .idle
        }
        crab.state = newState
        if newState == .working {
            crabFrame += 1                                   // 0.1s per frame — full walk cycle
        } else if newState == .permission, tickCount % 3 == 0 {
            crabFrame += 1                                   // slower bounce
        }
        crab.frameIndex = crabFrame
        crab.needsDisplay = true

        // Height follows content; width is the user's (horizontal resize only).
        let crabArea = ClawdView.topMargin + crab.intrinsicContentSize.height + ClawdView.bottomMargin
        let agentCount = sessions.reduce(0) { $0 + ($1.agents?.count ?? 0) }
        var contentHeight: CGFloat = crabArea + (sessions.isEmpty
            ? 30
            : CGFloat(grouped.count) * GroupHeaderView.height
                + CGFloat(sessions.count) * SessionRowView.height
                + CGFloat(agentCount) * AgentRowView.height + 8)
        if !updateBanner.isHidden {
            contentHeight += 24  // room for the update banner at the bottom
        }
        let frame = panel.frame
        if abs(frame.height - contentHeight) > 0.5 {
            let topLeft = NSPoint(x: frame.origin.x, y: frame.origin.y + frame.height)
            panel.setFrame(
                NSRect(x: topLeft.x, y: topLeft.y - contentHeight, width: frame.width, height: contentHeight),
                display: true
            )
            // Transparent windows don't recompute their shadow on content
            // changes; without this the drop shadow goes stale or vanishes
            panel.invalidateShadow()
        }
    }

    // MARK: Window position persistence

    func windowDidMove(_ notification: Notification) {
        let f = panel.frame
        // Save top-left so height changes don't drift the panel
        UserDefaults.standard.set([f.origin.x, f.origin.y + f.height], forKey: originKey)
    }

    func windowDidResize(_ notification: Notification) {
        let f = panel.frame
        UserDefaults.standard.set(Double(f.width), forKey: widthKey)
        // Resizing from the left edge moves the origin too
        UserDefaults.standard.set([f.origin.x, f.origin.y + f.height], forKey: originKey)
    }

    private func restoreOrigin() {
        if let arr = UserDefaults.standard.array(forKey: originKey) as? [Double], arr.count == 2 {
            let h = panel.frame.height
            panel.setFrameOrigin(NSPoint(x: arr[0], y: arr[1] - h))
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 20, y: v.maxY - 140))
        }
    }

    // MARK: Hooks installer

    private lazy var nodePath: String? = Self.findNode()

    private static func findNode() -> String? {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return found
        }
        // Fall back to login-shell lookup
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        if let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
            return out
        }
        return nil
    }

    @discardableResult
    private func runInstaller() -> Bool {
        guard let resources = Bundle.main.resourcePath else { return false }
        let installer = resources + "/install.js"
        guard FileManager.default.fileExists(atPath: installer) else { return false }
        guard let nodePath = nodePath else {
            NSLog("ccglance: node not found; run install.js manually")
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [installer]
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    /// Re-fetch PR status for idle sessions via the bundled hook's --fetch-pr
    /// mode. Fire-and-forget: results land in the session files and get picked
    /// up by the regular 0.5s poll. Called every 60s from tick() and by the
    /// manual Refresh action (force); hook events also refresh on
    /// Stop/SessionStart. The periodic pass only polls sessions with a live
    /// PR — no-PR sessions are covered by the hooks, MERGED is irreversible —
    /// to keep the node/gh process churn minimal.
    private func refreshPRStatuses(force: Bool = false) {
        guard let resources = Bundle.main.resourcePath, let nodePath = nodePath else { return }
        let hook = resources + "/ccglance-hook.js"
        guard FileManager.default.fileExists(atPath: hook) else { return }
        let now = Date().timeIntervalSince1970
        for s in sessions where s.status == "idle" {
            guard let cwd = s.cwd else { continue }
            if !force {
                guard let pr = s.pr, pr.state != "MERGED" else { continue }
                if let checked = pr.checkedAt, now - checked < 55 { continue }
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: nodePath)
            proc.arguments = [hook, "--fetch-pr", s.sessionId, cwd]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
        }
    }

    // MARK: Menu actions

    @objc private func refreshTitles() {
        StateStore.refreshTitles()
        sessions = StateStore.load()
        refreshPRStatuses(force: true)
        tick()
    }

    @objc private func clearIdle() { sessions = StateStore.clearAndReload(); tick() }
    @objc private func reinstallHooks() { runInstaller() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Updates

    private func showUpdateAvailable(_ release: UpdateChecker.Release) {
        updateBanner.title = "⬆ Update to v\(release.version)"
        updateBanner.isHidden = false
        updateBanner.isEnabled = true
        updateMenuItem.title = "Update to ccglance v\(release.version)…"
        updateMenuItem.isHidden = false
    }

    private func showUpdatePhase(_ phase: UpdateChecker.Phase) {
        switch phase {
        case .idle:
            if let release = updateChecker.available { showUpdateAvailable(release) }
        case .downloading:
            updateBanner.title = "⬇ Downloading update…"
            updateBanner.isEnabled = false
            updateMenuItem.isHidden = true
        case .installing:
            updateBanner.title = "Installing update…"
        case .failed(let message):
            // Disabled while .failed — installAvailableUpdate would ignore the
            // click anyway; re-enabled when the phase resets to .idle.
            updateBanner.title = "⚠ \(message)"
            updateBanner.isEnabled = false
        }
    }

    @objc private func installUpdate() {
        updateChecker.installAvailableUpdate()
    }

    @objc private func checkForUpdates() {
        updateChecker.check { [weak self] release in
            if let release {
                self?.showUpdateAvailable(release)
            } else {
                let alert = NSAlert()
                alert.messageText = "ccglance is up to date"
                alert.informativeText = "Version \(UpdateChecker.currentVersion) is the latest release."
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }
}

extension StateStore {
    static func clearAndReload() -> [SessionState] {
        clearIdle()
        return load()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
