import Foundation

struct TranscriptionHistoryEntry: Codable, Identifiable, Equatable {
    var id: String { filePath }
    let fileName: String
    let filePath: String
    let outputDir: String
    let engine: String
    let modelID: String
    let date: Date
    let duration: TimeInterval?
    let segmentCount: Int
    let speakerCount: Int
    let audioPath: String?

    var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    var outputFiles: [URL] {
        let dir = URL(fileURLWithPath: outputDir)
        let base = (fileName as NSString).deletingPathExtension
        return [
            dir.appendingPathComponent("\(base)_通话记录.md"),
            dir.appendingPathComponent("\(base)_funasr.json"),
            dir.appendingPathComponent("\(base)_speaker_map.json"),
            dir.appendingPathComponent("\(base)_整理版.md"),
            dir.appendingPathComponent("\(base)_摘要.md"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

@MainActor
class HistoryManager: ObservableObject {
    @Published var entries: [TranscriptionHistoryEntry] = []

    private let key = "transcriptionHistory"
    private let maxEntries = 200

    init() {
        load()
    }

    func add(_ entry: TranscriptionHistoryEntry) {
        entries.removeAll { $0.filePath == entry.filePath }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func remove(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    func remove(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TranscriptionHistoryEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
