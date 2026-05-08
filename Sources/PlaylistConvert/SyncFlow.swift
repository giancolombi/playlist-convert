import AppKit
import Foundation

/// Walks the matched tracks from a previous run and adds each one to the
/// target playlist as the user clicks + in Music.app to add it to their
/// library. This is the "fastest possible" workflow given macOS's
/// constraint that catalog → library mutation is user-driven only.
enum SyncFlow {
    struct Row {
        let appleMusicID: String
        let appleMusicURL: URL
        let title: String
        let artist: String
    }

    /// Reads matched rows from report.csv. Skips unmatched and malformed rows.
    static func loadMatches(reportPath: String) throws -> [Row] {
        let data = try Data(contentsOf: URL(fileURLWithPath: reportPath))
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > 1 else { return [] }

        let header = parseCSVLine(lines[0])
        let idxAppleID = header.firstIndex(of: "apple_music_id") ?? -1
        let idxURL = header.firstIndex(of: "apple_music_url") ?? -1
        let idxBestTitle = header.firstIndex(of: "best_candidate_title") ?? -1
        let idxSpotifyTitle = header.firstIndex(of: "title") ?? -1
        let idxBestArtist = header.firstIndex(of: "best_candidate_artist") ?? -1
        let idxSpotifyArtists = header.firstIndex(of: "artists") ?? -1

        guard idxAppleID >= 0, idxURL >= 0 else {
            throw CLIError.userMessage("CSV at \(reportPath) is missing apple_music_id / apple_music_url columns. Re-run the match step to regenerate.")
        }

        var rows: [Row] = []
        for line in lines.dropFirst() {
            let cells = parseCSVLine(line)
            guard cells.count > max(idxAppleID, idxURL) else { continue }
            let id = cells[idxAppleID]
            let urlStr = cells[idxURL]
            guard !id.isEmpty, let url = URL(string: urlStr) else { continue }
            // Prefer the Apple-Music-side metadata for AppleScript exact-match
            // queries (Spotify titles often differ — "(feat. X)", "Remastered",
            // smart quotes — and would miss against Music.app's library).
            let title = pickNonEmpty(cells, idxBestTitle, idxSpotifyTitle) ?? "?"
            let artist = pickNonEmpty(cells, idxBestArtist, idxSpotifyArtists) ?? "?"
            rows.append(Row(appleMusicID: id, appleMusicURL: url, title: title, artist: artist))
        }
        return rows
    }

    private static func pickNonEmpty(_ cells: [String], _ first: Int, _ fallback: Int) -> String? {
        if first >= 0 && first < cells.count, !cells[first].isEmpty {
            return cells[first]
        }
        if fallback >= 0 && fallback < cells.count, !cells[fallback].isEmpty {
            return cells[fallback]
        }
        return nil
    }

    /// One-pass: scan the matched rows, and for any track already in the
    /// user's library, add it to the named playlist. Doesn't open URLs and
    /// doesn't wait. Useful after the user has manually added songs while
    /// `--sync` wasn't running.
    static func sweep(rows: [Row], playlistName: String) throws {
        guard !rows.isEmpty else {
            print("No matched tracks to sweep.")
            return
        }
        print("Sweep: scanning \(rows.count) matched rows for tracks already in your library…")
        var added = 0
        var skipped = 0
        for row in rows {
            let inLib = (try? MusicAppBridge.trackInLibrary(databaseID: row.appleMusicID, name: row.title, artist: row.artist)) == true
            guard inLib else { continue }
            do {
                try MusicAppBridge.addLibraryTrackToPlaylist(databaseID: row.appleMusicID, name: row.title, artist: row.artist, playlistName: playlistName)
                added += 1
                fputs("  ✓ \(row.title) — \(row.artist)\n", stderr)
            } catch {
                skipped += 1
                fputs("  ✗ \(row.title) — \(row.artist) (\(error))\n", stderr)
            }
        }
        print("")
        print("Sweep complete: \(added) added, \(skipped) failed, \(rows.count - added - skipped) not in library.")
        if added < rows.count {
            print("To add the rest, run:  playlist-convert --sync --name \"\(playlistName)\"")
        }
    }

    /// Walks `rows`, opening each URL in `openWith` (Music.app by default)
    /// and polling for the track to appear in the user's library. When
    /// detected, auto-adds it to the named playlist.
    static func run(rows: [Row], playlistName: String, openWith: String = "Music", perTrackTimeout: TimeInterval = 60) async throws {
        guard !rows.isEmpty else {
            print("No matched tracks to sync.")
            return
        }

        print("Sync: walking \(rows.count) matched tracks into '\(playlistName)' via \(openWith).")
        if openWith.lowercased() == "music" {
            print("For each: a song loads in Music.app — click the + to add it to your library.")
        } else {
            print("For each: \(openWith) opens the song page — click 'Listen on Apple Music' (or equivalent) so it loads in Music.app, then click + to add to library.")
        }
        print("The tool then auto-adds it to the playlist and advances. Ctrl-C to stop.\n")

        var added = 0
        var skipped = 0

        for (i, row) in rows.enumerated() {
            let progress = "[\(i + 1)/\(rows.count)]"
            fputs("\(progress) \(row.title) — \(row.artist)\n", stderr)
            fputs("  opening in Music.app… click + when it loads, ", stderr)

            // Skip if already in library (e.g. user added it last time).
            if (try? MusicAppBridge.trackInLibrary(databaseID: row.appleMusicID, name: row.title, artist: row.artist)) == true {
                fputs("already in library — adding…\n", stderr)
                if (try? MusicAppBridge.addLibraryTrackToPlaylist(databaseID: row.appleMusicID, name: row.title, artist: row.artist, playlistName: playlistName)) != nil {
                    added += 1
                } else {
                    skipped += 1
                    fputs("    (couldn't add to playlist — skipped)\n", stderr)
                }
                continue
            }

            openInApp(row.appleMusicURL, app: openWith)

            let detected = await waitForLibraryAdd(databaseID: row.appleMusicID, name: row.title, artist: row.artist, timeout: perTrackTimeout)
            if !detected {
                fputs("\n  timeout — skipped (\(Int(perTrackTimeout))s; verify you clicked + in Music.app, not just in the browser)\n", stderr)
                skipped += 1
                continue
            }

            do {
                try MusicAppBridge.addLibraryTrackToPlaylist(databaseID: row.appleMusicID, name: row.title, artist: row.artist, playlistName: playlistName)
                fputs("✓ added to '\(playlistName)'\n", stderr)
                added += 1
            } catch let err as MusicAppBridge.ScriptError {
                fputs("\n  detected in library but couldn't insert into playlist: \(err.description.prefix(160))\n", stderr)
                skipped += 1
            }
        }

        print("")
        print("─── Sync summary ───")
        print(" added:   \(added)/\(rows.count)")
        print(" skipped: \(skipped)")
    }

    /// Hands a URL to a specific app via `/usr/bin/open -a <app>`. Falls back
    /// to NSWorkspace if the app name is empty or the spawn fails (some
    /// Macs may not have the named app installed).
    private static func openInApp(_ url: URL, app: String) {
        let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            NSWorkspace.shared.open(url)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", trimmed, url.absoluteString]
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                fputs("\n  warning: 'open -a \(trimmed)' exited \(p.terminationStatus); falling back to default handler.\n", stderr)
                NSWorkspace.shared.open(url)
            }
        } catch {
            fputs("\n  warning: couldn't run 'open -a \(trimmed)' (\(error)); falling back.\n", stderr)
            NSWorkspace.shared.open(url)
        }
    }

    private static func waitForLibraryAdd(databaseID: String, name: String, artist: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? MusicAppBridge.trackInLibrary(databaseID: databaseID, name: name, artist: artist)) == true {
                return true
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    /// Minimal CSV line parser handling double-quoted fields and embedded
    /// commas / escaped quotes ("").
    static func parseCSVLine(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex && line[next] == "\"" {
                        current.append("\"")
                        i = line.index(after: next)
                        continue
                    }
                    inQuotes = false
                    i = line.index(after: i)
                    continue
                }
                current.append(ch)
                i = line.index(after: i)
            } else {
                switch ch {
                case "\"":
                    inQuotes = true
                    i = line.index(after: i)
                case ",":
                    cells.append(current)
                    current = ""
                    i = line.index(after: i)
                default:
                    current.append(ch)
                    i = line.index(after: i)
                }
            }
        }
        cells.append(current)
        return cells
    }
}
