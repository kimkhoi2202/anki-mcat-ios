# Anki for iOS — native SwiftUI port of AnkiDroid

A native **SwiftUI** iOS client for Anki, built on Anki's **shared Rust engine**
(`rslib`). The UI is a faithful re-implementation of AnkiDroid's feature set;
the scheduler (FSRS), SQLite collection, sync, search, and card rendering are
reused as-is from the engine — not reimplemented.

## Architecture

```
rslib (Rust, in ../anki-desktop/main)
      │  C-FFI:  run_service_method(service, method, protobuf_bytes) -> bytes
AnkiCore.xcframework   (ankicore-ffi static lib; built by AnkiCore/build-xcframework.sh)
      │
AnkiKit  (Swift package)   typed RPC wrappers + generated protobufs + Keychain
      │
AnkiApp  (SwiftUI)         Decks · Reviewer · Browser · Editor · Sync · Stats · Settings · …
```

Card rendering uses `WKWebView` (the same approach real Anki clients use); every
other screen is native SwiftUI.

## Features

- **Study:** deck list with due counts, Reviewer with notetype CSS, image media,
  interval previews, undo, a card-action menu (flag / mark / edit / bury /
  suspend / delete / replay / card-info), and tap/swipe gestures.
- **Content:** note add/edit, Card Browser (search), Card Info, Change Note Type.
- **Decks:** create / rename / delete, deck options (daily limits), filtered decks.
- **Data:** Sync (AnkiWeb or a custom server), Import/Export `.apkg`/`.colpkg`,
  Statistics, Settings.

## Prerequisites

- macOS with **Xcode 16+** and an iOS 17 simulator.
- **Rust 1.92.0** + iOS targets:
  `rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin`
- **XcodeGen:** `brew install xcodegen`
- The desktop fork checked out at **`../anki-desktop/main`** (provides `rslib`).

## Build & run

```bash
# 1. Build the engine framework (once; and after any rslib change)
cd AnkiCore && ./build-xcframework.sh

# 2. Generate the Xcode project and build the app
cd ../AnkiApp && xcodegen generate
xcodebuild -project AnkiSpeedrun.xcodeproj -scheme AnkiSpeedrun \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -derivedDataPath build -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build

# …or just: open AnkiSpeedrun.xcodeproj   (then Run)
```

**Device builds:** set `DEVELOPMENT_TEAM` to your Apple Team ID in
`AnkiApp/project.yml` (or pass `DEVELOPMENT_TEAM=XXXX` to `xcodebuild`),
`xcodegen generate`, then build to a connected device. Simulator builds need no team.

## Tests

```bash
cd AnkiKit && swift test     # 43 engine-backed unit tests
```

## Sync

- **AnkiWeb (default):** log in with your AnkiWeb account on the Sync screen.
- **Self-hosted (recommended, version-matched):** `deploy/syncserver/` contains a
  Fly.io Dockerfile + `fly.toml` pinned to the engine's exact commit (a bleeding-edge
  engine can mismatch AnkiWeb's older server on full-upload). In the app, set
  **Custom sync server** to your server URL.

## Project layout

| Path | What |
| --- | --- |
| `AnkiCore/` | Rust C-FFI shim → `AnkiCore.xcframework` (+ `build-xcframework.sh`) |
| `AnkiKit/` | Swift package wrapping the engine (RPC wrappers, generated protos, tests) |
| `AnkiApp/` | the SwiftUI app (XcodeGen project from `project.yml`) |
| `deploy/syncserver/` | self-hosted, version-matched sync server (Fly.io) |
| `docs/` | build/architecture notes |

## MCAT "Speedrun" layer (optional, in progress)

This repo is also the base for an MCAT study-app challenge. Status of the graded pieces:

- **Rust engine change** — points-at-stake review queue: **done** in the desktop
  fork (`anki-mcat`) `main` (8 Rust + 3 Python tests, undo/no-corruption proven).
- **iOS "Focus Weak Topics" + MCAT coverage map + abstain** — on `feat/ios-client`.
- **Three honest scores** (Memory / Performance / Readiness) + dashboard — on
  branch **`feat/mcat-scores`** (not yet merged).
- **Benchmark + crash tests** — desktop fork.
- **AI card-gen + evaluations** — not started (needs an LLM API key).

## Known limitations

- Parity gaps vs AnkiDroid: audio playback / TTS, whiteboard, full Card-Browser
  columns + bulk ops, the Svelte deck-options page, home-screen widgets.
- QA so far is render + action-hook level on the simulator; deep interaction and
  on-device QA are still pending.

## License

AGPL-3.0-or-later, with credit to **Anki** (github.com/ankitects/anki). Some
upstream components are BSD-3-Clause.
