import Foundation

actor SpotifyClient {
    private let auth: SpotifyAuth
    private let session: URLSession

    init(auth: SpotifyAuth, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    // MARK: - Public API

    func fetchPlaylist(id playlistID: String) async throws -> SpotifyPlaylist {
        let header = try await fetchPlaylistHeader(id: playlistID)
        let (tracks, skippedLocal) = try await fetchAllTracks(playlistID: playlistID)
        return SpotifyPlaylist(
            id: header.id,
            name: header.name,
            description: header.description,
            ownerName: header.ownerName,
            tracks: tracks,
            skippedLocalCount: skippedLocal
        )
    }

    // MARK: - Header (name, description, owner)

    private struct PlaylistHeader {
        let id: String
        let name: String
        let description: String?
        let ownerName: String?
    }

    private func fetchPlaylistHeader(id: String) async throws -> PlaylistHeader {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Config.spotifyAPIHost
        components.path = "/v1/playlists/\(id)"
        components.queryItems = [
            URLQueryItem(name: "fields", value: "id,name,description,owner(display_name)")
        ]
        let url = components.url!

        let data = try await get(url)
        struct Resp: Decodable {
            let id: String
            let name: String
            let description: String?
            struct Owner: Decodable { let display_name: String? }
            let owner: Owner?
        }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return PlaylistHeader(
            id: r.id,
            name: r.name,
            description: (r.description?.isEmpty ?? true) ? nil : r.description,
            ownerName: r.owner?.display_name
        )
    }

    // MARK: - Tracks

    private func fetchAllTracks(playlistID: String) async throws -> (tracks: [SpotifyTrack], skippedLocal: Int) {
        let fields = "items(is_local,track(id,name,duration_ms,external_ids(isrc),album(name),artists(name))),next,total"

        var components = URLComponents()
        components.scheme = "https"
        components.host = Config.spotifyAPIHost
        components.path = "/v1/playlists/\(playlistID)/tracks"
        components.queryItems = [
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "additional_types", value: "track")
        ]

        var nextURL: URL? = components.url
        var tracks: [SpotifyTrack] = []
        var skippedLocal = 0

        while let url = nextURL {
            let data = try await get(url)
            let page = try JSONDecoder().decode(TracksPage.self, from: data)

            for item in page.items {
                if item.is_local == true {
                    skippedLocal += 1
                    continue
                }
                guard let t = item.track else { continue }
                guard let id = t.id, let name = t.name else { continue }
                let artistNames = t.artists?.map(\.name) ?? []
                let track = SpotifyTrack(
                    id: id,
                    name: name,
                    artists: artistNames,
                    albumName: t.album?.name ?? "",
                    isrc: t.external_ids?.isrc,
                    durationMs: t.duration_ms ?? 0
                )
                tracks.append(track)
            }

            if let next = page.next, let nextParsed = URL(string: next) {
                nextURL = nextParsed
            } else {
                nextURL = nil
            }
        }

        return (tracks, skippedLocal)
    }

    private struct TracksPage: Decodable {
        struct Item: Decodable {
            let is_local: Bool?
            let track: Track?
        }
        struct Track: Decodable {
            let id: String?
            let name: String?
            let duration_ms: Int?
            let external_ids: ExternalIDs?
            let album: Album?
            let artists: [Artist]?
        }
        struct ExternalIDs: Decodable {
            let isrc: String?
        }
        struct Album: Decodable {
            let name: String?
        }
        struct Artist: Decodable {
            let name: String
        }
        let items: [Item]
        let next: String?
        let total: Int?
    }

    // MARK: - HTTP

    private func get(_ url: URL) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            let token = try await auth.accessToken()
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw CLIError.userMessage("Spotify: non-HTTP response from \(url.absoluteString)")
            }

            switch http.statusCode {
            case 200..<300:
                return data
            case 401:
                if attempt < 2 { continue }  // token may have just expired; retry once
                throw CLIError.userMessage("Spotify: 401 unauthorized — token refresh did not recover.")
            case 404:
                throw CLIError.userMessage("Spotify: playlist not found, or you don't have permission to view it.")
            case 429:
                let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
                if attempt > 5 {
                    throw CLIError.userMessage("Spotify: rate limited (429) and exhausted retries.")
                }
                fputs("Spotify rate-limited, sleeping \(retry)s…\n", stderr)
                try await Task.sleep(nanoseconds: UInt64(retry) * 1_000_000_000)
                continue
            case 500..<600:
                if attempt > 5 {
                    let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
                    throw CLIError.userMessage("Spotify: \(http.statusCode) after retries — \(bodyStr)")
                }
                let backoff = pow(2.0, Double(attempt)) + Double.random(in: 0...0.5)
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                continue
            default:
                let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
                throw CLIError.userMessage("Spotify: HTTP \(http.statusCode) — \(bodyStr)")
            }
        }
    }
}
