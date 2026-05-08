import ArgumentParser
import Foundation

@main
struct PlaylistConvert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playlist-convert",
        abstract: "Match a Spotify playlist against the Apple Music catalog and emit URL list + CSV report.",
        discussion: """
            macOS does not let third-party tools without paid Apple Developer access
            script the final "add catalog track to playlist" step. So this tool stops
            at the matching boundary: it gives you Apple Music URLs for every track
            it could match, and a CSV explaining anything it couldn't. You create the
            new playlist in Music.app yourself and add the matched tracks.
            """
    )

    @Argument(help: "Spotify playlist URL, URI, or 22-char ID. If omitted, you'll be prompted (with clipboard auto-detect).")
    var spotifyPlaylist: String?

    @Option(name: .long, help: "Match score threshold 0–100 (default 85).")
    var matchThreshold: Int = 85

    @Option(name: .long, help: "Path for the per-track CSV report (default ./report.csv).")
    var reportPath: String = "./report.csv"

    @Option(name: .long, help: "Path for the matched-track URL list (default ./matches.txt).")
    var matchesPath: String = "./matches.txt"

    @Flag(name: .long, help: "Verbose logging — print each unmatched track and its best candidate.")
    var verbose: Bool = false

    mutating func run() async throws {
        do {
            try await execute()
        } catch let err as CLIError {
            fputs("error: \(err.description)\n", stderr)
            throw ExitCode(1)
        }
    }

    private func execute() async throws {
        // ── Config (run wizard on first use) ─────────────────────────────────
        let userConfig: Config.UserConfig
        if let existing = try Config.loadUserConfig() {
            userConfig = existing
        } else {
            userConfig = try SetupWizard.runFirstTimeSetup()
        }

        // ── Resolve the playlist (interactive if no arg) ─────────────────────
        let playlistInput: String
        if let arg = spotifyPlaylist, !arg.isEmpty {
            playlistInput = arg
        } else {
            playlistInput = InteractivePrompt.askForPlaylist()
        }

        guard let playlistID = PlaylistURLParser.extractID(from: playlistInput) else {
            throw CLIError.userMessage("""
                Could not parse a Spotify playlist ID from: \(playlistInput)
                Accepted formats:
                  https://open.spotify.com/playlist/<22-char-id>
                  spotify:playlist:<22-char-id>
                  <22-char-id>
                """)
        }

        // ── Spotify ──────────────────────────────────────────────────────────
        let auth = SpotifyAuth(clientID: userConfig.spotifyClientID)
        let client = SpotifyClient(auth: auth)

        _ = try await auth.accessToken()
        print("✓ Spotify authorized")

        let playlist = try await client.fetchPlaylist(id: playlistID)
        let localNote = playlist.skippedLocalCount > 0 ? " (\(playlist.skippedLocalCount) local files skipped)" : ""
        print("Fetched \(playlist.tracks.count) tracks from '\(playlist.name)'\(localNote)")

        // ── Match against the iTunes Search API ──────────────────────────────
        var rows: [MatchRow] = []
        let isrcCount = 0  // ISRC tier disabled — see AppleMusicClient.findByISRC.
        var searchCount = 0
        let total = playlist.tracks.count

        for (idx, track) in playlist.tracks.enumerated() {
            let result: MatchResult
            var matchedURL: URL? = nil

            let term = Matcher.textSearchTerm(for: track)
            let candidates = (try? await AppleMusicClient.search(term: term)) ?? []
            let scored = candidates
                .map { (pair: $0, scored: Matcher.score(track: track, candidate: $0.candidate)) }
                .max { $0.scored.score < $1.scored.score }

            if let s = scored, s.scored.score >= Double(matchThreshold) {
                result = MatchResult(
                    track: track,
                    tier: .search,
                    appleSongID: s.pair.candidate.id,
                    score: s.scored.score,
                    bestCandidateTitle: s.pair.candidate.title,
                    bestCandidateArtist: s.pair.candidate.artistName,
                    reason: nil
                )
                matchedURL = s.pair.song.url
                searchCount += 1
            } else {
                result = MatchResult(
                    track: track,
                    tier: .unmatched,
                    appleSongID: nil,
                    score: scored?.scored.score ?? 0,
                    bestCandidateTitle: scored?.pair.candidate.title,
                    bestCandidateArtist: scored?.pair.candidate.artistName,
                    reason: scored == nil
                        ? "no search results"
                        : String(format: "below threshold (%.1f < %d)", scored!.scored.score, matchThreshold)
                )
            }

            rows.append(MatchRow(result: result, appleMusicURL: matchedURL))
            printProgress(current: idx + 1, total: total, isrc: isrcCount, search: searchCount)
        }
        fputs("\n", stderr)

        let unmatched = rows.filter { $0.result.tier == .unmatched }

        if verbose {
            for r in unmatched {
                let cand = r.result.bestCandidateTitle.map { " — best: \"\($0)\" by \(r.result.bestCandidateArtist ?? "?")" } ?? ""
                print("  unmatched: \"\(r.result.track.name)\" by \(r.result.track.primaryArtist)\(cand) [\(r.result.reason ?? "")]")
            }
        }

        let conversionReport = ConversionReport(
            playlistName: playlist.name,
            totalSpotify: playlist.tracks.count,
            skippedLocal: playlist.skippedLocalCount,
            matchedISRC: isrcCount,
            matchedSearch: searchCount,
            unmatched: unmatched.count,
            appleMusicURL: nil,
            unmatchedDetails: unmatched.map(\.result)
        )

        try Report.writeCSV(rows, to: reportPath)
        try Report.writeURLList(rows, playlistName: playlist.name, to: matchesPath)
        Report.printSummary(conversionReport, csvPath: reportPath, urlsPath: matchesPath)

        print("")
        print("Next: open Music.app, make a new playlist, then either")
        print("  • run:  xargs -I{} open '{}' < \(matchesPath)   (loads each in Music.app)")
        print("  • or click each URL in \(matchesPath) one at a time.")
        print("Then in Music.app drag the loaded songs into your playlist.")
    }

    private func printProgress(current: Int, total: Int, isrc: Int, search: Int) {
        let line = String(format: "\rMatching: %d/%d (search: %d)", current, total, search)
        fputs(line, stderr)
    }
}
