# playlist-convert

Convert a Spotify playlist into an Apple Music playlist on this Mac. macOS-only,
local-only, no developer accounts required.

## What it does

1. Fetches a Spotify playlist via the Spotify Web API (PKCE auth — no Spotify
   secret needed, just a free Client ID).
2. Matches each track against Apple Music using MusicKit. ISRC first, then
   normalized title + artist text search, scored 50/35/15 (title/artist/duration)
   and gated by `--match-threshold` (default 85).
3. Creates a playlist in Apple Music and adds the matches by driving Music.app
   via AppleScript. Per-track add failures don't abort the run.
4. Writes an unmatched-tracks CSV report so you can see exactly what was skipped
   and why.

## Why the AppleScript bridge

MusicKit on macOS is read-only — `MusicLibrary.shared.createPlaylist(items:)`
and `MusicLibrary.shared.add(_:to:)` are both marked
`@available(macOS, unavailable)` in the system swiftinterface. Search APIs
(`MusicCatalogResourceRequest`, `MusicCatalogSearchRequest`) work fine, so we
use those for matching, then `osascript` to drive Music.app for the actual
playlist mutation. This keeps the tool 100% local and avoids the paid
Apple Developer membership the Apple Music Web API would require.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode command line tools (`xcode-select --install`)
- Apple Music subscription, signed into Music.app on this Mac
- A free Spotify Developer app (used only for the Client ID)

## First-time setup

1. Confirm macOS 14+:
   ```sh
   sw_vers -productVersion
   ```
2. Confirm Xcode CLT:
   ```sh
   xcode-select -p
   ```
3. Sign into Xcode once with your Apple ID (Xcode → Settings → Accounts) so a
   Personal Team exists for ad-hoc signing. If full Xcode is not installed,
   accepting the free developer agreement at developer.apple.com is enough.
4. Create a free Spotify app at <https://developer.spotify.com/dashboard>. Set
   the redirect URI to:
   ```
   http://127.0.0.1:8888/callback
   ```
   Copy the Client ID.
5. Save the Client ID to the config file:
   ```sh
   mkdir -p ~/.config/playlist-convert
   cat > ~/.config/playlist-convert/config.json <<EOF
   { "spotify_client_id": "<your-spotify-client-id>" }
   EOF
   ```
6. Build and ad-hoc sign:
   ```sh
   swift build -c release
   codesign --force --sign - .build/release/PlaylistConvert
   ```
7. (Optional) Symlink to your `PATH`:
   ```sh
   ln -s "$PWD/.build/release/PlaylistConvert" /usr/local/bin/playlist-convert
   ```

## First run

The first invocation triggers up to three OS permission prompts. Approve each
one and re-run if the run was interrupted.

1. **Browser** — Spotify will ask you to authorize the app. After the redirect
   to `127.0.0.1:8888` you can close the tab.
2. **Apple Music** — macOS asks for access to your Apple Music library. If you
   miss the prompt, enable it under
   `System Settings → Privacy & Security → Media & Apple Music`.
3. **Automation → Music** — first time the tool drives Music.app via
   AppleScript, macOS asks for permission. Enable it under
   `System Settings → Privacy & Security → Automation → playlist-convert → Music`.

Subsequent runs are silent — Spotify tokens are cached at
`~/Library/Application Support/PlaylistConvert/spotify-tokens.json` (mode 0600).

## Usage

```sh
playlist-convert "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M"
```

Accepts any of:
- `https://open.spotify.com/playlist/<22-char-id>` (with or without locale prefix or `?si=` query)
- `spotify:playlist:<22-char-id>`
- bare 22-char ID

### Options

| Flag | Description |
| --- | --- |
| `--name <string>` | Override the target Apple Music playlist name. |
| `--description <string>` | Override the target playlist description. |
| `--match-threshold <0–100>` | Score threshold for accepting a search-tier match. Default 85. Lower for more matches, higher for stricter. |
| `--dry-run` | Match only; do not create the Apple Music playlist. |
| `--report-path <path>` | Path for the unmatched-tracks CSV. Default `./report.csv`. |
| `--verbose` | Print each unmatched track and its best candidate. |

### Output

```
✓ Spotify authorized
Fetched 247 tracks from 'Late Night Coding'
✓ Apple Music authorized
Matching: 247/247 (ISRC: 211, search: 28)
Adding to Music: 239/239

─── Conversion summary ───
 playlist:        Late Night Coding
 matched:         239/247 (96.8%)
   - by ISRC:     211
   - by search:   28
 skipped (local): 0
 unmatched:       8
 Apple Music URL: musicapp://playlist/9876ABCD…
 report:          ./report.csv
```

The CSV has one row per unmatched track:
`spotify_id, title, artists, album, isrc, duration_ms, reason, best_candidate_title, best_candidate_artist, score`.

## Troubleshooting

- **"AppleScript failed: not authorized"** — System Settings → Privacy &
  Security → Automation → playlist-convert → enable Music.
- **"Apple Music access not granted"** — System Settings → Privacy & Security
  → Media & Apple Music → enable playlist-convert. Music.app must be installed
  and signed in.
- **"Spotify: 401 unauthorized"** — Delete the cached token and re-run:
  `rm ~/Library/Application\ Support/PlaylistConvert/spotify-tokens.json`.
- **"Spotify: playlist not found"** — Check the URL and that you have
  permission to view the playlist (the Client ID is yours, but the playlist
  must be visible to the Spotify account that authorized).
- **Match rate is low** — Try `--match-threshold 75`. Tracks tagged with
  `"Remastered"`, `"(feat. X)"`, etc. should already be normalized away;
  remaining misses are usually catalog gaps in your storefront.

## Project layout

```
PlaylistConvert/
  Package.swift                       SPM, embeds Info.plist via -sectcreate
  Sources/PlaylistConvert/
    PlaylistConvert.swift             ArgumentParser entrypoint + main pipeline
    Config.swift                      paths, user config loader
    Models.swift                      SpotifyTrack, MatchResult, ConversionReport
    Spotify/
      SpotifyAuth.swift               PKCE flow, local 127.0.0.1 listener, token cache
      SpotifyClient.swift             paginated playlist fetch
      PlaylistURLParser.swift         URL / URI / bare ID
    AppleMusic/
      Authorization.swift             MusicAuthorization.request()
      AppleMusicClient.swift          MusicKit search (ISRC + text)
      MusicAppBridge.swift            osascript wrapper for Music.app
      PlaylistCreator.swift           drives MusicAppBridge per matched song
    Matching/
      Normalizer.swift                strip "(feat.)", "Remastered", diacritics, …
      Matcher.swift                   tiered ISRC → search → score
    Reporting/
      Report.swift                    console summary + CSV writer
    Resources/Info.plist              NSAppleMusicUsageDescription
  Tests/PlaylistConvertTests/         XCTest suites for parser, normalizer, matcher
```

## Tests

```sh
swift test
```

Covers `PlaylistURLParser` (12 cases), `Normalizer` (18 cases),
`StringSimilarity`/Levenshtein (7 cases), and `Matcher` scoring + tier
selection (12 cases) — 50 tests in total. None hit the network or
Music.app; the matcher is parameterized over a `CatalogLookup` so synthetic
candidate sets can be passed directly.

## Limitations

- Catalog availability differs by storefront. A track on Spotify may not exist
  in your Apple Music country — that's an unmatched track, not a bug.
- Music.app must be running (the bridge launches it if needed).
- The `add by URL` AppleScript path requires an active Apple Music
  subscription so catalog tracks resolve in the user's library.
- This tool is for personal use only. No notarization, no distribution.
