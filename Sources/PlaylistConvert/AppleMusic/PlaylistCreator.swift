import Foundation

/// Creates an Apple Music library playlist via Music.app AppleScript and adds
/// catalog songs by their Apple Music URL.
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
        matched: [(track: SpotifyTrack, song: AppleMusicSong)],
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
            do {
                try MusicAppBridge.addCatalogTrack(url: pair.song.url, to: playlist)
                added += 1
                progress?(added, matched.count)
            } catch let err as MusicAppBridge.ScriptError {
                failures.append(AddFailure(
                    track: pair.track,
                    appleSongID: pair.song.id,
                    appleSongTitle: pair.song.title,
                    underlying: err.description
                ))
                fputs("\nwarning: failed to add #\(idx + 1) \"\(pair.song.title)\": \(err.description)\n", stderr)
            }
        }

        return (playlist, added, failures)
    }
}
