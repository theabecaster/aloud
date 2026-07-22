import AppKit
import Foundation

// In-app updater: GitHub release feed → download the notarized zip → verify the
// code signature (and that it's our Developer ID team) → atomic in-place swap
// via a detached helper that waits for us to exit. Pure Foundation; no Sparkle.
// Falls back to opening the Releases page when a swap can't be trusted.

enum Updater {
    static let updateAsset = "Aloud-macos.zip"
    static let releasesPage = URL(string: "https://github.com/\(AppPaths.githubRepo)/releases/latest")!
    private static let autoCheckInterval: TimeInterval = 24 * 3600

    // MARK: Semver

    static func semverParts(_ s: String) -> [Int] {
        let core = s.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
            .split(separator: "-").first.map(String.init) ?? ""
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func semverLess(_ a: String, _ b: String) -> Bool {
        let pa = semverParts(a), pb = semverParts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func currentVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    // MARK: Feed

    struct LatestRelease {
        let tag: String
        let pageURL: URL
        let zipURL: URL
    }

    private static func httpGet(_ url: URL, timeout: TimeInterval) -> Data? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: url)
        req.setValue("Aloud", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        var out: Data?
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { out = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return out
    }

    // Call off the main thread.
    static func fetchLatestRelease() -> LatestRelease? {
        let api = URL(string: "https://api.github.com/repos/\(AppPaths.githubRepo)/releases/latest")!
        guard let data = httpGet(api, timeout: 15),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == updateAsset }),
              let urlStr = asset["browser_download_url"] as? String,
              let url = URL(string: urlStr) else { return nil }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        return LatestRelease(tag: tag, pageURL: page, zipURL: url)
    }

    // MARK: Apply

    // The writable, non-translocated .app we can replace, or nil when a swap
    // can't be trusted (dev binary, translocation mount, unwritable parent).
    static func updatableBundlePath() -> String? {
        let bundle = Bundle.main.bundleURL
        let path = bundle.path
        guard path.hasSuffix(".app") else { return nil }
        if path.contains("/AppTranslocation/") { return nil }
        let parent = bundle.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else { return nil }
        return path
    }

    enum ApplyResult {
        case relaunching
        case failed(String)
    }

    @discardableResult
    private static func runTool(_ launchPath: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // Download, verify, stage the detached swap helper. On .relaunching the
    // caller terminates the app; the helper waits for the PID, swaps, relaunches.
    static func downloadAndStage(_ release: LatestRelease, into dest: String) -> ApplyResult {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("aloud-update-\(getpid())")
        try? fm.removeItem(at: tmp)
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) }
        catch { return .failed("couldn’t create a temporary folder") }

        let zipPath = tmp.appendingPathComponent(updateAsset)
        guard let zipData = httpGet(release.zipURL, timeout: 300) else { return .failed("download failed") }
        do { try zipData.write(to: zipPath) } catch { return .failed("couldn’t save the download") }

        if runTool("/usr/bin/ditto", ["-x", "-k", zipPath.path, tmp.path]) != 0 {
            return .failed("couldn’t unpack the download")
        }
        let newApp = tmp.appendingPathComponent("Aloud.app")
        guard fm.fileExists(atPath: newApp.path) else { return .failed("the download was incomplete") }

        // Integrity gates: the seal must verify AND the signer must be our team.
        if runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) != 0 {
            return .failed("the download failed signature verification")
        }
        if runTool("/usr/bin/codesign",
                   ["--verify", "--deep", "--strict",
                    "-R=anchor apple generic and certificate leaf[subject.OU] = \"R2PVQ496X7\"",
                    newApp.path]) != 0 {
            return .failed("the download isn’t signed by the Aloud developer")
        }

        let script = """
        #!/bin/sh
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        DEST="\(dest)"
        STAGED="$DEST.new-$$"
        BACKUP="$DEST.old-$$"
        /usr/bin/ditto "\(newApp.path)" "$STAGED" || { /bin/rm -rf "$STAGED"; /usr/bin/open "$DEST"; exit 1; }
        /bin/mv "$DEST" "$BACKUP" || { /bin/rm -rf "$STAGED"; /usr/bin/open "$DEST"; exit 1; }
        /bin/mv "$STAGED" "$DEST" || { /bin/mv "$BACKUP" "$DEST"; /usr/bin/open "$DEST"; exit 1; }
        /bin/rm -rf "$BACKUP"
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        /bin/rm -rf "\(tmp.path)"
        /usr/bin/open "$DEST"
        """
        let scriptURL = tmp.appendingPathComponent("apply.sh")
        do { try script.write(to: scriptURL, atomically: true, encoding: .utf8) }
        catch { return .failed("couldn’t stage the installer") }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [scriptURL.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run() } catch { return .failed("couldn’t launch the installer") }
        return .relaunching
    }

    // MARK: Throttle

    // True at most once per interval — the silent launch check must not hit
    // the network on every restart.
    static func shouldAutoCheckNow() -> Bool {
        let fm = FileManager.default
        let url = AppPaths.lastUpdateCheckFile
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) < autoCheckInterval { return false }
        AppPaths.ensureStateDir()
        try? Data().write(to: url)
        return true
    }
}
