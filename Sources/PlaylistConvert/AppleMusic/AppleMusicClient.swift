import Foundation
import MusicKit

/// MusicKit-backed implementation of catalog lookup and playlist creation.
/// Translates MusicKit `Song` values into the service-agnostic `Candidate` shape
/// expected by `Matcher`.
struct AppleMusicClient {
    /// Look up a song by ISRC.
    static func findByISRC(_ isrc: String) async throws -> (candidate: Candidate, song: Song)? {
        let request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
        let response = try await retry { try await request.response() }
        guard let song = response.items.first else { return nil }
        return (toCandidate(song), song)
    }

    /// Text search returning up to `limit` candidates plus the underlying songs.
    static func search(term: String, limit: Int = 10) async throws -> [(candidate: Candidate, song: Song)] {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = limit
        let response = try await retry { try await request.response() }
        return response.songs.map { song in (toCandidate(song), song) }
    }

    /// `CatalogLookup` exposed to `Matcher` — discards the underlying `Song` since
    /// the matcher only needs scoring data. Use the granular methods above when
    /// you also need the Song to create playlists.
    static let catalogLookup = CatalogLookup(
        byISRC: { isrc in
            try await findByISRC(isrc)?.candidate
        },
        search: { term in
            try await search(term: term).map(\.candidate)
        }
    )

    private static func toCandidate(_ song: Song) -> Candidate {
        let durationMs = Int(((song.duration ?? 0) * 1000).rounded())
        return Candidate(
            id: song.id.rawValue,
            title: song.title,
            artistName: song.artistName,
            albumName: song.albumTitle ?? "",
            isrc: song.isrc,
            durationMs: durationMs
        )
    }

    /// Retry MusicKit calls with exponential backoff + jitter, capped at 5 attempts.
    /// MusicKit can return transient errors during batch operations.
    private static func retry<T>(_ block: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await block()
            } catch {
                if attempt >= 5 {
                    throw error
                }
                let backoff = pow(2.0, Double(attempt)) + Double.random(in: 0...0.5)
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }
}
