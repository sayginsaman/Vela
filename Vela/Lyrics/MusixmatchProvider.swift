import Foundation

/// Word-by-word lyrics from Musixmatch, using a key the user supplies themselves.
///
/// Vela ships no key: word-level ("richsync") access is a commercial plan, and a key embedded in
/// an open-source app would be everybody's key. Someone with their own key can paste it into
/// Settings, where it is stored in the login keychain and used only for their own lookups.
struct MusixmatchProvider: LyricsProvider {
    static let keychainAccount = "musixmatch.apiKey"
    static let base = URL(string: "https://api.musixmatch.com/ws/1.1")!

    let name = "Musixmatch"
    let isRemote = true

    private let session: URLSession
    private let key: @Sendable () -> String?

    init(session: URLSession? = nil, key: @escaping @Sendable () -> String? = { KeychainStore.get(account: MusixmatchProvider.keychainAccount) }) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.waitsForConnectivity = false
            config.httpAdditionalHeaders = ["User-Agent": LRCLIBProvider.userAgent]
            self.session = URLSession(configuration: config)
        }
        self.key = key
    }

    var isConfigured: Bool { key() != nil }

    func lyrics(for query: LyricsQuery) async throws -> LyricsLookup {
        guard let apiKey = key(), !query.title.isEmpty, !query.artist.isEmpty else { return .notFound }
        guard let match = try await matcher(query, apiKey: apiKey) else { return .notFound }
        if match.instrumental { return .instrumental }
        guard let body = try await richsync(trackID: match.trackID, apiKey: apiKey),
              let document = Self.parseRichsync(body) else { return .notFound }
        return .found(document)
    }

    /// Verifies a key by asking for something cheap, so Settings can say whether it works.
    func validate(key apiKey: String) async -> String? {
        var components = URLComponents(url: Self.base.appendingPathComponent("matcher.track.get"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q_track", value: "Yesterday"),
            URLQueryItem(name: "q_artist", value: "The Beatles"),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        do {
            let (data, status) = try await perform(components.url!)
            guard status == 200 else { return "Musixmatch returned HTTP \(status)." }
            let code = Self.statusCode(in: data)
            switch code {
            case 200, 404: return nil                      // 404 just means no match for the probe
            case 401: return "That key was rejected (401)."
            case 402: return "That key has no quota left, or the plan does not cover this (402)."
            case 403: return "That key is not allowed to use this endpoint (403)."
            default: return code.map { "Musixmatch returned status \($0)." } ?? "Unexpected response from Musixmatch."
            }
        } catch {
            return "Could not reach Musixmatch: \(error.localizedDescription)"
        }
    }

    // MARK: Requests

    private struct Match { var trackID: Int; var instrumental: Bool }

    private func matcher(_ query: LyricsQuery, apiKey: String) async throws -> Match? {
        var components = URLComponents(url: Self.base.appendingPathComponent("matcher.track.get"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "q_track", value: query.title),
            URLQueryItem(name: "q_artist", value: query.artist),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        if !query.album.isEmpty { items.append(URLQueryItem(name: "q_album", value: query.album)) }
        components.queryItems = items
        let (data, status) = try await perform(components.url!)
        guard status == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let body = message["body"] as? [String: Any],
              let track = body["track"] as? [String: Any],
              let id = track["track_id"] as? Int else { return nil }
        let instrumental = (track["instrumental"] as? Int) == 1
        return Match(trackID: id, instrumental: instrumental)
    }

    private func richsync(trackID: Int, apiKey: String) async throws -> String? {
        var components = URLComponents(url: Self.base.appendingPathComponent("track.richsync.get"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_id", value: String(trackID)),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        let (data, status) = try await perform(components.url!)
        guard status == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let body = message["body"] as? [String: Any],
              let richsync = body["richsync"] as? [String: Any],
              let payload = richsync["richsync_body"] as? String, !payload.isEmpty else { return nil }
        return payload
    }

    private func perform(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue(LRCLIBProvider.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .cancelled {
            throw LyricsProviderError.cancelled
        } catch {
            throw LyricsProviderError.network(error.localizedDescription)
        }
    }

    static func statusCode(in data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let header = message["header"] as? [String: Any] else { return nil }
        return (header["status_code"] as? Int) ?? (header["status_code"] as? Double).map(Int.init)
    }

    // MARK: Parsing

    /// The richsync body is JSON: one entry per line with a start `ts`, an end `te`, and `l`,
    /// the chunks of the line each carrying an offset `o` from `ts`.
    static func parseRichsync(_ payload: String) -> LyricDocument? {
        guard let data = payload.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !rows.isEmpty else { return nil }
        var lines: [LyricLine] = []
        var wordID = 0
        for row in rows {
            guard let start = number(row["ts"]), let end = number(row["te"]),
                  let chunks = row["l"] as? [[String: Any]] else { continue }
            var words: [TimedWord] = []
            var pending: (text: String, start: TimeInterval)?
            func flush(until moment: TimeInterval) {
                guard let current = pending else { return }
                let text = current.text.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    words.append(TimedWord(id: wordID, text: text, start: current.start,
                                           end: max(current.start, moment), isEstimated: false))
                    wordID += 1
                }
                pending = nil
            }
            for chunk in chunks {
                guard let text = chunk["c"] as? String, let offset = number(chunk["o"]) else { continue }
                let moment = start + offset
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    // A whitespace chunk closes the word that came before it.
                    flush(until: moment)
                } else if pending == nil {
                    pending = (text, moment)
                } else {
                    pending?.text += text
                }
            }
            flush(until: end)
            guard !words.isEmpty else { continue }
            lines.append(LyricLine(id: lines.count, text: words.map(\.text).joined(separator: " "),
                                   start: min(start, words[0].start), end: max(end, words[words.count - 1].end),
                                   words: words))
        }
        guard !lines.isEmpty else { return nil }
        return LyricDocument(lines: lines, quality: .wordSynced, isInstrumental: false, provenance: "musixmatch")
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return TimeInterval(int) }
        if let string = value as? String { return TimeInterval(string) }
        return nil
    }
}
