import Foundation

/// Drives Music.app via osascript to create playlists and add catalog tracks
/// (by Apple Music URL). The catalog URL comes from the iTunes Search API,
/// and Music.app's `add` command resolves it against the user's Apple Music
/// subscription.
///
/// First invocation triggers the macOS Automation permission prompt
/// (System Settings → Privacy & Security → Automation → playlist-convert → Music).
enum MusicAppBridge {

    struct ScriptError: Error, CustomStringConvertible {
        let description: String
    }

    /// Persistent ID of a Music.app user playlist (a hex string).
    struct PlaylistRef {
        let persistentID: String
    }

    /// Make sure Music.app is running. Music.app's scripting bridge requires
    /// the app to be active.
    static func ensureMusicAppRunning() throws {
        let script = """
        tell application "Music"
            if it is not running then
                launch
                delay 0.5
            end if
            return "ok"
        end tell
        """
        _ = try runScript(source: script, args: [])
    }

    /// Creates a new user playlist and returns its persistent ID.
    static func createPlaylist(name: String, description: String?) throws -> PlaylistRef {
        let script = """
        on run argv
            set thePlaylistName to item 1 of argv
            set thePlaylistDesc to item 2 of argv
            tell application "Music"
                if thePlaylistDesc is "" then
                    set newPlaylist to make new user playlist with properties {name:thePlaylistName}
                else
                    set newPlaylist to make new user playlist with properties {name:thePlaylistName, description:thePlaylistDesc}
                end if
                return persistent ID of newPlaylist
            end tell
        end run
        """
        let pid = try runScript(source: script, args: [name, description ?? ""])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty else {
            throw ScriptError(description: "Music.app did not return a persistent ID for the new playlist.")
        }
        return PlaylistRef(persistentID: pid)
    }

    /// Adds a catalog track to a playlist by Apple Music URL. The Music.app
    /// `add` command accepts these URLs and resolves them against the user's
    /// Apple Music subscription. Throws on per-track failure so the caller
    /// can record it in the unmatched report instead of aborting.
    static func addCatalogTrack(url: URL, to playlist: PlaylistRef) throws {
        let script = """
        on run argv
            set trackURL to item 1 of argv
            set targetPID to item 2 of argv
            tell application "Music"
                set targetPlaylist to (first user playlist whose persistent ID is targetPID)
                add trackURL to targetPlaylist
                return "ok"
            end tell
        end run
        """
        _ = try runScript(source: script, args: [url.absoluteString, playlist.persistentID])
    }

    /// Returns the Music.app URL for the given playlist (so we can print it).
    static func playlistURL(for playlist: PlaylistRef) throws -> URL? {
        let script = """
        on run argv
            set targetPID to item 1 of argv
            tell application "Music"
                try
                    set p to (first user playlist whose persistent ID is targetPID)
                    return ("musicapp://playlist/" & targetPID)
                on error
                    return ""
                end try
            end tell
        end run
        """
        let s = try runScript(source: script, args: [playlist.persistentID])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return URL(string: s)
    }

    // MARK: - osascript runner

    private static func runScript(source: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"] + args

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ScriptError(description: "Failed to spawn osascript: \(error)")
        }

        try stdin.fileHandleForWriting.write(contentsOf: Data(source.utf8))
        try stdin.fileHandleForWriting.close()

        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw ScriptError(description: prettyError(stderr: err, status: process.terminationStatus))
        }
        return out
    }

    private static func prettyError(stderr: String, status: Int32) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-1743") || trimmed.lowercased().contains("not authorized") {
            return """
            Music.app refused the AppleScript request.
            Open System Settings → Privacy & Security → Automation, find playlist-convert,
            and enable Music. Then re-run.
            (osascript exit \(status): \(trimmed))
            """
        }
        if trimmed.contains("not running") || trimmed.contains("can\u{2019}t get application \"Music\"") {
            return "Music.app is not available. Make sure it is installed and you are signed in. (\(trimmed))"
        }
        return "AppleScript failed (exit \(status)): \(trimmed)"
    }
}
