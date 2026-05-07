import XCTest
@testable import PlaylistConvert

final class MatchingTests: XCTestCase {
    private func makeTrack(
        name: String,
        artists: [String] = ["The Weeknd"],
        isrc: String? = "USRC12345678",
        durationMs: Int = 200_000
    ) -> SpotifyTrack {
        SpotifyTrack(
            id: "spotify-\(UUID().uuidString)",
            name: name,
            artists: artists,
            albumName: "Album",
            isrc: isrc,
            durationMs: durationMs
        )
    }

    private func makeCandidate(
        id: String = "am-\(UUID().uuidString)",
        title: String,
        artistName: String = "The Weeknd",
        isrc: String? = nil,
        durationMs: Int = 200_000
    ) -> Candidate {
        Candidate(
            id: id,
            title: title,
            artistName: artistName,
            albumName: "Album",
            isrc: isrc,
            durationMs: durationMs
        )
    }

    func testISRCTierUsedWhenAvailable() async throws {
        let track = makeTrack(name: "Blinding Lights")
        let cand = makeCandidate(title: "Blinding Lights")

        let lookup = CatalogLookup(
            byISRC: { isrc in
                XCTAssertEqual(isrc, "USRC12345678")
                return cand
            },
            search: { _ in
                XCTFail("search should not be called when ISRC hits")
                return []
            }
        )

        let (result, _) = try await Matcher.match(track: track, threshold: 85, lookup: lookup)
        XCTAssertEqual(result.tier, .isrc)
        XCTAssertEqual(result.appleSongID, cand.id)
    }

    func testFallsBackToSearchWhenNoISRC() async throws {
        let track = makeTrack(name: "Blinding Lights", isrc: nil)
        let cand = makeCandidate(title: "Blinding Lights")

        let lookup = CatalogLookup(
            byISRC: { _ in nil },
            search: { _ in [cand] }
        )

        let (result, _) = try await Matcher.match(track: track, threshold: 85, lookup: lookup)
        XCTAssertEqual(result.tier, .search)
        XCTAssertEqual(result.appleSongID, cand.id)
    }

    func testFallsBackToSearchWhenISRCMisses() async throws {
        let track = makeTrack(name: "Blinding Lights")
        let cand = makeCandidate(title: "Blinding Lights")

        let lookup = CatalogLookup(
            byISRC: { _ in nil },
            search: { _ in [cand] }
        )

        let (result, _) = try await Matcher.match(track: track, threshold: 85, lookup: lookup)
        XCTAssertEqual(result.tier, .search)
    }

    func testUnmatchedWhenSearchEmpty() async throws {
        let track = makeTrack(name: "Whatever", isrc: nil)

        let lookup = CatalogLookup(
            byISRC: { _ in nil },
            search: { _ in [] }
        )

        let (result, scored) = try await Matcher.match(track: track, threshold: 85, lookup: lookup)
        XCTAssertEqual(result.tier, .unmatched)
        XCTAssertNil(scored)
    }

    func testUnmatchedWhenAllBelowThreshold() async throws {
        let track = makeTrack(name: "Blinding Lights", isrc: nil)
        let bad = makeCandidate(title: "Some Totally Different Song", artistName: "Other Person")

        let lookup = CatalogLookup(
            byISRC: { _ in nil },
            search: { _ in [bad] }
        )

        let (result, _) = try await Matcher.match(track: track, threshold: 85, lookup: lookup)
        XCTAssertEqual(result.tier, .unmatched)
        XCTAssertNotNil(result.bestCandidateTitle)
    }

    func testPicksBestOfMultipleCandidates() async throws {
        let track = makeTrack(name: "Blinding Lights", isrc: nil, durationMs: 200_000)
        let goodMatch = makeCandidate(title: "Blinding Lights", durationMs: 201_000)
        let okayMatch = makeCandidate(title: "Blinding Lights (Live)", durationMs: 220_000)
        let badMatch = makeCandidate(title: "Some Other Song", artistName: "Someone Else")

        let lookup = CatalogLookup(
            byISRC: { _ in nil },
            search: { _ in [badMatch, okayMatch, goodMatch] }
        )

        let (result, scored) = try await Matcher.match(track: track, threshold: 85, lookup: lookup)
        XCTAssertEqual(result.tier, .search)
        XCTAssertEqual(result.appleSongID, goodMatch.id)
        XCTAssertGreaterThan(scored?.score ?? 0, 90)
    }

    func testDurationSimilarityWithinThreeSeconds() {
        XCTAssertEqual(Matcher.durationSimilarity(spotifyMs: 200_000, candidateMs: 202_000), 1.0, accuracy: 0.001)
        XCTAssertEqual(Matcher.durationSimilarity(spotifyMs: 200_000, candidateMs: 200_000), 1.0, accuracy: 0.001)
    }

    func testDurationSimilarityBeyondFifteenSeconds() {
        XCTAssertEqual(Matcher.durationSimilarity(spotifyMs: 200_000, candidateMs: 220_000), 0.0, accuracy: 0.001)
    }

    func testDurationSimilarityLinearMidrange() {
        // 9s diff → halfway through the linear penalty band.
        let s = Matcher.durationSimilarity(spotifyMs: 200_000, candidateMs: 209_000)
        XCTAssertEqual(s, 0.5, accuracy: 0.05)
    }

    func testDurationSimilarityUnknownIsNeutral() {
        XCTAssertEqual(Matcher.durationSimilarity(spotifyMs: 0, candidateMs: 200_000), 0.5, accuracy: 0.001)
    }

    func testTitleAndArtistDominateScoring() {
        // Two candidates with identical titles/artists but different durations.
        // Both should comfortably clear threshold 85 because title (50) + artist (35) = 85 alone.
        let track = makeTrack(name: "Take Me Out", artists: ["Franz Ferdinand"], isrc: nil, durationMs: 230_000)
        let close = makeCandidate(title: "Take Me Out", artistName: "Franz Ferdinand", durationMs: 232_000)
        let farDuration = makeCandidate(title: "Take Me Out", artistName: "Franz Ferdinand", durationMs: 250_000)

        let scoreClose = Matcher.score(track: track, candidate: close).score
        let scoreFar = Matcher.score(track: track, candidate: farDuration).score
        XCTAssertGreaterThanOrEqual(scoreClose, 85)
        XCTAssertGreaterThanOrEqual(scoreFar, 85)
        XCTAssertGreaterThan(scoreClose, scoreFar)
    }

    func testNormalizationHelpsParentheticalMismatch() {
        // Spotify has "(feat. X)" but Apple Music's primary title is bare.
        let track = makeTrack(name: "Stay (feat. Justin Bieber)", artists: ["The Kid LAROI", "Justin Bieber"], isrc: nil)
        let cand = makeCandidate(title: "Stay", artistName: "The Kid LAROI")
        let s = Matcher.score(track: track, candidate: cand)
        XCTAssertGreaterThan(s.titleScore, 0.95)
    }
}
