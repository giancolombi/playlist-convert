import AppKit
import CryptoKit
import Foundation
import Network

/// PKCE OAuth flow for Spotify with a local 127.0.0.1 listener and on-disk token cache.
actor SpotifyAuth {
    struct CachedTokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String
        let scope: String?
        let expires_in: Int
        let refresh_token: String?
    }

    private let clientID: String
    private var cached: CachedTokens?

    init(clientID: String) {
        self.clientID = clientID
    }

    /// Returns a valid access token, refreshing or running the browser flow if needed.
    func accessToken() async throws -> String {
        if cached == nil {
            cached = loadFromDisk()
        }
        if let c = cached, c.expiresAt > Date().addingTimeInterval(60) {
            return c.accessToken
        }
        if let c = cached {
            do {
                let refreshed = try await refresh(refreshToken: c.refreshToken)
                cached = refreshed
                try saveToDisk(refreshed)
                return refreshed.accessToken
            } catch {
                fputs("warning: refresh failed (\(error)) — re-running browser flow\n", stderr)
            }
        }
        let fresh = try await runBrowserFlow()
        cached = fresh
        try saveToDisk(fresh)
        return fresh.accessToken
    }

    // MARK: - Disk cache

    private func loadFromDisk() -> CachedTokens? {
        guard let data = try? Data(contentsOf: Config.spotifyTokensFile) else { return nil }
        return try? JSONDecoder.iso8601().decode(CachedTokens.self, from: data)
    }

    private func saveToDisk(_ t: CachedTokens) throws {
        try Config.ensureAppSupportDir()
        let data = try JSONEncoder.iso8601().encode(t)
        try data.write(to: Config.spotifyTokensFile, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Config.spotifyTokensFile.path
        )
    }

    // MARK: - PKCE browser flow

    private func runBrowserFlow() async throws -> CachedTokens {
        let verifier = Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafe(length: 16)

        var components = URLComponents()
        components.scheme = "https"
        components.host = Config.spotifyAuthHost
        components.path = "/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Config.spotifyRedirectURI),
            URLQueryItem(name: "scope", value: Config.spotifyScopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authURL = components.url else {
            throw CLIError.userMessage("Failed to build Spotify authorize URL.")
        }

        print("Opening browser for Spotify authorization…")
        print("If the browser doesn't open, paste this URL manually:\n  \(authURL.absoluteString)")

        let listener = LocalCallbackListener(port: Config.spotifyRedirectPort)
        try listener.start()
        defer { listener.stop() }

        NSWorkspace.shared.open(authURL)

        let params = try await listener.awaitCallback(timeout: 300)
        guard params["state"] == state else {
            throw CLIError.userMessage("Spotify callback state mismatch — aborting.")
        }
        if let err = params["error"] {
            throw CLIError.userMessage("Spotify authorization error: \(err)")
        }
        guard let code = params["code"] else {
            throw CLIError.userMessage("Spotify callback missing 'code' parameter.")
        }

        let resp = try await exchangeCode(code: code, verifier: verifier)
        guard let refresh = resp.refresh_token else {
            throw CLIError.userMessage("Spotify token response missing refresh_token.")
        }
        return CachedTokens(
            accessToken: resp.access_token,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(TimeInterval(resp.expires_in))
        )
    }

    private func exchangeCode(code: String, verifier: String) async throws -> TokenResponse {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Config.spotifyRedirectURI),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]
        let body = components.percentEncodedQuery?.data(using: .utf8) ?? Data()

        var req = URLRequest(url: URL(string: "https://\(Config.spotifyAuthHost)/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw CLIError.userMessage("Spotify token exchange failed: \(bodyStr)")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func refresh(refreshToken: String) async throws -> CachedTokens {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID)
        ]
        let body = components.percentEncodedQuery?.data(using: .utf8) ?? Data()

        var req = URLRequest(url: URL(string: "https://\(Config.spotifyAuthHost)/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw CLIError.userMessage("Spotify refresh failed: \(bodyStr)")
        }
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        return CachedTokens(
            accessToken: resp.access_token,
            refreshToken: resp.refresh_token ?? refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(resp.expires_in))
        )
    }

    // MARK: - PKCE helpers

    private static func generateCodeVerifier() -> String {
        randomURLSafe(length: 64)
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }

    private static func randomURLSafe(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var out = ""
        out.reserveCapacity(length)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        for b in bytes {
            out.append(alphabet[Int(b) % alphabet.count])
        }
        return out
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// A tiny single-shot HTTP listener bound to 127.0.0.1 to capture an OAuth callback.
/// Mutable state is only ever touched from `queue`, so the class is Sendable in practice.
final class LocalCallbackListener: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var fired = false
    private let queue = DispatchQueue(label: "playlist-convert.callback-listener")

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        let params = NWParameters.tcp
        if let opt = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            opt.version = .v4
        }
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func awaitCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.queue.async {
                        self.continuation = cont
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CLIError.userMessage("Timed out waiting for Spotify callback. Re-run and complete the browser flow within \(Int(timeout))s.")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func handle(connection conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            defer { conn.cancel() }
            if let error {
                self.fail(error)
                return
            }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                self.fail(CLIError.userMessage("Empty Spotify callback request."))
                return
            }
            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2,
                  let url = URL(string: "http://127.0.0.1\(parts[1])") else {
                self.fail(CLIError.userMessage("Malformed Spotify callback request: \(firstLine)"))
                return
            }
            var params: [String: String] = [:]
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.forEach { params[$0.name] = $0.value ?? "" }

            let body = """
            <!doctype html><meta charset=utf-8>
            <title>PlaylistConvert</title>
            <style>body{font-family:-apple-system,system-ui,sans-serif;padding:48px;max-width:540px;margin:0 auto;color:#222}h1{font-size:18px;margin:0 0 8px}p{color:#555}</style>
            <h1>Spotify authorization received</h1>
            <p>You can close this tab and return to the terminal.</p>
            """
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in })
            self.deliver(params)
        }
    }

    private func deliver(_ params: [String: String]) {
        guard !fired else { return }
        fired = true
        continuation?.resume(returning: params)
        continuation = nil
    }

    private func fail(_ error: Error) {
        guard !fired else { return }
        fired = true
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
