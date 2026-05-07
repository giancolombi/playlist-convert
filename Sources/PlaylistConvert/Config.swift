import Foundation

enum Config {
    static let userAgent = "PlaylistConvert/0.1 (local)"

    static let spotifyAuthHost = "accounts.spotify.com"
    static let spotifyAPIHost = "api.spotify.com"
    static let spotifyRedirectURI = "http://127.0.0.1:8888/callback"
    static let spotifyRedirectPort: UInt16 = 8888
    static let spotifyScopes = "playlist-read-private playlist-read-collaborative"

    static var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/playlist-convert", isDirectory: true)
    }

    static var configFile: URL {
        configDir.appendingPathComponent("config.json")
    }

    static var appSupportDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/PlaylistConvert", isDirectory: true)
    }

    static var spotifyTokensFile: URL {
        appSupportDir.appendingPathComponent("spotify-tokens.json")
    }

    static func ensureAppSupportDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: appSupportDir.path) {
            try fm.createDirectory(
                at: appSupportDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    struct UserConfig: Codable {
        let spotifyClientID: String

        enum CodingKeys: String, CodingKey {
            case spotifyClientID = "spotify_client_id"
        }
    }

    static func loadUserConfig() throws -> UserConfig {
        let data: Data
        do {
            data = try Data(contentsOf: configFile)
        } catch {
            throw CLIError.userMessage("""
                Missing config file at \(configFile.path).
                Create it with:
                  mkdir -p \(configDir.path)
                  cat > \(configFile.path) <<EOF
                  { "spotify_client_id": "<your-spotify-client-id>" }
                  EOF
                Get a Client ID at https://developer.spotify.com/dashboard
                Set the redirect URI to \(spotifyRedirectURI)
                """)
        }
        return try JSONDecoder().decode(UserConfig.self, from: data)
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String

    static func userMessage(_ message: String) -> CLIError {
        CLIError(description: message)
    }
}
