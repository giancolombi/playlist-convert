import Foundation

enum PlaylistURLParser {
    /// Extracts a 22-char Spotify playlist ID from a URL, URI, or bare ID.
    /// Returns nil if no valid ID can be found.
    static func extractID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isValidPlaylistID(trimmed) {
            return trimmed
        }

        if trimmed.hasPrefix("spotify:playlist:") {
            let candidate = String(trimmed.dropFirst("spotify:playlist:".count))
            return isValidPlaylistID(candidate) ? candidate : nil
        }

        if let url = URL(string: trimmed),
           let host = url.host,
           host.contains("spotify.com") {
            let parts = url.path.split(separator: "/").map(String.init)
            if let idx = parts.firstIndex(of: "playlist"), idx + 1 < parts.count {
                let candidate = parts[idx + 1]
                return isValidPlaylistID(candidate) ? candidate : nil
            }
        }

        return nil
    }

    /// Spotify base62 IDs are 22 characters of [A-Za-z0-9].
    static func isValidPlaylistID(_ s: String) -> Bool {
        guard s.count == 22 else { return false }
        return s.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber)
        }
    }
}
