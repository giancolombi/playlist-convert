import AppKit
import Foundation

enum InteractivePrompt {
    /// Prompts for a Spotify playlist URL/URI/ID. If the clipboard contains a
    /// recognisable Spotify playlist reference, offers it as the default.
    /// Returns the raw user input (the caller still passes it through PlaylistURLParser).
    static func askForPlaylist() -> String {
        let suggestion = clipboardSpotifyPlaylist()

        while true {
            if let s = suggestion {
                print("\nSpotify playlist URL detected on clipboard:")
                print("  \(s)")
                print("Press Return to use it, or paste a different URL: ", terminator: "")
            } else {
                print("\nPaste a Spotify playlist URL (or URI / 22-char ID): ", terminator: "")
            }

            guard let raw = readLine() else {
                FileHandle.standardError.write(Data("\nstdin closed — aborting.\n".utf8))
                exit(1)
            }

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = trimmed.isEmpty ? (suggestion ?? "") : trimmed

            if candidate.isEmpty {
                print("Empty input. Try again or Ctrl-C to abort.")
                continue
            }
            if PlaylistURLParser.extractID(from: candidate) == nil {
                print("That doesn't look like a Spotify playlist URL. Try again.")
                continue
            }
            return candidate
        }
    }

    /// Returns the clipboard contents only if it parses as a Spotify playlist.
    static func clipboardSpotifyPlaylist() -> String? {
        guard let s = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlaylistURLParser.extractID(from: trimmed) != nil ? trimmed : nil
    }
}
