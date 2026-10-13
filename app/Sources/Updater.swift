import AppKit
import CryptoKit
import Foundation

/// Checks this fork's GitHub Releases for a newer version and, only after the user
/// confirms in a dialog, installs it in place.
///
/// macOS does not vet an app that downloads and swaps itself (no quarantine flag, and an
/// ad-hoc signature runs fine), so the checks here are the only gate:
/// - the release and its zip must both come from `owner`'s own account; a workflow's
///   GITHUB_TOKEN acts as github-actions[bot] and can't pass this;
/// - nothing installs without the user pressing 安裝, whatever triggered the check.
final class Updater {
    static let shared = Updater()
    /// Written into Info.plist at build time from the GitHub repository that built it.
    static let repo = Bundle.main.object(forInfoDictionaryKey: "LouisaUpdateRepo") as? String ?? "PipperL/louisa-wifi"
    static let owner = Bundle.main.object(forInfoDictionaryKey: "LouisaUpdateOwner") as? String ?? "PipperL"
    static let bundleID = "io.github.louisawifi"

    struct Update {
        let version: String
        let title: String
        let page: URL
        let zip: URL
        let digest: String?    // "sha256:…" from the API, when GitHub provides it
    }

    /// Newer release, if any. Main thread only.
    private(set) var available: Update?
    private var dialogOpen = false

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var commit: String? { Bundle.main.object(forInfoDictionaryKey: "LouisaGitCommit") as? String }

    /// "有更新時通知我" (default) or "不檢查更新".
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "checkUpdates") }
        set { UserDefaults.standard.set(newValue, forKey: "checkUpdates"); if newValue { check() } }
    }
    private var skipped: String? {
        get { UserDefaults.standard.string(forKey: "skippedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "skippedVersion") }
    }
    private var postponed: String?    // 稍後: keep the menu item, don't pop the dialog again

    func start() {
        if enabled { check() }
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            if self?.enabled == true { self?.check() }
        }
    }

    /// `manual`: from the menu or louisawifi://update. Always ends in a dialog or a notification,
    /// and shows a skipped version again.
    func check(manual: Bool = false) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            let release = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async {
                // 404: no release published yet.
                guard let release else {
                    if manual { Notifier.post(status == 404 ? "目前已是最新版本（\(self.current)）" : "檢查更新失敗，請稍後再試") }
                    return
                }
                switch self.verify(release) {
                case .failure(let why):
                    debugLog("release \(release.tag_name) ignored: \(why.text)")
                    if manual { Notifier.post("最新的 release 沒有通過檢查（\(why.text)），不會安裝") }
                case .success(let update):
                    guard update.version.compare(self.current, options: .numeric) == .orderedDescending else {
                        self.available = nil
                        if manual { Notifier.post("目前已是最新版本（\(self.current)）") }
                        return
                    }
                    self.available = update
                    if manual {
                        self.present()
                    } else if update.version != self.skipped && update.version != self.postponed {
                        Notifier.post("有新版本 \(update.version)")
                        self.present()
                    }
                }
            }
        }.resume()
    }

    /// Only releases the owner published, from their own account, with the zip they uploaded.
    private func verify(_ r: Release) -> Result<Update, Failure> {
        guard !r.draft, !r.prerelease else { return .failure(Failure("不是正式版")) }
        guard r.author.login == Self.owner else { return .failure(Failure("發布者是 \(r.author.login)，不是 \(Self.owner)")) }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        guard version.range(of: #"^\d+(\.\d+){0,3}$"#, options: .regularExpression) != nil else {
            return .failure(Failure("版本號格式不正確：\(r.tag_name)"))
        }
        guard let asset = r.assets.first(where: { $0.name == "LouisaWiFi.zip" }) else { return .failure(Failure("找不到 LouisaWiFi.zip")) }
        guard asset.uploader.login == Self.owner else { return .failure(Failure("zip 上傳者是 \(asset.uploader.login)，不是 \(Self.owner)")) }
        guard asset.browser_download_url.host == "github.com" else { return .failure(Failure("下載網址不在 github.com")) }
        return .success(Update(version: version, title: r.name ?? r.tag_name, page: r.html_url,
                               zip: asset.browser_download_url, digest: asset.digest))
    }

    /// The only way to install: the user presses 安裝 here.
    func present() {
        guard let update = available, !dialogOpen else { return }
        dialogOpen = true
        defer { dialogOpen = false }
        let alert = NSAlert()
        alert.messageText = "有新版本 \(update.version)"
        alert.informativeText = """
            目前版本：\(current)\(commit.map { "（\($0)）" } ?? "")
            新版本：\(update.title)
            發布者：\(Self.owner)
            SHA-256：\(update.digest.map { $0.replacingOccurrences(of: "sha256:", with: "") } ?? "（GitHub 未提供）")

            \(update.page.absoluteString)
            """
        alert.addButton(withTitle: "安裝")
        alert.addButton(withTitle: "稍後")
        alert.addButton(withTitle: "跳過這個版本")
        alert.addButton(withTitle: "查看發布頁面")
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(update)
        case .alertSecondButtonReturn: postponed = update.version
        case .alertThirdButtonReturn: skipped = update.version; available = nil
        default: postponed = update.version; NSWorkspace.shared.open(update.page)
        }
    }

    /// Download, check, swap the bundle after we quit, relaunch.
    private func install(_ update: Update) {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            Notifier.post("沒有權限替換 \(target.deletingLastPathComponent().path) 裡的 App，請手動下載")
            NSWorkspace.shared.open(update.page)
            return
        }
        Notifier.post("正在下載 \(update.version)…")
        URLSession.shared.downloadTask(with: update.zip) { file, _, _ in
            do {
                guard let file else { throw Failure("下載失敗") }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LouisaWiFi-\(update.version)-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let archive = dir.appendingPathComponent("LouisaWiFi.zip")
                try FileManager.default.moveItem(at: file, to: archive)

                // Catches a broken download; the digest comes from the same place as the zip,
                // so tampering is handled by the owner checks and immutable releases instead.
                if let digest = update.digest {
                    let actual = "sha256:" + SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
                    guard actual == digest.lowercased() else { throw Failure("SHA-256 不符") }
                }
                try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, dir.path])
                let fresh = dir.appendingPathComponent("LouisaWiFi.app")
                guard Bundle(url: fresh)?.bundleIdentifier == Self.bundleID else { throw Failure("不是 Louisa Wi-Fi") }
                try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh.path])

                // Runs after we exit; child processes outlive the app.
                let swap = Process()
                swap.executableURL = URL(fileURLWithPath: "/bin/sh")
                swap.arguments = ["-c", "sleep 1; rm -rf \"$1\" && mv \"$2\" \"$1\"; xattr -dr com.apple.quarantine \"$1\"; open \"$1\"",
                                  "sh", target.path, fresh.path]
                try swap.run()
                debugLog("updating to \(update.version)")
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } catch {
                let why = (error as? Failure)?.text ?? error.localizedDescription
                debugLog("update failed: \(why)")
                DispatchQueue.main.async { Notifier.post("更新失敗（\(why)），請到 GitHub 下載新版") }
            }
        }.resume()
    }

    private struct Failure: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("\(URL(fileURLWithPath: tool).lastPathComponent) 檢查失敗") }
    }

    private struct Account: Decodable { let login: String }

    private struct Release: Decodable {
        let tag_name: String
        let name: String?
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let author: Account
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let uploader: Account
        let digest: String?
    }
}
