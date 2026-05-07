import Foundation

enum Report {
    static func printSummary(_ report: ConversionReport) {
        let total = report.totalSpotify
        let matched = report.matchedISRC + report.matchedSearch
        let pct = total == 0 ? 0.0 : (Double(matched) / Double(total)) * 100.0

        print("")
        print("─── Conversion summary ───")
        print(" playlist:       \(report.playlistName)")
        print(String(format: " matched:        %d/%d (%.1f%%)", matched, total, pct))
        print("   - by ISRC:    \(report.matchedISRC)")
        print("   - by search:  \(report.matchedSearch)")
        print(" skipped (local): \(report.skippedLocal)")
        print(" unmatched:       \(report.unmatched)")
        if let url = report.appleMusicURL {
            print(" Apple Music URL: \(url.absoluteString)")
        }
    }

    /// Writes one row per unmatched track. Always writes a header.
    static func writeCSV(_ unmatched: [MatchResult], to path: String) throws {
        var out = "spotify_id,title,artists,album,isrc,duration_ms,reason,best_candidate_title,best_candidate_artist,score\n"
        for r in unmatched {
            let cells: [String] = [
                r.track.id,
                r.track.name,
                r.track.artists.joined(separator: "; "),
                r.track.albumName,
                r.track.isrc ?? "",
                String(r.track.durationMs),
                r.reason ?? "",
                r.bestCandidateTitle ?? "",
                r.bestCandidateArtist ?? "",
                String(format: "%.1f", r.score)
            ]
            out += cells.map(csvEscape).joined(separator: ",") + "\n"
        }
        let url = URL(fileURLWithPath: path)
        try out.data(using: .utf8)?.write(to: url, options: [.atomic])
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return s
    }
}
