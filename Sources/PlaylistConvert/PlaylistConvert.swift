import ArgumentParser
import Foundation
import MusicKit

@main
struct PlaylistConvert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playlist-convert",
        abstract: "Convert a Spotify playlist into an Apple Music playlist on this Mac."
    )

    @Argument(help: "Spotify playlist URL, URI, or 22-char ID. If omitted, you'll be prompted (with clipboard auto-detect).")
    var spotifyPlaylist: String?

    @Option(name: .long, help: "Override the target playlist name.")
    var name: String?

    @Option(name: .long, help: "Override the target playlist description.")
    var description: String?

    @Option(name: .long, help: "Match score threshold 0–100 (default 85).")
    var matchThreshold: Int = 85

    @Flag(name: .long, help: "Match only — do not create the Apple Music playlist.")
    var dryRun: Bool = false

    @Option(name: .long, help: "Path for the unmatched-tracks CSV report.")
    var reportPath: String = "./report.csv"

    @Flag(name: .long, help: "Verbose logging — print each unmatched track and its best candidate.")
    var verbose: Bool = false

    mutating func run() async throws {
        do {
            try await execute()
        } catch let err as CLIError {
            fputs("error: \(err.description)\n", stderr)
            throw ExitCode(1)
        } catch let err as MusicAppBridge.ScriptError {
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

        // ── Spotify ───────────────────────────────────────────────────────────
        let auth = SpotifyAuth(clientID: userConfig.spotifyClientID)
        let client = SpotifyClient(auth: auth)

        _ = try await auth.accessToken()
        print("✓ Spotify authorized")

        let playlist = try await client.fetchPlaylist(id: playlistID)
        print("Fetched \(playlist.tracks.count) tracks from '\(playlist.name)'\(playlist.skippedLocalCount > 0 ? " (\(playlist.skippedLocalCount) local files skipped)" : "")")

        // ── Apple Music ──────────────────────────────────────────────────────
        try await AppleMusicAuthorization.ensureAuthorized()
        print("✓ Apple Music authorized")

        // ── Match ────────────────────────────────────────────────────────────
        var matchedSongs: [(track: SpotifyTrack, song: Song)] = []
        var matchResults: [MatchResult] = []
        var isrcCount = 0
        var searchCount = 0
        let total = playlist.tracks.count

        for (idx, track) in playlist.tracks.enumerated() {
            let result: MatchResult
            let song: Song?

            if let isrc = track.isrc, !isrc.isEmpty,
               let hit = try? await AppleMusicClient.findByISRC(isrc) {
                let scored = Matcher.score(track: track, candidate: hit.candidate)
                result = MatchResult(
                    track: track,
                    tier: .isrc,
                    appleSongID: hit.candidate.id,
                    score: scored.score,
                    bestCandidateTitle: hit.candidate.title,
                    bestCandidateArtist: hit.candidate.artistName,
                    reason: nil
                )
                song = hit.song
                isrcCount += 1
            } else {
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
                    song = s.pair.song
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
                    song = nil
                }
            }

            matchResults.append(result)
            if let song { matchedSongs.append((track, song)) }
            printProgress(current: idx + 1, total: total, isrc: isrcCount, search: searchCount)
        }
        fputs("\n", stderr)  // newline after the progress line

        let unmatchedResults = matchResults.filter { $0.tier == .unmatched }

        if verbose {
            for r in unmatchedResults {
                let cand = r.bestCandidateTitle.map { " — best: \"\($0)\" by \(r.bestCandidateArtist ?? "?")" } ?? ""
                print("  unmatched: \"\(r.track.name)\" by \(r.track.primaryArtist)\(cand) [\(r.reason ?? "")]")
            }
        }

        // ── Dry run? ─────────────────────────────────────────────────────────
        if dryRun {
            let report = ConversionReport(
                playlistName: name ?? playlist.name,
                totalSpotify: playlist.tracks.count,
                skippedLocal: playlist.skippedLocalCount,
                matchedISRC: isrcCount,
                matchedSearch: searchCount,
                unmatched: unmatchedResults.count,
                appleMusicURL: nil,
                unmatchedDetails: unmatchedResults
            )
            Report.printSummary(report)
            try Report.writeCSV(unmatchedResults, to: reportPath)
            print(" report:          \(reportPath)")
            print("(dry run — no playlist created)")
            return
        }

        // ── Create the Apple Music playlist ──────────────────────────────────
        guard !matchedSongs.isEmpty else {
            throw CLIError.userMessage("No tracks matched — refusing to create an empty playlist. See \(reportPath).")
        }

        let creation = try PlaylistCreator.create(
            name: name ?? playlist.name,
            description: description ?? playlist.description,
            matched: matchedSongs,
            progress: { added, total in
                fputs("\rAdding to Music: \(added)/\(total)", stderr)
            }
        )
        fputs("\n", stderr)

        // Per-track add failures get recorded as unmatched-after-match.
        var finalUnmatched = unmatchedResults
        for f in creation.addFailures {
            finalUnmatched.append(MatchResult(
                track: f.track,
                tier: .unmatched,
                appleSongID: f.appleSongID,
                score: 0,
                bestCandidateTitle: f.appleSongTitle,
                bestCandidateArtist: nil,
                reason: "matched but Music.app add failed: \(f.underlying)"
            ))
        }

        let amURL = (try? MusicAppBridge.playlistURL(for: creation.playlistRef)) ?? nil
        let report = ConversionReport(
            playlistName: name ?? playlist.name,
            totalSpotify: playlist.tracks.count,
            skippedLocal: playlist.skippedLocalCount,
            matchedISRC: isrcCount,
            matchedSearch: searchCount,
            unmatched: finalUnmatched.count,
            appleMusicURL: amURL,
            unmatchedDetails: finalUnmatched
        )
        Report.printSummary(report)
        try Report.writeCSV(finalUnmatched, to: reportPath)
        print(" report:          \(reportPath)")
    }

    private func printProgress(current: Int, total: Int, isrc: Int, search: Int) {
        let line = String(format: "\rMatching: %d/%d (ISRC: %d, search: %d)", current, total, isrc, search)
        fputs(line, stderr)
    }
}
