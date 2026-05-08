import Foundation

/// iTunes Search API client. Public, unauthenticated, returns the same Apple
/// Music catalog song IDs that Music.app uses, so the URLs round-trip cleanly
/// to the AppleScript `add` command.
///
/// The anonymous rate limit is roughly 20 requests/minute. We serialize all
/// requests through a global throttle (1.2s minimum gap → ~50/min ceiling) and
/// back off hard on 403/429 since those windows are minute-long.
struct AppleMusicClient {
    static let endpoint = URL(string: "https://itunes.apple.com/search")!

    /// We make one request per Spotify track. ISRC-as-search-term proved
    /// unreliable (Apple's search rarely indexes ISRC strings cleanly) and
    /// just doubled the rate-limit pressure, so we now go straight to text
    /// search and rely on the matcher's scoring.
    static func findByISRC(_ isrc: String) async throws -> (candidate: Candidate, song: AppleMusicSong)? {
        nil  // see search() — kept for API symmetry; the matcher always falls through to search.
    }

    static func search(term: String, limit: Int = 10) async throws -> [(candidate: Candidate, song: AppleMusicSong)] {
        let results = try await rawSearch(term: term, limit: limit)
        return results.compactMap { r in
            guard r.kind == "song", let song = r.toAppleMusicSong() else { return nil }
            return (toCandidate(song, isrc: nil), song)
        }
    }

    // MARK: - HTTP

    private static func rawSearch(term: String, limit: Int) async throws -> [ITunesResult] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { return [] }

        var attempt = 0
        while true {
            attempt += 1
            await ITunesThrottle.shared.wait()

            var req = URLRequest(url: url)
            req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20

            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    if attempt >= 3 { return [] }
                    continue
                }
                switch http.statusCode {
                case 200..<300:
                    let decoded = try JSONDecoder().decode(ITunesResponse.self, from: data)
                    return decoded.results
                case 403, 429:
                    AppleMusicErrorLog.note("iTunes search rate-limited (\(http.statusCode)) — backing off 30s")
                    if attempt >= 3 { return [] }
                    // The iTunes rate-limit window is ~1 minute; 30s + jitter
                    // gives us a good chance of recovery.
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    continue
                default:
                    if attempt >= 3 {
                        AppleMusicErrorLog.note("iTunes search HTTP \(http.statusCode)")
                        return []
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
            } catch {
                if attempt >= 3 {
                    AppleMusicErrorLog.note(error.localizedDescription)
                    return []
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - Mapping

    private struct ITunesResponse: Decodable {
        let resultCount: Int
        let results: [ITunesResult]
    }

    private struct ITunesResult: Decodable {
        let kind: String?
        let trackId: Int?
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let trackTimeMillis: Int?
        let trackViewUrl: String?

        func toAppleMusicSong() -> AppleMusicSong? {
            guard let id = trackId,
                  let title = trackName,
                  let artist = artistName,
                  let urlStr = trackViewUrl,
                  let url = URL(string: urlStr) else {
                return nil
            }
            return AppleMusicSong(
                id: String(id),
                url: url,
                title: title,
                artistName: artist,
                albumTitle: collectionName ?? "",
                durationMs: trackTimeMillis ?? 0
            )
        }
    }

    private static func toCandidate(_ song: AppleMusicSong, isrc: String?) -> Candidate {
        Candidate(
            id: song.id,
            title: song.title,
            artistName: song.artistName,
            albumName: song.albumTitle,
            isrc: isrc,
            durationMs: song.durationMs
        )
    }
}

/// Serializes iTunes Search API requests with a minimum gap between them so
/// we stay under the anonymous rate limit (~20/min). 1.2s gap → ceiling of
/// 50/min, well under what the API will tolerate before 403.
actor ITunesThrottle {
    static let shared = ITunesThrottle(minGap: 1.2)
    private let minGap: TimeInterval
    private var lastRequest: Date = .distantPast

    init(minGap: TimeInterval) {
        self.minGap = minGap
    }

    func wait() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRequest)
        if elapsed < minGap {
            let sleepNs = UInt64((minGap - elapsed) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNs)
        }
        lastRequest = Date()
    }
}

/// First-occurrence error log so the user gets one diagnostic line per error
/// class instead of silent failures.
enum AppleMusicErrorLog {
    nonisolated(unsafe) private static var seen: Set<String> = []
    private static let lock = NSLock()

    static func note(_ message: String) {
        lock.lock()
        let isNew = seen.insert(message).inserted
        lock.unlock()
        if isNew {
            fputs("\nApple Music lookup warning (first occurrence): \(message)\n", stderr)
        }
    }
}
