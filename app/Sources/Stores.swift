import CoreLocation
import CryptoKit
import Foundation

struct Store: Codable {
    let name: String
    let address: String
    let phone: String
    let lat: Double
    let lng: Double
    /// Wi-Fi password candidates derived from the phone number, most likely first.
    let passwords: [String]

    var city: String {
        String(address.split(separator: " ").first ?? "其他").replacingOccurrences(of: "臺", with: "台")
    }
    var location: CLLocation? { lat == 0 ? nil : CLLocation(latitude: lat, longitude: lng) }
}

/// data/stores.meta.json: when the data was published, how many stores, and its SHA-256.
struct StoreMeta: Codable {
    let updated: String
    let count: Int
    let sha256: String

    var date: Date? { ISO8601DateFormatter().date(from: updated) }
}

enum Stores {
    private static let lock = NSLock()
    private static var current: (stores: [Store], meta: StoreMeta?) = loadInitial()

    static var all: [Store] { lock.lock(); defer { lock.unlock() }; return current.stores }
    static var meta: StoreMeta? { lock.lock(); defer { lock.unlock() }; return current.meta }

    /// Swap in newly downloaded data; menus and auto-connect pick it up on their next read.
    static func replace(_ stores: [Store], meta: StoreMeta) {
        lock.lock(); defer { lock.unlock() }
        current = (stores, meta)
    }

    static let downloadedURL = supportDir.appendingPathComponent("stores.json")
    static let downloadedMetaURL = supportDir.appendingPathComponent("stores.meta.json")

    /// The built-in data, unless a downloaded copy is newer and still passes the checks.
    private static func loadInitial() -> (stores: [Store], meta: StoreMeta?) {
        let bundled = Bundle.main.url(forResource: "stores", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([Store].self, from: $0) } ?? []
        let bundledMeta = Bundle.main.url(forResource: "stores.meta", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(StoreMeta.self, from: $0) }

        if let data = try? Data(contentsOf: downloadedURL),
           let metaData = try? Data(contentsOf: downloadedMetaURL),
           let meta = try? JSONDecoder().decode(StoreMeta.self, from: metaData),
           let date = meta.date, date > (bundledMeta?.date ?? .distantPast) {
            switch StoreCheck.validate(data, meta: meta, previousCount: nil) {
            case .success(let stores): return (stores, meta)
            case .failure(let why): debugLog("ignoring downloaded store data: \(why.text)")
            }
        }
        return (bundled, bundledMeta)
    }

    static func named(_ name: String) -> Store? { all.first { $0.name == name } }

    static func nearest(to here: CLLocation, limit: Int, in stores: [Store] = all) -> [(store: Store, meters: Double)] {
        let ranked = stores.compactMap { s in s.location.map { (store: s, meters: $0.distance(from: here)) } }
        return Array(ranked.sorted { $0.meters < $1.meters }.prefix(limit))
    }

    private static let cityOrder = ["台北市", "新北市", "基隆市", "桃園市", "新竹市", "新竹縣", "苗栗縣", "台中市",
                                    "彰化縣", "南投縣", "雲林縣", "嘉義市", "嘉義縣", "台南市", "高雄市", "屏東縣",
                                    "宜蘭縣", "花蓮縣", "台東縣", "澎湖縣", "金門縣", "連江縣"]

    static func byCity(_ stores: [Store] = all) -> [(city: String, stores: [Store])] {
        let rank = { (c: String) in cityOrder.firstIndex(of: c) ?? cityOrder.count }
        return Dictionary(grouping: stores, by: \.city)
            .sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
            .map { (city: $0.key, stores: $0.value.sorted { $0.name < $1.name }) }
    }
}

/// The hard checks from scripts/check_stores.py, repeated before downloaded data is used.
enum StoreCheck {
    struct Failure: Error { let text: String }

    static let maxBytes = 1_000_000
    static let minStores = 400
    static let minRatio = 0.9
    static let maxNoCoords = 0.15

    static func validate(_ data: Data, meta: StoreMeta, previousCount: Int?) -> Result<[Store], Failure> {
        func fail(_ s: String) -> Result<[Store], Failure> { .failure(Failure(text: s)) }
        guard data.count < maxBytes else { return fail("檔案太大（\(data.count) bytes）") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == meta.sha256.lowercased() else { return fail("SHA-256 和 meta 不符") }
        guard let stores = try? JSONDecoder().decode([Store].self, from: data) else { return fail("JSON 格式不正確") }
        guard stores.count == meta.count else { return fail("筆數和 meta 不符") }
        guard stores.count >= minStores else { return fail("只有 \(stores.count) 間門市") }
        if let previous = previousCount, Double(stores.count) < minRatio * Double(previous) {
            return fail("只有 \(stores.count) 間門市，上一版有 \(previous) 間")
        }
        let names = stores.map { $0.name.trimmingCharacters(in: .whitespaces) }
        guard !names.contains(""), Set(names).count == names.count else { return fail("門市名稱空白或重複") }
        for s in stores {
            guard !s.passwords.isEmpty else { return fail("\(s.name) 沒有密碼候選") }
            for p in s.passwords where !(8...63).contains(p.count) || !p.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return fail("\(s.name) 的密碼候選格式不正確")
            }
            let none = s.lat == 0 && s.lng == 0
            guard none || (21 < s.lat && s.lat < 26.5 && 118 < s.lng && s.lng < 122.5) else {
                return fail("\(s.name) 的座標不在台灣")
            }
        }
        let noCoords = stores.filter { $0.lat == 0 && $0.lng == 0 }.count
        guard Double(noCoords) <= maxNoCoords * Double(stores.count) else { return fail("沒有座標的門市太多") }
        return .success(stores)
    }
}
