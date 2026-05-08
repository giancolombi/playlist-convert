# playlist-convert

Convert a Spotify playlist into an Apple Music playlist on this Mac. macOS-only,
local-only, no developer accounts required.

## What it does

1. Fetches a Spotify playlist via the Spotify Web API (PKCE auth — no Spotify
   secret needed, just a free Client ID).
2. Matches each track against the Apple Music catalog via the public iTunes
   Search API. Title + artist scoring is 50/35/15 (title/artist/duration),
   normalized to drop "(feat.)", "Remastered", diacritics, etc., and gated by
   `--match-threshold` (default 85).
3. Creates a playlist in Apple Music and adds the matches by driving Music.app
   via AppleScript. Per-track add failures don't abort the run.
4. Writes an unmatched-tracks CSV report so you can see exactly what was skipped
   and why.

## Why no MusicKit / no developer account

MusicKit catalog APIs require a Music developer token, which on macOS is minted
from a code-signing identity that has the `com.apple.developer.musickit`
entitlement. That entitlement is gated by **paid** Apple Developer membership
($99/yr) — Personal Teams and ad-hoc signing can't get it. Same blocker for
the Apple Music Web API (needs a `.p8` private key from a paid account).

The iTunes Search API (`https://itunes.apple.com/search`) is public and
returns the same Apple Music catalog song IDs that Music.app uses, so we use
that for catalog lookup and then drive Music.app via AppleScript to actually
create the playlist and add tracks. Result: 100% local, no paid accounts, no
keys, no entitlements.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode command line tools (`xcode-select --install`)
- Apple Music subscription, signed into Music.app on this Mac
- A free Spotify Developer app (used only for the Client ID)

## Install

```sh
make install
```

That's it. `make install` builds in release mode, ad-hoc signs the binary, and
symlinks it to `/usr/local/bin/playlist-convert`. (Override the location with
`PREFIX=$HOME/.local make install`.)

If `xcode-select -p` errors, run `xcode-select --install` first.

## First run

Just run it:

```sh
playlist-convert
```

On the first invocation the tool walks you through everything that's
genuinely user-driven:

1. **Spotify Client ID wizard** — opens the Spotify developer dashboard in
   your browser and asks you to paste the Client ID. Saved to
   `~/.config/playlist-convert/config.json` (mode 0600). One-time only.
2. **Playlist URL** — if you already copied a Spotify playlist URL to your
   clipboard, the tool detects it and offers it as the default; press Return
   to accept. Otherwise, paste any URL / URI / 22-char ID.
3. **Two OS permission prompts** (deliberately gated by macOS):
   - Browser opens for Spotify authorization. After the redirect to
     `127.0.0.1:8888` you can close the tab.
   - macOS asks for permission to control Music.app via AppleScript —
     accept. If you miss it: System Settings → Privacy & Security →
     Automation → playlist-convert → enable Music.

Subsequent runs are silent — Spotify tokens are cached at
`~/Library/Application Support/PlaylistConvert/spotify-tokens.json` (mode 0600).

## Usage

```sh
# Interactive — prompts for the playlist (uses clipboard if it's a Spotify URL)
playlist-convert

# Non-interactive — pass the URL directly
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
Matching: 247/247 (ISRC: 0, search: 218)
Adding to Music: 218/218

─── Conversion summary ───
 playlist:        Late Night Coding
 matched:         218/247 (88.3%)
   - by ISRC:     0
   - by search:   218
 skipped (local): 0
 unmatched:       29
 Apple Music URL: musicapp://playlist/9876ABCD…
 report:          ./report.csv
```

> The "by ISRC" tier is currently always 0 — Apple's iTunes Search API
> doesn't index ISRCs reliably, so we go straight to text search. Match
> quality is lower than what MusicKit catalog access would give, but it
> doesn't require a paid developer account. Expect ~70–95% match depending
> on how mainstream the playlist is.

The CSV has one row per unmatched track:
`spotify_id, title, artists, album, isrc, duration_ms, reason, best_candidate_title, best_candidate_artist, score`.

## Troubleshooting

- **"AppleScript failed: not authorized"** — System Settings → Privacy &
  Security → Automation → playlist-convert → enable Music.
- **"iTunes search rate-limited (403)"** — Apple's anonymous rate cap
  (~20 req/min) was hit. The tool backs off 30s and continues. Long playlists
  on a stale IP can trip this several times; the run still completes.
- **"Spotify: 401 unauthorized"** — Delete the cached token and re-run:
  `rm ~/Library/Application\ Support/PlaylistConvert/spotify-tokens.json`.
- **"Spotify: playlist not found"** — As of Nov 2024 Spotify dev-mode apps
  can only read playlists the authorizing user **owns** or collaborates on.
  Spotify-owned editorial playlists (`37i9dQZF1DX…`) return 404. Workaround:
  duplicate the editorial playlist into one of your own (right-click →
  "Add to other playlist" → "+ New playlist") and use the URL of your copy.
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
      AppleMusicClient.swift          iTunes Search API client + 1.2s throttle
      MusicAppBridge.swift            osascript wrapper for Music.app
      PlaylistCreator.swift           drives MusicAppBridge per matched song
    Matching/
      Normalizer.swift                strip "(feat.)", "Remastered", diacritics, …
      Matcher.swift                   tiered ISRC → search → score
    Reporting/
      Report.swift                    console summary + CSV writer
    Resources/Info.plist              CFBundleIdentifier (used by Automation perms)
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
- iTunes Search API doesn't expose ISRC lookup, so we rely on text matching
  only. Mainstream tracks match well (~90%); ambient / classical / regional
  catalogs match worse. Lower `--match-threshold` if you'd rather over-match.
- Anonymous iTunes API rate limits (~20 req/min) mean a 200-track playlist
  takes ~5 minutes of matching time even on the happy path.
- Music.app must be running (the bridge launches it if needed) and signed
  into an Apple Music subscription so catalog URLs resolve.
- macOS-only. No notarization, no distribution. Build it from source for the
  Mac you're running it on.

## License

MIT — see [LICENSE](./LICENSE).
