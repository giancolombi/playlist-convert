import Foundation

enum Config {
    /// Spotify is fine with our honest UA. Apple's iTunes Search API,
    /// however, rate-limits unfamiliar UAs aggressively, so we present as
    /// Safari for that endpoint specifically. See AppleMusicClient.
    static let spotifyUserAgent = "PlaylistConvert/0.1 (local)"
    static let itunesUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    /// Default — kept for any legacy callers; new code should use the
    /// service-specific constants.
    static let userAgent = spotifyUserAgent

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

    /// Returns nil if the config file does not exist (caller can run the wizard).
    /// Throws on a malformed file.
    static func loadUserConfig() throws -> UserConfig? {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return nil
        }
        let data = try Data(contentsOf: configFile)
        return try JSONDecoder().decode(UserConfig.self, from: data)
    }

    static func ensureConfigDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir.path) {
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        }
    }

    static func writeUserConfig(_ config: UserConfig) throws {
        try ensureConfigDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configFile, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configFile.path
        )
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String

    static func userMessage(_ message: String) -> CLIError {
        CLIError(description: message)
    }
}
