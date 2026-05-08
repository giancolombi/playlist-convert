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

    @Option(name: .long, help: "Override the target Apple Music playlist name (defaults to the Spotify playlist name).")
    var name: String?

    @Option(name: .long, help: "Match score threshold 0–100 (default 85).")
    var matchThreshold: Int = 85

    @Option(name: .long, help: "Path for the per-track CSV report (default ./report.csv).")
    var reportPath: String = "./report.csv"

    @Option(name: .long, help: "Path for the matched-track URL list (default ./matches.txt).")
    var matchesPath: String = "./matches.txt"

    @Flag(name: .long, help: "Skip creating the empty playlist in Music.app (just emit files).")
    var noPlaylist: Bool = false

    @Flag(name: .long, help: "Sync mode: skip the Spotify/iTunes match and walk an existing report.csv, opening each URL in Music.app and auto-adding tracks to your playlist as you click +.")
    var sync: Bool = false

    @Flag(name: .long, help: "Sweep mode: like --sync but doesn't open URLs or wait — just adds any matched tracks already in your Music library to the playlist and exits. Run this any time after manually adding songs.")
    var sweep: Bool = false

    @Option(name: .long, help: "App to receive the song URLs in --sync mode. Defaults to 'Music' (loads each in Music.app directly). Try 'Safari' or 'Google Chrome' to route through a browser instead.")
    var openWith: String = "Music"

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
        // ── Sync / Sweep mode short-circuit ──────────────────────────────────
        if sync || sweep {
            try await runSyncOrSweep(sweepOnly: sweep)
            return
        }

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

        // ── Best-effort empty-playlist creation in Music.app ─────────────────
        // Adding catalog tracks scriptedly is impossible without paid dev
        // access (see README), but creating the empty playlist itself works
        // and saves the user one Cmd-N. Soft failure: if Automation
        // permission is denied, we still printed everything they need.
        let targetName = name ?? playlist.name
        if !noPlaylist {
            do {
                _ = try MusicAppBridge.createEmptyPlaylist(
                    name: targetName,
                    description: playlist.description
                )
                print("\n✓ Empty playlist '\(targetName)' created in Music.app.")
                print("Next: in Music.app, leave that playlist open. Then in this terminal:")
            } catch let err as MusicAppBridge.ScriptError {
                fputs("\nnote: couldn't create the playlist in Music.app (\(err.description.prefix(120)))\n", stderr)
                fputs("In Music.app, create a new playlist named '\(targetName)' yourself, then:\n", stderr)
            }
        } else {
            print("\nIn Music.app, create a new playlist named '\(targetName)'. Then:")
        }

        print("  while IFS= read -r u; do [[ \"$u\" =~ ^https ]] && open -a Safari \"$u\" && sleep 0.4; done < \(matchesPath)")
        print("This opens each match in Safari. From each tab → 'Listen on Apple Music' → '+' to add to library → drag into your playlist.")
    }

    private func printProgress(current: Int, total: Int, isrc: Int, search: Int) {
        let line = String(format: "\rMatching: %d/%d (search: %d)", current, total, search)
        fputs(line, stderr)
    }

    private func runSyncOrSweep(sweepOnly: Bool) async throws {
        let rows = try SyncFlow.loadMatches(reportPath: reportPath)
        if rows.isEmpty {
            throw CLIError.userMessage("""
                No matched tracks found in \(reportPath). Either it doesn't exist
                or no rows have an apple_music_url column populated.
                Run a match first:  playlist-convert <spotify-url>
                """)
        }

        let target: String
        if let n = name, !n.isEmpty {
            target = n
        } else {
            let mode = sweepOnly ? "--sweep" : "--sync"
            print("Target Apple Music playlist name (must match exactly): ", terminator: "")
            guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
                throw CLIError.userMessage("Playlist name required for \(mode). Re-run with --name \"<name>\".")
            }
            target = line
        }

        if sweepOnly {
            try SyncFlow.sweep(rows: rows, playlistName: target)
        } else {
            try await SyncFlow.run(rows: rows, playlistName: target, openWith: openWith)
        }
    }
}
