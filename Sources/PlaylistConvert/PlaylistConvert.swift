import ArgumentParser
import Foundation

@main
struct PlaylistConvert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playlist-convert",
        abstract: "Convert a Spotify playlist into an Apple Music playlist on this Mac."
    )

    @Argument(help: "Spotify playlist URL, URI, or 22-char ID.")
    var spotifyPlaylist: String

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
        print("playlist-convert v0.1.0")
        print("playlist:        \(spotifyPlaylist)")
        print("name override:   \(name ?? "<none>")")
        print("threshold:       \(matchThreshold)")
        print("dry-run:         \(dryRun)")
        print("report-path:     \(reportPath)")
        print("verbose:         \(verbose)")
    }
}
