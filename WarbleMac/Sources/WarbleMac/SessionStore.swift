import Foundation

/// Reads/writes the persisted session list as JSON under Application Support,
/// so threads and their per-session config survive a relaunch. Generic over the
/// Codable snapshot type so it stays trivially unit-testable with a temp file.
struct SessionStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.fileURL = base.appendingPathComponent("Warble/sessions.json")
        }
    }

    func load<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence is best-effort: a failed write shouldn't take down the
            // running app — the in-memory sessions stay usable for this run.
        }
    }
}
