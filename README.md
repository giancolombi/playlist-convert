# playlist-convert

Match a Spotify playlist against the Apple Music catalog and emit a list of
Apple Music URLs (one per matched track) plus a CSV report. macOS-only,
local-only, no developer accounts required.

> **Why it stops at matching, not playlist creation.** macOS doesn't allow
> third-party tools without paid Apple Developer access to mutate your Apple
> Music library. MusicKit's playlist-write APIs are
> `@available(macOS, unavailable)`; Music.app's AppleScript `add` command
> only accepts local files, not catalog URLs. So this tool gives you the
> URLs and you do the final 30 seconds of clicks. See [Limitations](#limitations).

## What it does

1. **Fetches** a Spotify playlist via the Spotify Web API (PKCE auth — no
   client secret, just a free Client ID).
2. **Matches** each track against the public iTunes Search API
   (`https://itunes.apple.com/search`) — same catalog as Apple Music,
   no auth, no developer account. Title + artist + duration scoring is
   50/35/15, normalized to drop `"(feat.)"`, `"Remastered"`, diacritics,
   etc., gated by `--match-threshold` (default 85).
3. **Writes** two artifacts:
   - `matches.txt` — one Apple Music URL per matched track, ready to feed to
     `open` or paste into Music.app.
   - `report.csv` — every Spotify track with match status, URL, and
     unmatched reasons.
4. **You** open Music.app, make a new playlist, and add the matched tracks
   (one `xargs` line takes care of bulk-loading them).

## Why no MusicKit / no paid developer account

| Path | Status on macOS without paid dev membership |
| --- | --- |
| MusicKit catalog search (`MusicCatalogSearchRequest`) | ❌ Returns `MusicTokenRequestError.developerTokenRequestFailed`. Needs `com.apple.developer.musickit` entitlement, which is gated by paid Developer Program membership. |
| MusicKit playlist mutation (`createPlaylist(items:)`, `add(_:to:)`) | ❌ Marked `@available(macOS, unavailable)` regardless of signing. iOS-only. |
| Apple Music Web API (`api.music.apple.com`) | ❌ Needs a `.p8` private key from a paid Developer account. |
| AppleScript `add URL to playlist` in Music.app | ❌ `add` direct-parameter is `<type type="file">`. Returns `error -43 File not found` on Apple Music URLs. |
| iTunes Search API (`itunes.apple.com/search`) | ✅ Public, no auth, returns Apple Music catalog song IDs and URLs. |
| Music.app drag-drop / clicking the `+` button by hand | ✅ Always works. |

So the architecture is: iTunes Search API for matching, you for the final
mutation. The CSV + URL list bridges the gap.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode command line tools (`xcode-select --install`)
- Apple Music subscription (so the URLs resolve when you open them)
- A free Spotify Developer app — used only for the Client ID

## Install

```sh
make install
```

Builds in release mode, ad-hoc signs the binary, symlinks it to
`/usr/local/bin/playlist-convert`. Override the location with
`PREFIX=$HOME/.local make install`.

## First run

```sh
playlist-convert
```

On the first run the tool walks you through everything that's user-driven:

1. **Spotify Client ID wizard** — opens the Spotify developer dashboard in
   your browser, asks you to create a free app (Redirect URI must be
   `http://127.0.0.1:8888/callback`), and prompts for the Client ID.
   Saved to `~/.config/playlist-convert/config.json` (mode 0600). One-time.
2. **Playlist URL** — if your clipboard already has a Spotify playlist URL,
   the tool offers it as the default; press Return to accept. Otherwise
   paste a URL, URI, or 22-char ID.
3. **One OS permission prompt:** browser opens for Spotify authorization
   (PKCE, runs once). After the redirect to `127.0.0.1:8888/callback` you
   can close the tab.

Subsequent runs are silent — Spotify tokens are cached at
`~/Library/Application Support/PlaylistConvert/spotify-tokens.json` (mode 0600).

## Usage

```sh
# Interactive (prompts for the playlist; clipboard auto-detected)
playlist-convert

# Non-interactive
playlist-convert "https://open.spotify.com/playlist/<id>"
```

Accepts:
- `https://open.spotify.com/playlist/<22-char-id>` (with or without `intl-*` prefix or `?si=` query)
- `spotify:playlist:<22-char-id>`
- bare 22-char ID

### Options

| Flag | Description |
| --- | --- |
| `--match-threshold <0–100>` | Score threshold for accepting a match. Default 85. Lower = more matches, more noise. |
| `--matches-path <path>` | Where to write the URL list. Default `./matches.txt`. |
| `--report-path <path>` | Where to write the CSV. Default `./report.csv`. |
| `--verbose` | Print each unmatched track and its best candidate. |

### Output

```
✓ Spotify authorized
Fetched 247 tracks from 'Late Night Coding'
Matching: 247/247 (search: 218)

─── Conversion summary ───
 playlist:        Late Night Coding
 matched:         218/247 (88.3%)
   - by ISRC:     0
   - by search:   218
 skipped (local): 0
 unmatched:       29
 matches:         ./matches.txt
 report:          ./report.csv

Next: open Music.app, make a new playlist, then either
  • run:  xargs -I{} open '{}' < ./matches.txt   (loads each in Music.app)
  • or click each URL in ./matches.txt one at a time.
Then in Music.app drag the loaded songs into your playlist.
```

The `report.csv` has one row per Spotify track:
`spotify_id, title, artists, album, isrc, duration_ms, tier, score, apple_music_id, apple_music_url, best_candidate_title, best_candidate_artist, reason`.

The "by ISRC" tier is always 0 — the iTunes Search API doesn't index ISRCs
reliably, so we rely on text matching alone. Match quality is therefore lower
than what MusicKit would give: ~70-95% depending on how mainstream the
playlist is.

## Loading matches into Music.app

After the run finishes, the simplest path is:

```sh
# In Music.app: File → New Playlist (Cmd-N), name it, leave it open.
# Then in Terminal:
xargs -I{} open '{}' < matches.txt
```

`open` hands each URL to Music.app, which loads the song. From there:
1. In Music.app, navigate to each loaded song.
2. Click the `+` (or right-click → "Add to Library").
3. Drag from your library into your new playlist (or right-click → "Add to
   Playlist" → your playlist).

There's no scripted shortcut for that last step; it's the macOS limitation
this tool exists around.

## Troubleshooting

- **"iTunes search rate-limited (403)"** — Apple's anonymous rate cap is
  ~20 req/min, with deeper IP-level penalties after sustained traffic. The
  tool's adaptive throttle (1.5–6 s between requests, 45 s pause on 403)
  recovers, but if you've been rate-limited heavily the IP can stay in
  penalty for 15–30 min. Wait, then re-run.
- **"Spotify: 401 unauthorized"** — Delete the cached token and re-run:
  `rm ~/Library/Application\ Support/PlaylistConvert/spotify-tokens.json`.
- **"Spotify: playlist not found"** — As of Nov 2024 Spotify dev-mode apps
  can only read playlists the authorizing user **owns** or collaborates on.
  Spotify-owned editorial playlists (`37i9dQZF1DX…`) return 404. Fix:
  duplicate the playlist into your own library (right-click → "Add to other
  playlist" → "+ New playlist") and use that URL.
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
    SetupWizard.swift                 first-run Spotify Client ID wizard
    InteractivePrompt.swift           clipboard-aware playlist URL prompt
    Models.swift                      SpotifyTrack, MatchResult, AppleMusicSong, …
    Spotify/
      SpotifyAuth.swift               PKCE flow, local 127.0.0.1 listener, token cache
      SpotifyClient.swift             paginated playlist fetch
      PlaylistURLParser.swift         URL / URI / bare ID
    AppleMusic/
      AppleMusicClient.swift          iTunes Search API client + adaptive throttle
    Matching/
      Normalizer.swift                strip "(feat.)", "Remastered", diacritics, …
      Matcher.swift                   text-search match + 50/35/15 scoring
    Reporting/
      Report.swift                    console summary + CSV + URL list writers
    Resources/Info.plist              CFBundleIdentifier + Apple Events usage
  Tests/PlaylistConvertTests/         XCTest suites
```

## Tests

```sh
make test    # or: swift test
```

50 unit tests across `PlaylistURLParser` (12), `Normalizer` (18),
`StringSimilarity`/Levenshtein (7), `Matcher` scoring + tier selection (12),
plus a smoke test. None of them hit the network — the matcher is
parameterised over a `CatalogLookup` so synthetic candidate sets can be
passed directly.

## Limitations

- **No final automation.** The tool stops at "here are the URLs to add."
  See [Why no MusicKit](#why-no-musickit--no-paid-developer-account) for the
  underlying macOS API constraints.
- **Match quality is text-only.** iTunes Search API doesn't expose ISRC
  lookup, so we rely on title + artist matching. Mainstream tracks match
  well (~90%); ambient / classical / regional catalogs match worse. Lower
  `--match-threshold` if you'd rather over-match.
- **Rate limits are real.** Anonymous iTunes API caps you at ~20 req/min
  with deeper IP-level penalties. A 200-track playlist takes ~5–10 minutes
  of wall time on the happy path; longer if you've been rate-limited.
- **Catalog availability differs by storefront.** A track on Spotify may
  simply not exist in your Apple Music country.
- **macOS-only.** No notarization, no distribution. Build from source.

## License

MIT — see [LICENSE](./LICENSE).

## Contributing

PRs welcome. The primary upgrade path I'd love to see:

- A polished AppleScript / Shortcuts.app handoff that lets a paid-developer
  user (or the Shortcuts.app's privileged Music actions) ingest `matches.txt`
  and create the playlist for them.
- An iOS sibling: MusicKit playlist mutation works there for free, so the
  same matching pipeline could ship as a Shortcut input source.
