import Foundation

/// Synchronized lyrics from the public LRCLIB service (https://lrclib.net). No key required.
struct LRCLIBProvider: LyricsProvider {
    let name = "LRCLIB"
    let isRemote = true

    static let userAgent = "Vela/1.0 (macOS lyric visualizer; https://lrclib.net client)"
    static let baseURL = URL(string: "https://lrclib.net/api")!

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 15
            config.waitsForConnectivity = false
            config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
            self.session = URLSession(configuration: config)
        }
    }

    struct Record: Decodable {
        var id: Int?
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    func lyrics(for query: LyricsQuery) async throws -> LyricsLookup {
        guard !query.title.isEmpty, !query.artist.isEmpty else { return .notFound }
        // 1. Exact match by signature.
        if let record = try await fetchExact(query) {
            return Self.lookup(from: record)
        }
        // 2. Fallback search, pick the closest duration.
        let candidates = try await search(query)
        if let best = Self.bestMatch(in: candidates, for: query) {
            return Self.lookup(from: best)
        }
        return .notFound
    }

    // MARK: Requests

    private func fetchExact(_ query: LyricsQuery) async throws -> Record? {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("get"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ]
        if !query.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: query.album)) }
        if let duration = query.duration { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        components.queryItems = items
        let (data, status) = try await perform(components.url!)
        if status == 404 { return nil }
        guard status == 200 else { throw LyricsProviderError.badResponse(status) }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func search(_ query: LyricsQuery) async throws -> [Record] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ]
        let (data, status) = try await perform(components.url!)
        guard status == 200 else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private func perform(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch let error as URLError where error.code == .cancelled {
            throw LyricsProviderError.cancelled
        } catch {
            throw LyricsProviderError.network(error.localizedDescription)
        }
    }

    // MARK: Matching

    static func bestMatch(in records: [Record], for query: LyricsQuery) -> Record? {
        let usable = records.filter { $0.syncedLyrics?.isEmpty == false || $0.plainLyrics?.isEmpty == false || $0.instrumental == true }
        guard !usable.isEmpty else { return nil }
        func score(_ r: Record) -> Double {
            var s = 0.0
            if let d = r.duration, let want = query.duration {
                let diff = abs(d - want)
                if diff > 6 { return -1 }
                s += 10 - diff
            }
            if r.syncedLyrics?.isEmpty == false { s += 5 }
            if let name = r.trackName, name.lowercased() == query.title.lowercased() { s += 3 }
            if let artist = r.artistName, artist.lowercased() == query.artist.lowercased() { s += 3 }
            return s
        }
        let scored = usable.map { ($0, score($0)) }.filter { $0.1 >= 0 }
        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    static func lookup(from record: Record) -> LyricsLookup {
        if record.instrumental == true { return .instrumental }
        if let synced = record.syncedLyrics, !synced.isEmpty, var doc = LRCParser.parse(synced) {
            doc.provenance = "lrclib"
            return .found(doc)
        }
        if let plain = record.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .found(LRCParser.plain(plain, provenance: "lrclib"))
        }
        return .notFound
    }
}
