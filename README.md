# Anki for iOS — native SwiftUI port of AnkiDroid

A native **SwiftUI** iOS client for Anki, built on Anki's **shared Rust engine**
(`rslib`). The UI is a faithful re-implementation of AnkiDroid's feature set; the
scheduler (FSRS), SQLite collection, sync, search, media, and card rendering are
reused as-is from the engine — never reimplemented.

`main` is the clean, faithful AnkiDroid clone. The optional MCAT/"Speedrun" layer
lives on separate branches (see [Branches](#branches)).

## Architecture

```
rslib (Rust, in ../anki-desktop/main)
      │  C-FFI:  anki_run_command(service, method, protobuf_bytes) -> bytes
AnkiCore.xcframework   (ankicore-ffi static lib; built --release by AnkiCore/build-xcframework.sh)
      │
AnkiKit  (Swift package)   typed RPC wrappers + generated protobufs + Keychain
      │
AnkiApp  (SwiftUI)         Decks · Reviewer · Browser · Editor · Note Types · Sync · Stats · Settings · …
```

- Every screen is **native SwiftUI**, talking to the engine through `AnkiKit`.
- Anki's own shared **SvelteKit** pages are embedded in a `WKWebView` for the
  screens that are web-based in real Anki too — **Statistics, Card Info, Deck
  Options, and the Image-Occlusion editor** — served from the bundled
  `AnkiApp/Resources/sveltekit/` over a custom URL scheme with a `fetch → /_anki`
  bridge into the backend (the same pattern AnkiDroid uses). The reviewer's card
  body is also rendered via `WKWebView` with the notetype's real CSS.

## Features (AnkiDroid parity)

- **Study:** deck list with due counts + subdeck collapse/expand + deck overview;
  Reviewer with real card rendering, 4-button grading + interval previews,
  type-in-the-answer, native `[sound:]` + `{{tts}}` audio (autoplay + per-segment
  play buttons), remaining-count display, flag/mark/bury/suspend/delete/edit/undo,
  set-due-date, opt-in auto-advance, tap/swipe gestures.
- **Browse:** windowed Card Browser (scales to large collections) with search,
  multi-select + bulk actions (deck/flag/mark/suspend/bury/tags/delete),
  configurable columns, tap-to-sort, Notes/Cards mode, a filter sidebar
  (decks/tags/flags/state/saved-searches), Find & Replace, and card preview.
- **Create:** rich note editor (bold/italic/underline/super/sub, cloze with
  auto-numbering, MathJax, media insert: photo/camera/audio-record/file, sticky
  fields, add-another), Change Note Type, and a full **note-type / card-template
  editor** (Manage note types, Fields editor, Front/Back/CSS with live preview),
  plus the **Image-Occlusion** editor.
- **Decks:** create/rename/delete, per-deck actions (browse/add/export/unbury/
  create-subdeck), Deck Options (FSRS), filtered decks (two filters), and the full
  **Custom Study** preset dialog.
- **Data:** Sync (AnkiWeb or a custom server; collection + media; conflict
  resolution; Keychain-stored key), Import/Export `.apkg`/`.colpkg` **and CSV/TSV
  import wizard + notes/cards text export**, automatic **Backups** (+ create-now).
- **App:** Statistics, Settings (engine-backed Reviewing/Editing prefs, Sync
  options, Appearance incl. full-screen + interface size), first-launch onboarding,
  Shared-Decks browser (AnkiWeb), and a home-screen **WidgetKit** due-count widget.

## Prerequisites

- macOS with **Xcode 16+** and an iOS 17+ simulator.
- **Rust** + iOS targets:
  `rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin`
- **XcodeGen:** `brew install xcodegen`
- The desktop fork checked out at **`../anki-desktop/main`** (provides `rslib`).

## Build & run

```bash
# 1. Build the engine framework (once; and after any rslib change) — RELEASE-optimized
cd AnkiCore && ./build-xcframework.sh

# 2. Generate the Xcode project and build the app (run xcodebuild from the repo root)
cd ../AnkiApp && xcodegen generate
cd ..
xcodebuild -project AnkiApp/AnkiSpeedrun.xcodeproj -scheme AnkiSpeedrun \
  -destination "platform=iOS Simulator,name=iPhone 17" build

# …or: open AnkiApp/AnkiSpeedrun.xcodeproj   (then Run)
```

**Device builds:** simulator builds need no team; a **device** build needs a real
`DEVELOPMENT_TEAM` (set it in `AnkiApp/project.yml`, or pick your team in Xcode's
Signing & Capabilities tab after `xcodegen generate`). The entitlements files
intentionally ship **empty** — carrying an unprovisioned App Group entitlement
makes `cfprefsd` detach on device, corrupting normal `UserDefaults` reads (this
broke sync-server resolution). The home-screen widget therefore shows placeholder
counts until you register `group.com.khoilam.ankispeedrun` for your own team and
restore it in both `.entitlements` files.

## Tests

```bash
# Run from the canonical path (see the iCloud/.nosync note below):
cd -P AnkiKit && swift test        # 88 engine-backed unit tests
```

> **iCloud / `.nosync` note:** this project sits under an iCloud-synced folder via
> an `anki -> anki.nosync` symlink (keeps iCloud from churning build artifacts).
> Always run `swift test` with `cd -P` (the real path) — building `AnkiKit` through
> both the symlink and the real path can double the module cache and crash the
> compiler. If it ever happens: `rm -rf AnkiKit/.build` and rebuild from `cd -P`.

## Sync

- **Self-hosted (default):** the app defaults to the project's hosted sync server
  (`https://anki-mcat-sync.fly.dev/`, always-on). `deploy/syncserver/` is the
  Fly.io Dockerfile + `fly.toml` pinned to the engine's exact commit (a
  bleeding-edge engine can mismatch AnkiWeb's older server on a full upload).
- **AnkiWeb / other:** switch servers anytime in **Settings → Sync server**
  (while logged out).
- **TLS on iOS:** the engine is built with the `rustls` feature
  (pure-Rust TLS + bundled webpki roots). This is required — reqwest's default
  `native-tls` backend provides no working HTTPS transport on physical iOS
  devices, so every HTTPS sync would fail with a misleading
  `error sending request for url ()`. Don't build the xcframework without it
  (`AnkiCore/Cargo.toml` already enables it).

## Branches

| Branch | What |
| --- | --- |
| **`main`** | The clean, faithful AnkiDroid clone — the foundation to build on. |
| `speedrun/mcat-full` | Full MCAT/"Speedrun" layer (coverage map, weak-topics, points-at-stake UI). |
| `feat/mcat-scores` | MCAT layer + the three honest scores (Memory / Performance / Readiness) + dashboard. |

The MCAT-specific engine change (points-at-stake review queue) lives on the desktop
fork (`../anki-desktop/main`) branch `feat/rust-points-at-stake`. `main` here has
**no** MCAT app code.

## Project layout

| Path | What |
| --- | --- |
| `AnkiCore/` | Rust C-FFI shim → `AnkiCore.xcframework` (+ `build-xcframework.sh`) |
| `AnkiKit/` | Swift package wrapping the engine (RPC wrappers, generated protos, tests) |
| `AnkiApp/Sources/` | the SwiftUI app screens |
| `AnkiApp/AnkiWidget/` + `AnkiApp/Shared/` | the WidgetKit extension + shared App-Group snapshot |
| `AnkiApp/Resources/sveltekit/` | Anki's bundled web pages (Stats / Card Info / Deck Options / Image Occlusion) |
| `AnkiApp/project.yml` | XcodeGen project definition |
| `deploy/syncserver/` | self-hosted, version-matched sync server (Fly.io) |

## Status vs AnkiDroid

The long-tail items once listed here are now implemented: the
**whiteboard/drawing** overlay (PencilKit), **configurable gesture/tap-zone**
remapping (Settings ▸ Gestures — the full 3×3 tap grid + swipes/long-press),
**local review reminders** (Settings ▸ Notifications), and the **Advanced**
database tools (Check database / fsck, Empty cards, Force full sync, Restore from
backup). Auto-advance now defaults its answer action to **Bury** and sources its
timings from the deck's config.

Remaining items are environment/polish rather than missing features: the
home-screen **widget** needs an Apple developer team for an on-device build (it
runs in the simulator), and **localization** + App Store metadata are left for
publishing time.

## License

AGPL-3.0-or-later, with credit to **Anki** (github.com/ankitects/anki). Some
upstream components are BSD-3-Clause.
