import Foundation
import MusicKit

/// Creates an Apple Music library playlist via Music.app AppleScript and adds
/// catalog songs by their Apple Music URL. MusicKit's library-mutation APIs
/// are macOS-unavailable; this is the available substitute.
enum PlaylistCreator {

    struct AddFailure {
        let track: SpotifyTrack
        let appleSongID: String
        let appleSongTitle: String
        let underlying: String
    }

    static func create(
        name: String,
        description: String?,
        matched: [(track: SpotifyTrack, song: Song)],
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> (
        playlistRef: MusicAppBridge.PlaylistRef,
        addedCount: Int,
        addFailures: [AddFailure]
    ) {
        try MusicAppBridge.ensureMusicAppRunning()
        let playlist = try MusicAppBridge.createPlaylist(name: name, description: description)

        var added = 0
        var failures: [AddFailure] = []

        for (idx, pair) in matched.enumerated() {
            guard let url = pair.song.url else {
                failures.append(AddFailure(
                    track: pair.track,
                    appleSongID: pair.song.id.rawValue,
                    appleSongTitle: pair.song.title,
                    underlying: "Apple Music song has no URL"
                ))
                continue
            }
            do {
                try MusicAppBridge.addCatalogTrack(url: url, to: playlist)
                added += 1
                progress?(added, matched.count)
            } catch let err as MusicAppBridge.ScriptError {
                // Per-track failure is recorded but does not abort the run.
                failures.append(AddFailure(
                    track: pair.track,
                    appleSongID: pair.song.id.rawValue,
                    appleSongTitle: pair.song.title,
                    underlying: err.description
                ))
                fputs("\nwarning: failed to add #\(idx + 1) \"\(pair.song.title)\": \(err.description)\n", stderr)
            }
        }

        return (playlist, added, failures)
    }
}
