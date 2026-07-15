import AppKit
import CryptoKit

/// Checks GitHub Releases for a newer version and installs it in place:
/// download the release zip → verify its SHA-256 against the published
/// .sha256 asset → unpack → verify the code signature is a Developer ID
/// signature from `teamID` → swap the .app bundle → relaunch. Auto-install
/// refuses to run without the checksum asset or from non-GitHub hosts
/// (interactive installs fall back to opening the release page; automatic
/// ones leave the banner for a click). Downloaded zips carry no quarantine
/// attribute (we don't opt into LSFileQuarantineEnabled).
final class UpdateChecker {
    /// GitHub repo to check. Change when the repo is published.
    static let repo = "hatoya/ccglance"

    /// Apple Developer Team ID releases are signed with. Updates signed by
    /// anyone else (including ad-hoc CI fallback builds) are refused, so a
    /// compromised GitHub account alone can't push code to existing users.
    static let teamID = "JN89ZQ9858"

    /// codesign requirement matching Apple's standard Developer ID designated
    /// requirement: issued by the Developer ID CA (intermediate ...6.2.6) as a
    /// Developer ID Application certificate (leaf ...6.1.13) for our team.
    static let signatureRequirement =
        "anchor apple generic"
        + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        + " and certificate leaf[subject.OU] = \"\(teamID)\""

    struct Release {
        let version: String   // normalized, no leading "v"
        let pageURL: URL      // html_url — fallback when auto-install fails
        let zipURL: URL?      // first .zip asset — what we download and install
        let shaURL: URL?      // "<zip>.sha256" asset — auto-install requires it
    }

    enum Phase {
        case idle
        case downloading
        case installing
        case failed(String)
    }

    /// Latest release found that is newer than the running version. nil = up to date / unknown.
    private(set) var available: Release?
    private(set) var phase: Phase = .idle
    var onUpdateAvailable: ((Release) -> Void)?
    var onPhaseChange: ((Phase) -> Void)?

    private var timer: Timer?
    private var interactiveInstall = true
    private let checkInterval: TimeInterval = 24 * 3600
    private let lastCheckKey = "ccglanceLastUpdateCheck"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Start periodic checking: once shortly after launch (if 24h passed
    /// since the last check), then every 24h while running.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            let last = UserDefaults.standard.double(forKey: self.lastCheckKey)
            if Date().timeIntervalSince1970 - last >= self.checkInterval {
                self.check()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    /// Fetch the latest release. completion runs on the main thread.
    func check(completion: ((Release?) -> Void)? = nil) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            var found: Release?
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String,
               let pageString = obj["html_url"] as? String,
               let pageURL = URL(string: pageString) {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                var zipURL: URL?
                var shaURL: URL?
                if let assets = obj["assets"] as? [[String: Any]] {
                    var urls: [String: URL] = [:]   // asset name → download URL
                    for asset in assets {
                        if let name = asset["name"] as? String,
                           let dl = asset["browser_download_url"] as? String,
                           let url = URL(string: dl), Self.isTrustedAssetURL(url) {
                            urls[name] = url
                        }
                    }
                    if let zipName = urls.keys.filter({ $0.hasSuffix(".zip") }).sorted().first {
                        zipURL = urls[zipName]
                        shaURL = urls[zipName + ".sha256"]
                    }
                }
                if Self.isNewer(version, than: Self.currentVersion) {
                    found = Release(version: version, pageURL: pageURL, zipURL: zipURL, shaURL: shaURL)
                }
            }
            DispatchQueue.main.async {
                if let found {
                    let isNew = self?.available?.version != found.version
                    self?.available = found
                    if isNew { self?.onUpdateAvailable?(found) }
                }
                completion?(found)
            }
        }.resume()
    }

    /// Only download release assets from GitHub-controlled hosts over HTTPS.
    static func isTrustedAssetURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }
        return host == "github.com"
            || host == "githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }

    /// Numeric semver comparison ("1.2.10" > "1.2.9"). Non-numeric parts compare as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Install

    /// Download the release zip, swap the running .app bundle, relaunch.
    /// On any failure the old app is restored (or left untouched).
    /// interactive: true when triggered by a user click — failures then open
    /// the release page as a fallback. false for automatic installs, which
    /// must never pop a browser window on their own.
    func installAvailableUpdate(interactive: Bool = true) {
        guard let release = available else { return }
        guard case .idle = phase else { return }        // already running
        interactiveInstall = interactive
        // Refuse to auto-install without a checksum asset or from untrusted
        // hosts — fall back to the release page so the user installs manually.
        guard let zipURL = release.zipURL, let shaURL = release.shaURL,
              Self.isTrustedAssetURL(zipURL), Self.isTrustedAssetURL(shaURL) else {
            if interactive { NSWorkspace.shared.open(release.pageURL) }
            return
        }
        setPhase(.downloading)

        let task = URLSession.shared.downloadTask(with: zipURL) { [weak self] tmpFile, response, error in
            guard let self else { return }
            guard let tmpFile,
                  let http = response as? HTTPURLResponse, http.statusCode == 200, error == nil else {
                self.fail("Download failed", fallback: release)
                return
            }
            // downloadTask deletes tmpFile when the handler returns — move it out first.
            let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ccglance-update-\(UUID().uuidString)", isDirectory: true)
            let zipFile = workDir.appendingPathComponent("update.zip")
            do {
                try FileManager.default.createDirectory(
                    at: workDir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.moveItem(at: tmpFile, to: zipFile)
            } catch {
                self.fail("Could not stage download", fallback: release)
                return
            }
            // Verify the zip's SHA-256 against the published .sha256 asset
            // before anything gets unpacked or executed.
            self.fetchExpectedDigest(shaURL) { expected in
                guard let expected, Self.sha256Hex(of: zipFile) == expected else {
                    try? FileManager.default.removeItem(at: workDir)
                    self.fail("Update failed checksum verification", fallback: release)
                    return
                }
                self.setPhase(.installing)
                DispatchQueue.global(qos: .userInitiated).async {
                    self.unpackAndSwap(zipFile: zipFile, workDir: workDir, release: release)
                }
            }
        }
        task.resume()
    }

    /// Download the .sha256 asset and return the hex digest (first token,
    /// `shasum` output format). completion(nil) on any failure.
    private func fetchExpectedDigest(_ url: URL, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  error == nil, let data, data.count < 4096,
                  let text = String(data: data, encoding: .utf8),
                  let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first
            else { return completion(nil) }
            let digest = token.lowercased()
            guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { return completion(nil) }
            completion(digest)
        }.resume()
    }

    static func sha256Hex(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func unpackAndSwap(zipFile: URL, workDir: URL, release: Release) {
        let fm = FileManager.default
        let extractDir = workDir.appendingPathComponent("extract", isDirectory: true)

        // 1. Unpack with ditto (preserves symlinks, resource forks, signatures)
        guard run("/usr/bin/ditto", ["-xk", zipFile.path, extractDir.path]) else {
            fail("Could not unpack the update", fallback: release)
            return
        }

        // 2. Locate the .app bundle (top level or one directory down)
        guard let newApp = findApp(in: extractDir),
              fm.isExecutableFile(atPath: newApp.appendingPathComponent("Contents/MacOS/ccglance").path) else {
            fail("Update package looks broken", fallback: release)
            return
        }

        // 2b. The bundle must carry an unbroken Developer ID signature from
        //     our team — a hash match against a compromised release is not
        //     enough to get code installed.
        guard run("/usr/bin/codesign", [
            "--verify", "--deep", "--strict",
            "-R=\(Self.signatureRequirement)", newApp.path,
        ]) else {
            fail("Update package failed signature check", fallback: release)
            return
        }

        // 3. Swap: move the running bundle aside, move the new one in.
        //    macOS allows moving a running app — the binary stays mapped.
        let dest = URL(fileURLWithPath: Bundle.main.bundlePath)
        let oldApp = workDir.appendingPathComponent("old-\(dest.lastPathComponent)")
        do {
            try fm.moveItem(at: dest, to: oldApp)
        } catch {
            fail("No permission to replace the app", fallback: release)
            return
        }
        do {
            try fm.moveItem(at: newApp, to: dest)
        } catch {
            try? fm.moveItem(at: oldApp, to: dest)   // roll back
            fail("Could not install the update", fallback: release)
            return
        }

        // 4. Relaunch the new version and quit. The helper outlives us because
        //    it's a detached process; the short sleep lets this process exit
        //    so `open` starts a fresh instance instead of focusing this one.
        // The app path is passed as a positional argument ($0), never
        // interpolated into the shell string — no quoting/injection issues.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "sleep 1; exec /usr/bin/open -g \"$0\"", dest.path]
        try? helper.run()

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        if let app = top.first(where: { $0.pathExtension == "app" }) { return app }
        for sub in top {
            if let children = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil),
               let app = children.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        return nil
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func setPhase(_ new: Phase) {
        DispatchQueue.main.async {
            self.phase = new
            self.onPhaseChange?(new)
        }
    }

    private func fail(_ message: String, fallback release: Release) {
        DispatchQueue.main.async {
            let interactive = self.interactiveInstall
            self.phase = .failed(interactive ? message + " — opening release page" : message)
            self.onPhaseChange?(self.phase)
            if interactive { NSWorkspace.shared.open(release.pageURL) }
            // Let the user try again later
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if case .failed = self.phase {
                    self.phase = .idle
                    self.onPhaseChange?(.idle)
                }
            }
        }
    }
}
