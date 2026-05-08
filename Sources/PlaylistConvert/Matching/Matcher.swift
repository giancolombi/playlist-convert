import Foundation

/// A catalog candidate from Apple Music, normalized into a service-agnostic
/// shape so the matcher can be tested with synthetic data instead of hitting
/// the iTunes Search API.
struct Candidate: Equatable {
    let id: String
    let title: String
    let artistName: String
    let albumName: String
    let isrc: String?
    let durationMs: Int
}

/// Async closures the matcher uses to look up the catalog. Production wires
/// these to AppleMusicClient (iTunes Search API); tests pass synchronous
/// in-memory ones.
struct CatalogLookup {
    var byISRC: (String) async throws -> Candidate?
    var search: (String) async throws -> [Candidate]
}

struct ScoredMatch {
    let candidate: Candidate
    let score: Double
    let titleScore: Double
    let artistScore: Double
    let durationScore: Double
}

enum Matcher {
    /// Score range is 0–100 to align with the user-facing --match-threshold flag.
    /// Title 50, artist 35, duration 15.
    static func score(track: SpotifyTrack, candidate: Candidate) -> ScoredMatch {
        let normTrackTitle = Normalizer.normalize(track.name)
        let normCandTitle = Normalizer.normalize(candidate.title)
        let titleSim = StringSimilarity.ratio(normTrackTitle, normCandTitle)

        let normCandArtist = Normalizer.normalize(candidate.artistName)
        let bestArtistSim = track.artists.map { artist -> Double in
            StringSimilarity.ratio(Normalizer.normalize(artist), normCandArtist)
        }.max() ?? 0

        let durationSim = durationSimilarity(spotifyMs: track.durationMs, candidateMs: candidate.durationMs)

        let total = (titleSim * 50) + (bestArtistSim * 35) + (durationSim * 15)
        return ScoredMatch(
            candidate: candidate,
            score: total,
            titleScore: titleSim,
            artistScore: bestArtistSim,
            durationScore: durationSim
        )
    }

    /// ≤3000ms diff → 1.0; linear penalty out to 15000ms; 0 beyond.
    static func durationSimilarity(spotifyMs: Int, candidateMs: Int) -> Double {
        if spotifyMs == 0 || candidateMs == 0 { return 0.5 }  // unknown — neutral
        let diff = Double(abs(spotifyMs - candidateMs))
        if diff <= 3000 { return 1.0 }
        if diff >= 15000 { return 0.0 }
        return 1.0 - ((diff - 3000) / 12000.0)
    }

    /// Tiered match: ISRC → text search → score. Returns the best result and the tier
    /// it came from. The caller decides whether the score meets --match-threshold.
    static func match(
        track: SpotifyTrack,
        threshold: Double,
        lookup: CatalogLookup
    ) async throws -> (result: MatchResult, bestScored: ScoredMatch?) {
        if let isrc = track.isrc, !isrc.isEmpty {
            if let candidate = try await lookup.byISRC(isrc) {
                let scored = score(track: track, candidate: candidate)
                let result = MatchResult(
                    track: track,
                    tier: .isrc,
                    appleSongID: candidate.id,
                    score: scored.score,
                    bestCandidateTitle: candidate.title,
                    bestCandidateArtist: candidate.artistName,
                    reason: nil
                )
                return (result, scored)
            }
        }

        let term = textSearchTerm(for: track)
        let candidates = try await lookup.search(term)
        guard let best = candidates
            .map({ score(track: track, candidate: $0) })
            .max(by: { $0.score < $1.score })
        else {
            let result = MatchResult(
                track: track,
                tier: .unmatched,
                appleSongID: nil,
                score: 0,
                bestCandidateTitle: nil,
                bestCandidateArtist: nil,
                reason: "no search results"
            )
            return (result, nil)
        }

        if best.score >= threshold {
            let result = MatchResult(
                track: track,
                tier: .search,
                appleSongID: best.candidate.id,
                score: best.score,
                bestCandidateTitle: best.candidate.title,
                bestCandidateArtist: best.candidate.artistName,
                reason: nil
            )
            return (result, best)
        }

        let result = MatchResult(
            track: track,
            tier: .unmatched,
            appleSongID: nil,
            score: best.score,
            bestCandidateTitle: best.candidate.title,
            bestCandidateArtist: best.candidate.artistName,
            reason: String(format: "below threshold (%.1f < %.1f)", best.score, threshold)
        )
        return (result, best)
    }

    static func textSearchTerm(for track: SpotifyTrack) -> String {
        let title = Normalizer.normalize(track.name)
        let artist = Normalizer.normalize(track.primaryArtist)
        if artist.isEmpty { return title }
        return "\(title) \(artist)"
    }
}
