import Foundation
import CryptoKit

/// Disk cache for lyric lookups. Successful documents are kept indefinitely; misses expire.
actor LyricsCache {
    struct Entry: Codable {
        var storedAt: Date
        var document: LyricDocument?
        var instrumental: Bool
    }

    static let missTTL: TimeInterval = 60 * 60 * 24

    let directory: URL
    private var memory: [String: Entry] = [:]

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("Vela/LyricsCache", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: Keys

    /// Stable key from the track's descriptive fields. Case, surrounding whitespace, and
    /// duplicate inner spaces are ignored; duration is rounded to the nearest 2 seconds so that
    /// players reporting slightly different lengths share entries.
    nonisolated static func key(for query: LyricsQuery) -> String {
        func norm(_ s: String) -> String {
            s.lowercased()
                .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        let duration = query.duration.map { Int(($0 / 2).rounded()) * 2 } ?? -1
        let material = [norm(query.artist), norm(query.title), norm(query.album), String(duration)].joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Access

    func lookup(_ query: LyricsQuery) -> LyricsLookup? {
        let key = Self.key(for: query)
        let entry: Entry
        if let cached = memory[key] {
            entry = cached
        } else if let loaded = load(key: key) {
            memory[key] = loaded
            entry = loaded
        } else {
            return nil
        }
        if let document = entry.document {
            var doc = document
            doc.provenance = "cache"
            return .found(doc)
        }
        if entry.instrumental { return .instrumental }
        if Date().timeIntervalSince(entry.storedAt) < Self.missTTL { return .notFound }
        return nil
    }

    func store(_ lookup: LyricsLookup, for query: LyricsQuery) {
        let key = Self.key(for: query)
        let entry: Entry
        switch lookup {
        case .found(let doc): entry = Entry(storedAt: Date(), document: doc, instrumental: false)
        case .instrumental: entry = Entry(storedAt: Date(), document: nil, instrumental: true)
        case .notFound: entry = Entry(storedAt: Date(), document: nil, instrumental: false)
        }
        memory[key] = entry
        save(entry, key: key)
    }

    func remove(_ query: LyricsQuery) {
        let key = Self.key(for: query)
        memory[key] = nil
        try? FileManager.default.removeItem(at: url(for: key))
    }

    func clear() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    private func load(key: String) -> Entry? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Entry.self, from: data)
    }

    private func save(_ entry: Entry, key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: url(for: key), options: .atomic)
    }
}
