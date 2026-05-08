# CLAUDE.md

Context for AI coding agents working on this repo. Read this before suggesting
architectural changes — most "obvious" improvements have been tried and are
documented here as dead ends.

If you're a human developer, [README.md](./README.md) is what you want.

## What this is

A macOS CLI (Swift, SPM) that takes a Spotify playlist URL, matches each
track against the Apple Music catalog via the public iTunes Search API,
emits two files (`matches.txt` of Apple Music URLs, `report.csv` of
per-track status), and creates an empty playlist in Music.app for the user
to drag the matches into. The tool stops at the matching boundary because
macOS does not let third-party tools without paid Apple Developer access
fill that playlist programmatically.

## Build, test, run

```sh
make install          # build release + ad-hoc sign + symlink to /usr/local/bin
make build            # release build at .build/release/PlaylistConvert
make sign             # ad-hoc codesign (required for Music.app Automation)
make test             # 50 XCTest cases — none hit the network
make clean            # nuke .build
```

Direct invocation if you don't want the symlink:
`./.build/release/PlaylistConvert "<spotify-url>"`.

## Source layout

```
Sources/PlaylistConvert/
  PlaylistConvert.swift        ArgumentParser entrypoint + main pipeline
  Config.swift                 paths, user-config loader, UA constants
  SetupWizard.swift            first-run Spotify Client ID wizard
  InteractivePrompt.swift      clipboard-aware playlist URL prompt
  Models.swift                 SpotifyTrack, MatchResult, AppleMusicSong, …
  Spotify/
    SpotifyAuth.swift          PKCE flow, local 127.0.0.1:8888 NWListener, token cache
    SpotifyClient.swift        paginated /v1/playlists/{id}/tracks fetch
    PlaylistURLParser.swift    URL / URI / bare ID parsing
  AppleMusic/
    AppleMusicClient.swift     iTunes Search API client + adaptive throttle
    MusicAppBridge.swift       osascript → Music.app for empty-playlist creation
  Matching/
    Normalizer.swift           strip "(feat.)", "Remastered", diacritics, …
    Matcher.swift              text-search match + 50/35/15 scoring
  Reporting/
    Report.swift               console summary + CSV + URL list writers
  Resources/Info.plist         CFBundleIdentifier + NSAppleEventsUsageDescription
Tests/PlaylistConvertTests/    XCTest suites — parser/normalizer/matcher
```

## Key architectural facts

### Info.plist is embedded into the binary

`Package.swift` uses `linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", …])]`
to bake `Info.plist` into the `__TEXT` `__info_plist` section. Verify with
`codesign -dvv .build/release/PlaylistConvert` — should show `Info.plist
entries=N` and the `CFBundleIdentifier` from the plist. If macOS isn't
showing the right Automation prompt copy on first run, this is usually why.

### Configuration paths

| What | Where | Mode |
| --- | --- | --- |
| Spotify Client ID | `~/.config/playlist-convert/config.json` | 0600 |
| Cached Spotify tokens | `~/Library/Application Support/PlaylistConvert/spotify-tokens.json` | 0600 |
| Output URL list | `./matches.txt` (gitignored) | — |
| Output CSV | `./report.csv` (gitignored) | — |

### Spotify

- PKCE flow with S256. No client secret. Public Client ID only.
- `LocalCallbackListener` (Network.framework) binds to `127.0.0.1:8888`,
  catches one HTTP request, returns a small HTML page, fires the
  `CheckedContinuation` with the parsed query params.
- Tokens cached to `~/Library/Application Support/PlaylistConvert/spotify-tokens.json`.
  Refresh transparently; only re-run the browser flow if refresh fails.
- Scopes: `playlist-read-private playlist-read-collaborative`.
- **Important Spotify constraint:** as of Nov 2024, Spotify dev-mode apps
  can only read playlists the authorizing user **owns** or **collaborates
  on**. Spotify-owned editorial playlists (`37i9dQZF1DX…`) return 404.
  Workaround documented in README troubleshooting.

### iTunes Search API (Apple Music catalog)

- `https://itunes.apple.com/search?term=...&entity=song&media=music&limit=10`.
- No auth. Returns Apple Music catalog song IDs and the `trackViewUrl` form
  (`https://music.apple.com/us/album/.../{id}?i={id}`). These URLs work
  with Music.app's own URL handler.
- **`itunesUserAgent` (Safari 17 UA) matters.** Apple's API rate-limits
  unfamiliar UAs more aggressively. We use Safari for iTunes, the honest
  `PlaylistConvert/0.1 (local)` for Spotify (which doesn't care).
- **`ITunesThrottle` is adaptive**: starts at 1.5s gap, widens by 1.0s on
  each 403/429 (capped at 6s), heals 0.5s after every 20 successes. On
  rate limit it sleeps 45–50s + jitter before retrying (the iTunes window
  is empirically longer than 60s for IPs that have been hammered).
- **No ISRC tier.** iTunes Search API doesn't index ISRCs reliably. Adding
  a probe by ISRC just doubled rate-limit pressure for negligible gain.
  `findByISRC` is kept for symmetry but always returns nil.

### Music.app AppleScript bridge

- `MusicAppBridge.createEmptyPlaylist(name:description:)` runs osascript
  with `make new user playlist with properties {…}` and returns the
  persistent ID. This is the **only** library mutation we can do without
  paid dev access.
- First call triggers the macOS Automation prompt (Privacy & Security →
  Automation → playlist-convert → Music). If denied, the CLI soft-fails
  and prints a manual-create note instead of aborting.

## What we tried that does not work — DO NOT redo

These are documented in commit messages, but listing them here so future
work doesn't burn time relitigating.

| Attempt | Result |
| --- | --- |
| MusicKit `MusicCatalogSearchRequest` / `MusicCatalogResourceRequest` | ❌ `MusicTokenRequestError.developerTokenRequestFailed`. Catalog access needs `com.apple.developer.musickit` entitlement → paid Apple Developer membership. |
| MusicKit `MusicLibrary.shared.createPlaylist(items:)` | ❌ `@available(macOS, unavailable)`. iOS-only. Confirm from `MusicKit.framework/.../arm64e-apple-macos.swiftinterface` if you doubt this. |
| MusicKit `MusicLibrary.shared.add(_:to:)` | ❌ Same — `@available(macOS, unavailable)`. |
| Apple Music Web API (`api.music.apple.com`) | ❌ Needs a `.p8` private key from a paid dev account. Same blocker. |
| AppleScript `add "<music.apple.com URL>" to playlist` | ❌ `error -43 File not found`. The `add` command's direct-parameter is `<type type="file">` — local files only. |
| AppleScript `add 1234567890 to playlist` (raw ID) | ❌ `error -1700 Can't make some data into the expected type`. |
| `add "itmss://music.apple.com/..." to playlist` | ❌ Same `-43`. |
| `(first track whose database ID is N)` for catalog song IDs | ❌ `error -1728 object not found` — only finds tracks **already in the user's library**, not catalog at large. Tested on 5 random matched IDs, all missed. |
| Personal Team signing instead of ad-hoc | ❌ Doesn't grant the Music capability. Same `developerTokenRequestFailed`. |
| `head -25` or `head -N` piped from the binary's progress output | ❌ Not architectural, but will mislead you in dev: progress lines use `\r` so the line count is misleading. Use `tr '\r' '\n' | tail -N` to inspect mid-run. |

## Constraints to remember when editing

- **No paid Apple Developer membership** is assumed. Don't add code paths
  that require it (no MusicKit catalog, no Apple Music Web API JWT, no
  Music capability entitlement).
- **No notarization, no distribution.** This is a local-build tool. Each
  user builds + ad-hoc signs on their own Mac.
- **No third-party HTTP client.** `URLSession.shared` only. No `Alamofire`,
  no async-http-client.
- **No third-party fuzzy-match library.** Levenshtein is ~30 lines in
  `Normalizer.swift`. Don't pull in a dep for it.
- **Tests don't hit the network.** `Matcher` is parameterized over
  `CatalogLookup`, so synthetic candidates can be passed directly. Keep
  it that way.
- **`Config.spotifyUserAgent` and `Config.itunesUserAgent` exist for a
  reason.** The Safari UA on iTunes calls is a real fix for rate-limit
  aggression, not a cosmetic.
- **Output paths.** `report.csv` and `matches.txt` are gitignored. The
  binary writes them via `Report.writeCSV` / `Report.writeURLList`.
- **`@main` cannot live in a file named `main.swift`.** The entrypoint
  file is `PlaylistConvert.swift`.

## When something breaks at runtime

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| First-run Automation prompt never appears | Info.plist not embedded | Run `codesign -dvv .build/release/PlaylistConvert`; should show `Info.plist entries>0`. Check `Package.swift` linker flags. |
| `developerTokenRequestFailed` | Someone re-added MusicKit catalog calls | Don't. See the table above. |
| `error -43 File not found` from osascript | Someone re-added catalog-track add via `add URL` | Don't. See the table above. |
| `iTunes search rate-limited (403)` once or twice | Normal; adaptive throttle handles it | If it happens >5×, IP is in deep penalty — wait 15-30 min |
| `Spotify: playlist not found` | Editorial playlist | Tell user to duplicate it (README troubleshooting) |
| `Apple Music access not granted` (legacy text) | Stale error path; should not happen post-iTunes-pivot | Grep for any stale MusicAuthorization references |

## Where to look in git history

The repo has 14 commits with intentionally explanatory messages. If you
want to know **why** something is the way it is, `git log -p <file>`
will get you to the answer faster than re-reasoning from scratch. The
two architectural pivot commits are particularly worth reading:

- `a897892` — drop MusicKit, use iTunes Search API
- `e099278` — drop AppleScript bridge for adding tracks, ship match-only
- `c71589b` — add back the empty-playlist scripted creation only

## Style

- Default to no comments; only when WHY is non-obvious or there's a
  hidden constraint (e.g., the rate-limit reasoning in `ITunesThrottle`).
- Don't add error handling for impossible scenarios. Trust internal code.
- Don't add `// TODO` comments. Either do it or skip it.
- One short doc line max for types/functions; never multi-paragraph
  docstrings.
