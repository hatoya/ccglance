import AppKit
import CoreText

// MARK: - Session state model (written by hooks/ccglance-hook.js)

struct AgentTask: Codable {
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

struct SessionState: Codable {
    var sessionId: String
    var project: String?
    var title: String?      // session name from the transcript (editable in Claude Desktop)
    var cwd: String?
    var status: String        // "thinking" | "tool" | "permission" | "idle"
    var tool: String?
    var message: String?
    var turnStartedAt: Double?
    var updatedAt: Double
    var agents: [AgentTask]?  // running subagents (optional: older files lack it)
    var pr: PRInfo?           // fetched via gh by the hook's --fetch-pr mode
}

enum StateStore {
    static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ccglance/sessions", isDirectory: true)
    }

    /// Load all session files. Prunes files not updated for 12h (crashed sessions).
    static func load() -> [SessionState] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        let now = Date().timeIntervalSince1970
        var result: [SessionState] = []
        for url in files where url.pathExtension == "json" {
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

    /// Look up the Desktop-app session title (editable in Claude Desktop) for a
    /// CLI session id. Store layout:
    ///   ~/Library/Application Support/Claude/claude-code-sessions/<ws>/<x>/local_<id>.json
    ///   { "title": ..., "cliSessionId": ..., "bridgeSessionIds": [...] }
    static func desktopTitle(for sessionId: String) -> String? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (title: String, mtime: Date)?
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var ids: [String] = []
            for key in ["cliSessionId", "sessionId", "id"] {
                if let v = obj[key] as? String { ids.append(v) }
            }
            if let bridged = obj["bridgeSessionIds"] as? [String] { ids += bridged }
            guard ids.contains(sessionId),
                  let raw = obj["title"] as? String else { continue }
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || mtime > best!.mtime {
                best = (title, mtime)
            }
        }
        return best?.title
    }

    /// Re-resolve titles for all current sessions and persist them into the
    /// state files (hooks preserve the field afterwards).
    static func refreshTitles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  var state = try? JSONDecoder().decode(SessionState.self, from: data) else { continue }
            guard let title = desktopTitle(for: state.sessionId), title != state.title else { continue }
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

// MARK: - Session row view (table-style)

final class SessionRowView: NSView {
    static let height: CGFloat = 28

    let glyph = NSTextField(labelWithString: "")
    let projectLabel = NSTextField(labelWithString: "")
    let rightLabel = NSTextField(labelWithString: "")   // elapsed time if available, otherwise status name
    private let highlight = NSView()
    private let separator = NSBox()

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
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ s: SessionState, sparkIndex: Int, now: TimeInterval) {
        // The project name lives in the group header; the row shows the
        // session title (editable in Claude Desktop) or the id as a fallback.
        let name = (s.title?.isEmpty == false) ? s.title!
            : "Session " + String(s.sessionId.prefix(8))
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

final class RootView: NSView {
    static let edgeWidth: CGFloat = 8

    // The panel never becomes key (it must not steal focus), but macOS only
    // honors cursor rects / one-shot NSCursor.set() for the key window and
    // resets the cursor right back. So: track the mouse with .activeAlways +
    // .cursorUpdate, and re-assert the cursor on every event while hovering
    // an edge — continuous re-set wins over the system reset.
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
        } else {
            NSCursor.arrow.set()
        }
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
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
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
        menu.addItem(withTitle: "Refresh session names", action: #selector(refreshTitles), keyEquivalent: "r")
        menu.addItem(withTitle: "Clear finished sessions", action: #selector(clearIdle), keyEquivalent: "")
        menu.addItem(withTitle: "Reinstall Claude Code hooks", action: #selector(reinstallHooks), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ccglance", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        effect.menu = menu

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
        // Lock vertical resizing: edges only move horizontally
        panel.minSize = NSSize(width: minWidth, height: contentHeight)
        panel.maxSize = NSSize(width: maxWidth, height: contentHeight)
        let frame = panel.frame
        if abs(frame.height - contentHeight) > 0.5, !panel.inLiveResize {
            let topLeft = NSPoint(x: frame.origin.x, y: frame.origin.y + frame.height)
            panel.setFrame(
                NSRect(x: topLeft.x, y: topLeft.y - contentHeight, width: frame.width, height: contentHeight),
                display: true
            )
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
