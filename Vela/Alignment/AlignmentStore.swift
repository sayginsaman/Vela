import Foundation

/// Keeps aligned lyric documents on disk, keyed like the lyrics cache, so a song only has to be
/// listened to once. The next play starts with real word timings.
actor AlignmentStore {
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("Vela/Alignments", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    struct Entry: Codable {
        var document: LyricDocument
        var anchoredFraction: Double
        var storedAt: Date
    }

    private func url(for query: LyricsQuery) -> URL {
        directory.appendingPathComponent(LyricsCache.key(for: query) + ".json")
    }

    func entry(for query: LyricsQuery) -> Entry? {
        guard let data = try? Data(contentsOf: url(for: query)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Entry.self, from: data)
    }

    /// Only ever replaces a stored alignment with a better one.
    func store(_ document: LyricDocument, anchoredFraction: Double, for query: LyricsQuery) {
        if let existing = entry(for: query), existing.anchoredFraction >= anchoredFraction { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let entry = Entry(document: document, anchoredFraction: anchoredFraction, storedAt: Date())
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: url(for: query), options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
