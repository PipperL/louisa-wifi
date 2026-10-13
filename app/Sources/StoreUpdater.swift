import Foundation

/// Keeps store data current from this fork's `data` branch, separately from app updates.
/// Data only ever becomes fixed-field strings and numbers; it never runs.
final class StoreUpdater {
    static let shared = StoreUpdater()
    static let repo = "PipperL/louisa-wifi"
    private static let base = "https://raw.githubusercontent.com/\(repo)/data/data/"
    /// The scheduled workflow that refreshes the data; if it hasn't succeeded in a while, say so.
    private static let workflowRuns =
        "https://api.github.com/repos/\(repo)/actions/workflows/stores.yml/runs?branch=main&status=success&per_page=1"
    static let staleDays = 21

    /// Days since the data workflow last succeeded, once known. Main thread only.
    private(set) var daysSinceCheck: Int?
    private var rejected: String?           // SHA we already warned about
    private let queue = DispatchQueue(label: "louisawifi.stores")

    func start() {
        check()
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    func check(manual: Bool = false) {
        queue.async {
            self.checkStale()
            self.refresh(manual: manual)
        }
    }

    private func refresh(manual: Bool) {
        guard let metaData = fetch(Self.base + "stores.meta.json"),
              let meta = try? JSONDecoder().decode(StoreMeta.self, from: metaData), let date = meta.date else {
            if manual { Notifier.post("無法取得門市資料，請稍後再試") }
            return
        }
        let have = Stores.meta?.date ?? .distantPast
        guard date > have else {
            if manual { Notifier.post("門市資料已是最新（\(Stores.all.count) 間）") }
            return
        }
        guard let data = fetch(Self.base + "stores.json") else {
            if manual { Notifier.post("無法下載門市資料，請稍後再試") }
            return
        }
        let old = Stores.all
        switch StoreCheck.validate(data, meta: meta, previousCount: old.count) {
        case .failure(let why):
            debugLog("store data rejected: \(why.text)")
            // The CDN can briefly serve a stale stores.json next to a new meta; that fixes itself.
            if manual || rejected != meta.sha256 {
                rejected = meta.sha256
                Notifier.post("下載的門市資料沒有通過檢查（\(why.text)），繼續使用目前的資料")
            }
        case .success(let stores):
            do {
                try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
                try data.write(to: Stores.downloadedURL, options: .atomic)
                try metaData.write(to: Stores.downloadedMetaURL, options: .atomic)
            } catch {
                debugLog("saving store data failed: \(error.localizedDescription)")
            }
            Stores.replace(stores, meta: meta)
            let before = Set(old.map(\.name)), after = Set(stores.map(\.name))
            let text = "門市資料已更新：新增 \(after.subtracting(before).count) 間、移除 \(before.subtracting(after).count) 間（共 \(stores.count) 間）"
            debugLog(text)
            Notifier.post(text)
        }
    }

    private func checkStale() {
        guard let data = fetch(Self.workflowRuns),
              let runs = try? JSONDecoder().decode(Runs.self, from: data) else { return }
        // No successful run yet (e.g. a new fork): nothing to compare against.
        let days = runs.workflow_runs.first
            .flatMap { ISO8601DateFormatter().date(from: $0.updated_at) }
            .map { Int(Date().timeIntervalSince($0) / 86400) }
        DispatchQueue.main.async { self.daysSinceCheck = days }
    }

    /// Text for the menu when the data workflow seems to have stopped.
    var staleWarning: String? {
        guard let d = daysSinceCheck, d > Self.staleDays else { return nil }
        return "⚠️ 門市資料已 \(d) 天沒有檢查"
    }

    private func fetch(_ url: String) -> Data? {
        var request = URLRequest(url: URL(string: url)!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { box.data = data }
            done.signal()
        }.resume()
        done.wait()
        return box.data
    }

    private struct Runs: Decodable {
        struct Run: Decodable { let updated_at: String }
        let workflow_runs: [Run]
    }
}
