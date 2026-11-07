import Foundation

/// 撮影情報のローカルログ。写真ライブラリの asset のローカル識別子と紐づけて保存する。
/// 端末外へ送信することはない（Documents 配下の JSON のみ）。
final class CaptureLogStore {

    static let shared = CaptureLogStore()

    private let queue = DispatchQueue(label: "jp.oniichan.camera.capturelog")
    private var records: [String: CaptureRecord] = [:]
    private let fileURL: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = documents.appendingPathComponent("capture-log.json")
        load()
    }

    func add(_ record: CaptureRecord) {
        queue.sync {
            records[record.id] = record
            saveLocked()
        }
    }

    func record(forLocalIdentifier identifier: String) -> CaptureRecord? {
        queue.sync { records[identifier] }
    }

    func recentRecords(limit: Int = 50) -> [CaptureRecord] {
        queue.sync {
            Array(records.values.sorted { $0.date > $1.date }.prefix(limit))
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: CaptureRecord].self, from: data) {
            records = decoded
        }
    }

    private func saveLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 記録は最新 500 件に制限する
        if records.count > 500 {
            let trimmed = records.values.sorted { $0.date > $1.date }.prefix(500)
            records = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.id, $0) })
        }
        if let data = try? encoder.encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
