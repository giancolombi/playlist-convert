import AppKit
import Foundation

enum SetupWizard {
    /// Walks the user through creating a Spotify dev app and saves their Client ID.
    /// Returns the resulting config so the caller can proceed without re-reading.
    static func runFirstTimeSetup() throws -> Config.UserConfig {
        print("""

        ── First-time setup ─────────────────────────────────────────────────
        playlist-convert needs a free Spotify "Client ID" to read your playlists.
        It takes about 60 seconds.

        1. The Spotify developer dashboard will open in your browser.
        2. Click "Create app".
        3. Fill in any name and description.
        4. Set the Redirect URI to EXACTLY:

             \(Config.spotifyRedirectURI)

        5. Save, then copy the "Client ID" from the app's settings page.
        ─────────────────────────────────────────────────────────────────────
        """)

        print("Press Return to open the Spotify dashboard, or Ctrl-C to abort…", terminator: "")
        _ = readLine()

        if let url = URL(string: "https://developer.spotify.com/dashboard") {
            NSWorkspace.shared.open(url)
        }

        let clientID = promptUntilValidClientID()

        let config = Config.UserConfig(spotifyClientID: clientID)
        try Config.writeUserConfig(config)

        print("✓ Saved \(Config.configFile.path) (mode 0600).\n")
        return config
    }

    private static func promptUntilValidClientID() -> String {
        while true {
            print("\nPaste your Spotify Client ID and press Return: ", terminator: "")
            guard let raw = readLine() else {
                FileHandle.standardError.write(Data("\nstdin closed — aborting.\n".utf8))
                exit(1)
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPlausibleClientID(trimmed) {
                return trimmed
            }
            print("That doesn't look like a Client ID (Spotify IDs are 32 hex chars). Try again.")
        }
    }

    /// Spotify Client IDs are 32 lowercase hex characters.
    private static func isPlausibleClientID(_ s: String) -> Bool {
        guard s.count == 32 else { return false }
        return s.allSatisfy { ch in
            ch.isASCII && (ch.isHexDigit)
        }
    }
}
