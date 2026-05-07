import Foundation

struct SpotifyPlaylist {
    let id: String
    let name: String
    let description: String?
    let ownerName: String?
    let tracks: [SpotifyTrack]
    let skippedLocalCount: Int
}

struct SpotifyTrack: Equatable {
    let id: String
    let name: String
    let artists: [String]
    let albumName: String
    let isrc: String?
    let durationMs: Int

    var primaryArtist: String { artists.first ?? "" }
}

enum MatchTier: String {
    case isrc
    case search
    case unmatched
    case skippedLocal = "skipped_local"
}

struct MatchResult {
    let track: SpotifyTrack
    let tier: MatchTier
    let appleSongID: String?
    let score: Double
    let bestCandidateTitle: String?
    let bestCandidateArtist: String?
    let reason: String?
}

struct ConversionReport {
    let playlistName: String
    let totalSpotify: Int
    let skippedLocal: Int
    let matchedISRC: Int
    let matchedSearch: Int
    let unmatched: Int
    let appleMusicURL: URL?
    let unmatchedDetails: [MatchResult]
}
