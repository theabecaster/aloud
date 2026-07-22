import Foundation

// Recent transcriptions, local JSON only. User-clearable from Settings.
struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let text: String             // what was typed (after clean-up)
    let rawText: String?         // exact model output, when it differs
    let duration: TimeInterval   // spoken audio seconds

    init(text: String, rawText: String? = nil, duration: TimeInterval, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.text = text
        self.rawText = (rawText == text) ? nil : rawText
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
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
                entries = decoded
            } else {
                // Unreadable (corrupt or future-schema) history must not be
                // silently zeroed by the next persist — set it aside instead.
                try? data.write(to: fileURL.appendingPathExtension("bak"), options: .atomic)
                entries = []
            }
        } else {
            entries = []
        }
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
