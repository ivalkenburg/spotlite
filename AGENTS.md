# Spotlite

macOS 26 app launcher (Swift package, AppKit, no Xcode project). Goal #1: fast and light.

## Layout

- `Sources/SpotliteCore`: pure Swift, no AppKit. Matcher, calculator, result assembly, index, preferences. Tested headless in `Tests/SpotliteCoreTests`.
- `Sources/Spotlite`: AppKit layer (panel, settings, hotkey, launching).
- Keep logic in Core where possible so it stays testable.

## Commands

```sh
make          # build + sign into build/Spotlite.app
make run      # build, kill running copy, open
make test     # swift test
make install  # copy to /Applications (required for Start at login)
make dmg      # build/Spotlite-<version>.dmg
```

## Commits

- Use semantic commit messages: `<type>[optional scope]: <description>` (Conventional Commits).
- Choose the type that describes the change, such as `fix`, `feat`, `refactor`, `perf`, `test`, `docs`, or `chore`. Example: `fix(matcher): rank consecutive matches above scattered letters`.

## Performance rules

- Idle CPU must stay 0%. Avoid polling; the only timer is a coalescible 5 s caffeine refresh.
- Keep memory to a minimum. Idle is ~32 MB (45 MB with menu bar icon); ~88 MB after first panel open, mostly `NSGlassEffectView`.
- Matching runs synchronously on the main thread (~28 µs for the full index). Don't move it to a queue.
- Icons load on a background queue (~670 µs each), only for visible rows.
- Hotkey uses Carbon `RegisterEventHotKey`: no Accessibility permission, no per-keystroke wakeups.
- Measure with `--bench` before and after touching the matcher or ranking.

## Data

- App index: depth-2 scan of `/Applications`, `/System/Applications`, `/System/Library/CoreServices/Applications`, `~/Applications`; background-only agents skipped; localized Finder names. Cached in `~/Library/Caches/Spotlite`, refreshed by FSEventStream (2 s latency) and an mtime check on panel open.
- Prefs and launch history: `~/Library/Application Support/Spotlite`. Never mix with the cache (index is regenerable, prefs are not).
- Not sandboxed: a sandboxed app can't launch arbitrary apps.

## Dev hooks

| Hook | Effect |
| --- | --- |
| `--bench` | Time the matcher against the real index |
| `--search <query>` | Print ranked results with scores |
| `--dump` | Print the index |
| `SPOTLITE_SHOW_ON_LAUNCH=1` | Show the panel at launch |
| `SPOTLITE_DEV_FRAMES=1` | Dump view frames (collapsed, expanded for `SPOTLITE_DEV_QUERY` or "a") and exit |
| `SPOTLITE_DEV_SEQUENCE=1` | Show, type, clear; log panel frames |
| `SPOTLITE_DEV_MENU=1` | Exercise Caffeinate submenu keys, toggle and filtering; dump frames and exit |
| `SPOTLITE_DEV_COMPLETION=1` | Exercise app completion modes, caret and Backspace; dump search and settings frames and exit |
| `SPOTLITE_DEV_UTILITIES=1` | Exercise conversion cards, UUID actions, Utility settings and visibility; preserve clipboard, dump frames and exit |
| `SPOTLITE_DEV_PIN=1` | Keep the panel open when it loses focus |
| `SPOTLITE_DEV_QUERY=<q>` | Prefill a query |

For layout bugs, compare `SPOTLITE_DEV_FRAMES` output against what the layout code claims; screenshots alone have missed bugs.

## Releasing

Releases are not notarized (no Developer ID). `make release` needs a Developer ID and is unused until one exists.

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. `make dmg IDENTITY="<Apple Development identity>" SIGN_FLAGS="--options runtime --timestamp"`. Always pass `IDENTITY` explicitly; the default picks the first Apple Development cert, which may be the wrong one.
3. `gh release create v<version> build/Spotlite-<version>.dmg`
4. `make cask` writes `build/spotlite.rb` from `packaging/spotlite.rb`; copy it to `Casks/` in `ivalkenburg/homebrew-tap`.
