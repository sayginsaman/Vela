import Foundation

/// Where the AMLL catalogue is read from. Injectable so tests never touch the network.
protocol AMLLDataSource: Sendable {
    /// The newline-delimited JSON index of every contributed song.
    func index() async throws -> Data
    /// One TTML lyric file from `raw-lyrics/`.
    func lyrics(file: String) async throws -> Data
}

/// Reads the catalogue straight from the public repository. No key, no token; the index is
/// cached on disk and refreshed once a day.
struct AMLLGitHubSource: AMLLDataSource {
    static let base = URL(string: "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main")!
    static let indexTTL: TimeInterval = 60 * 60 * 24
    static let maximumIndexBytes = 32 * 1024 * 1024

    private let session: URLSession
    private let cacheURL: URL

    init(session: URLSession? = nil, cacheDirectory: URL? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 45
            config.waitsForConnectivity = false
            config.httpAdditionalHeaders = ["User-Agent": LRCLIBProvider.userAgent]
            self.session = URLSession(configuration: config)
        }
        let base = cacheDirectory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("Vela/AMLL", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        cacheURL = base.appendingPathComponent("raw-lyrics-index.jsonl")
    }

    func index() async throws -> Data {
        if let cached = freshCache() { return cached }
        do {
            let data = try await fetch(Self.base.appendingPathComponent("metadata/raw-lyrics-index.jsonl"))
            guard data.count <= Self.maximumIndexBytes else { throw LyricsProviderError.decoding }
            try? data.write(to: cacheURL, options: .atomic)
            return data
        } catch {
            // A stale index is far better than none; the catalogue only ever grows.
            if let stale = try? Data(contentsOf: cacheURL), !stale.isEmpty { return stale }
            throw error
        }
    }

    func lyrics(file: String) async throws -> Data {
        // The index supplies the name; keep it to a single path component regardless.
        let name = (file as NSString).lastPathComponent
        guard !name.isEmpty else { throw LyricsProviderError.decoding }
        return try await fetch(Self.base.appendingPathComponent("raw-lyrics").appendingPathComponent(name))
    }

    private func freshCache() -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < Self.indexTTL,
              let data = try? Data(contentsOf: cacheURL), !data.isEmpty else { return nil }
        return data
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(LRCLIBProvider.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw LyricsProviderError.badResponse(status) }
            return data
        } catch let error as URLError where error.code == .cancelled {
            throw LyricsProviderError.cancelled
        } catch let error as LyricsProviderError {
            throw error
        } catch {
            throw LyricsProviderError.network(error.localizedDescription)
        }
    }
}

/// The AMLL index, parsed once and kept in memory for the lifetime of the process.
actor AMLLCatalogue {
    struct Entries: Sendable, Equatable {
        var bySpotifyID: [String: String] = [:]
        var byTitleArtist: [String: String] = [:]
        var count = 0
    }

    private let source: AMLLDataSource
    private var entries: Entries?
    private var loadTask: Task<Entries, Error>?

    init(source: AMLLDataSource) {
        self.source = source
    }

    /// Name of the TTML file for this track, or `nil` when the catalogue does not have it.
    func lyricFile(for query: LyricsQuery) async throws -> String? {
        let entries = try await load()
        if let id = query.spotifyTrackID, let file = entries.bySpotifyID[id] { return file }
        return entries.byTitleArtist[Self.key(title: query.title, artist: query.artist)]
    }

    private func load() async throws -> Entries {
        if let entries { return entries }
        if let loadTask { return try await loadTask.value }
        let task = Task { [source] in Self.parse(try await source.index()) }
        loadTask = task
        do {
            let result = try await task.value
            entries = result
            loadTask = nil
            return result
        } catch {
            loadTask = nil
            throw error
        }
    }

    /// The index is newline-delimited JSON: one object per contributed song, whose `metadata` is
    /// an array of `[key, [values]]` pairs.
    static func parse(_ data: Data) -> Entries {
        var entries = Entries()
        guard let text = String(data: data, encoding: .utf8) else { return entries }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let file = object["rawLyricFile"] as? String, !file.isEmpty,
                  let metadata = object["metadata"] as? [[Any]] else { continue }
            var fields: [String: [String]] = [:]
            for pair in metadata {
                guard pair.count == 2, let key = pair[0] as? String else { continue }
                let values = (pair[1] as? [String]) ?? (pair[1] as? String).map { [$0] } ?? []
                fields[key, default: []].append(contentsOf: values)
            }
            entries.count += 1
            for id in fields["spotifyId"] ?? [] where !id.isEmpty {
                if entries.bySpotifyID[id] == nil { entries.bySpotifyID[id] = file }
            }
            for title in fields["musicName"] ?? [] {
                for artist in fields["artists"] ?? [] {
                    let key = key(title: title, artist: artist)
                    if entries.byTitleArtist[key] == nil { entries.byTitleArtist[key] = file }
                }
            }
        }
        return entries
    }

    /// Both title and artist must agree, so a cover or a remix is never served by mistake.
    static func key(title: String, artist: String) -> String {
        func normalise(_ value: String) -> String {
            value.lowercased()
                .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .joined(separator: " ")
        }
        return normalise(artist) + "|" + normalise(title)
    }
}

/// Word-by-word lyrics from the community AMLL TTML database (CC0, no API key).
///
/// Coverage is a few thousand songs rather than everything, so this sits ahead of LRCLIB and
/// simply reports `notFound` when the catalogue does not have the track.
struct AMLLProvider: LyricsProvider {
    let name = "AMLL"
    let isRemote = true
    private let catalogue: AMLLCatalogue
    private let source: AMLLDataSource

    init(source: AMLLDataSource = AMLLGitHubSource()) {
        self.source = source
        catalogue = AMLLCatalogue(source: source)
    }

    func lyrics(for query: LyricsQuery) async throws -> LyricsLookup {
        guard !query.title.isEmpty, !query.artist.isEmpty || query.spotifyTrackID != nil else { return .notFound }
        guard let file = try await catalogue.lyricFile(for: query) else { return .notFound }
        let data = try await source.lyrics(file: file)
        guard let document = TTMLParser.parse(data, provenance: "amll") else { throw LyricsProviderError.decoding }
        return .found(document)
    }
}
