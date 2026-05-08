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

/// A song from the Apple Music catalog as returned by the iTunes Search API.
/// Carries everything PlaylistCreator needs to add the track via AppleScript.
struct AppleMusicSong {
    let id: String          // catalog "trackId" as string, e.g. "1234567890"
    let url: URL            // trackViewUrl — pass directly to Music.app `add`
    let title: String
    let artistName: String
    let albumTitle: String
    let durationMs: Int
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
