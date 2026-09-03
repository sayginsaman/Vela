import Foundation

enum LyricsOutcome: Sendable, Equatable {
    case found(LyricDocument)
    case instrumental
    case notFound
    case offline
    case failed(String)
}

/// Resolves lyrics for a track by consulting providers in order and caching the answer.
///
/// Order: user-imported file → bundled demo lyrics → disk cache → remote providers.
/// Every step checks for cancellation so a track change abandons the lookup promptly.
actor LyricsService {
    let cache: LyricsCache
    let localStore: LocalLyricsStore
    private let bundled: [LyricsProvider]
    private let remote: [LyricsProvider]
    private let isOnline: @Sendable () -> Bool

    init(cache: LyricsCache, localStore: LocalLyricsStore,
         bundled: [LyricsProvider] = [DemoLyricsProvider()],
         remote: [LyricsProvider] = [LRCLIBProvider()],
         isOnline: @escaping @Sendable () -> Bool = { NetworkMonitor.shared.isOnline }) {
        self.cache = cache
        self.localStore = localStore
        self.bundled = bundled
        self.remote = remote
        self.isOnline = isOnline
    }

    func resolve(track: TrackInfo) async -> LyricsOutcome {
        let query = LyricsQuery(track: track)

        if let imported = await localStore.document(for: query) { return .found(imported) }
        if Task.isCancelled { return .failed("cancelled") }

        for provider in bundled {
            if let outcome = await consult(provider, query: query, storeInCache: false) { return outcome }
            if Task.isCancelled { return .failed("cancelled") }
        }

        if let cached = await cache.lookup(query) {
            switch cached {
            case .found(let doc): return .found(doc)
            case .instrumental: return .instrumental
            case .notFound: return .notFound
            }
        }

        guard isOnline() else { return .offline }
        var lastFailure: String?
        for provider in remote {
            if Task.isCancelled { return .failed("cancelled") }
            do {
                let lookup = try await provider.lyrics(for: query)
                if Task.isCancelled { return .failed("cancelled") }
                await cache.store(lookup, for: query)
                switch lookup {
                case .found(let doc): return .found(doc)
                case .instrumental: return .instrumental
                case .notFound: continue
                }
            } catch LyricsProviderError.cancelled {
                return .failed("cancelled")
            } catch {
                lastFailure = "\(provider.name): \(error)"
                continue
            }
        }
        if let lastFailure { return .failed(lastFailure) }
        return .notFound
    }

    private func consult(_ provider: LyricsProvider, query: LyricsQuery, storeInCache: Bool) async -> LyricsOutcome? {
        guard let lookup = try? await provider.lyrics(for: query) else { return nil }
        switch lookup {
        case .found(let doc): return .found(doc)
        case .instrumental: return .instrumental
        case .notFound: return nil
        }
    }

    /// Imports a `.lrc`/`.txt` file for the given track and returns the parsed document.
    func importLyrics(from url: URL, for track: TrackInfo) async throws -> LyricDocument {
        let query = LyricsQuery(track: track)
        let document = try await localStore.importFile(at: url, for: query)
        return document
    }

    func forget(track: TrackInfo) async {
        let query = LyricsQuery(track: track)
        await cache.remove(query)
    }

    func clearCache() async {
        await cache.clear()
    }
}
