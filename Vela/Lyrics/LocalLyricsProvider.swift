import Foundation

/// Lyrics the user imported as `.lrc` files. Stored per-track under Application Support so the
/// import survives relaunches. Also honours a plain `.txt` for unsynced lyrics.
actor LocalLyricsStore {
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("Vela/ImportedLyrics", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func url(for query: LyricsQuery) -> URL {
        directory.appendingPathComponent(LyricsCache.key(for: query) + ".lrc")
    }

    func document(for query: LyricsQuery) -> LyricDocument? {
        guard let text = try? String(contentsOf: url(for: query), encoding: .utf8) else { return nil }
        return Self.parse(text)
    }

    func hasImport(for query: LyricsQuery) -> Bool {
        FileManager.default.fileExists(atPath: url(for: query).path)
    }

    /// Copies the file contents into the store and returns the parsed document.
    @discardableResult
    func importFile(at fileURL: URL, for query: LyricsQuery) throws -> LyricDocument {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        guard let document = Self.parse(text) else { throw CocoaError(.fileReadCorruptFile) }
        try text.write(to: url(for: query), atomically: true, encoding: .utf8)
        return document
    }

    func removeImport(for query: LyricsQuery) {
        try? FileManager.default.removeItem(at: url(for: query))
    }

    nonisolated static func parse(_ text: String) -> LyricDocument? {
        if var doc = LRCParser.parse(text) {
            doc.provenance = "local"
            return doc
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return LRCParser.plain(trimmed, provenance: "local")
    }
}

struct LocalLyricsProvider: LyricsProvider {
    let name = "Imported"
    let isRemote = false
    let store: LocalLyricsStore

    func lyrics(for query: LyricsQuery) async throws -> LyricsLookup {
        if let doc = await store.document(for: query) { return .found(doc) }
        return .notFound
    }
}
