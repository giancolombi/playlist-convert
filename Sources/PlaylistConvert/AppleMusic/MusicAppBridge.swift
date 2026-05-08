import Foundation

/// Drives Music.app via osascript for the one mutation we *can* script
/// without paid dev access: creating an empty user playlist. Adding catalog
/// tracks to it is not scriptable — see README's "Why no MusicKit" table.
enum MusicAppBridge {
    struct ScriptError: Error, CustomStringConvertible {
        let description: String
    }

    /// Creates an empty user playlist with `name` and (optional) `description`.
    /// Returns the persistent ID Music.app assigns. If Music.app isn't
    /// running it launches first.
    /// True iff a track with the given catalog/database ID exists in the
    /// user's Music library. Used to detect "user just clicked + on this
    /// track" during sync.
    static func trackInLibrary(databaseID: String) throws -> Bool {
        let script = """
        on run argv
            set tid to (item 1 of argv) as integer
            tell application "Music"
                try
                    set t to (first track whose database ID is tid)
                    return "yes"
                on error
                    return "no"
                end try
            end tell
        end run
        """
        let out = try runScript(source: script, args: [databaseID])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out == "yes"
    }

    /// Adds a track that's already in the user's library to a named user
    /// playlist (via `duplicate`). Throws if the track or playlist isn't
    /// found.
    static func addLibraryTrackToPlaylist(databaseID: String, playlistName: String) throws {
        let script = """
        on run argv
            set tid to (item 1 of argv) as integer
            set pname to item 2 of argv
            tell application "Music"
                set t to (first track whose database ID is tid)
                set p to (first user playlist whose name is pname)
                duplicate t to p
                return "ok"
            end tell
        end run
        """
        _ = try runScript(source: script, args: [databaseID, playlistName])
    }

    @discardableResult
    static func createEmptyPlaylist(name: String, description: String?) throws -> String {
        let script = """
        on run argv
            set thePlaylistName to item 1 of argv
            set thePlaylistDesc to item 2 of argv
            tell application "Music"
                if it is not running then
                    launch
                    delay 0.5
                end if
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
            throw ScriptError(description: "Music.app didn't return a persistent ID for the new playlist.")
        }
        return pid
    }

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

        guard process.terminationStatus == 0 else {
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
        return "AppleScript failed (exit \(status)): \(trimmed)"
    }
}
