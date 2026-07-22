import Foundation

// Recent transcriptions, local JSON only. User-clearable from Settings.
struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let text: String
    let duration: TimeInterval   // spoken audio seconds

    init(text: String, duration: TimeInterval, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.text = text
        self.duration = duration
    }
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL
    private let queue = DispatchQueue(label: "aloud.history")

    init(fileURL: URL = AppPaths.historyFile) {
        self.fileURL = fileURL
        entries = (try? JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: fileURL))) ?? []
    }

    func append(_ entry: HistoryEntry, limit: Int) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        let snapshot = entries
        let url = fileURL
        queue.async {
            AppPaths.ensureStateDir()
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
