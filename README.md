# Anki for iOS — native SwiftUI port of AnkiDroid

A native **SwiftUI** iOS client for Anki, built on Anki's **shared Rust engine**
(`rslib`). The UI is a faithful re-implementation of AnkiDroid's feature set; the
scheduler (FSRS), SQLite collection, sync, search, media, and card rendering are
reused as-is from the engine — never reimplemented.

`main` is the full app: a faithful AnkiDroid-parity client **plus** the MCAT
"Speedrun" layer (Memory / Performance / Readiness scores, coverage map, Focus
Weak Topics, in-app Library) built on top — all sharing the desktop fork's Rust
engine, including the **points-at-stake** review-queue change (see
[MCAT Speedrun](#mcat-speedrun)).

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

**Device builds:** simulator builds need no team; a **device** build (and the
home-screen widget's App Group) needs a real `DEVELOPMENT_TEAM` in
`AnkiApp/project.yml`. If a machine has no team at all and the widget's App-Group
entitlement blocks the build, comment out the app target's `- target: AnkiWidget`
dependency in `project.yml` (documented there) — the app still builds green.

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

- **AnkiWeb (default):** log in with your AnkiWeb account on the Sync screen.
- **Self-hosted (version-matched):** `deploy/syncserver/` is a Fly.io Dockerfile +
  `fly.toml` pinned to the engine's exact commit (a bleeding-edge engine can
  mismatch AnkiWeb's older server on a full upload). It's configured for
  **scale-to-zero** (sleeps when idle, wakes on sync). In the app, choose a custom
  sync server in **Settings → Sync server** (while logged out).

## MCAT Speedrun

The MCAT layer is built **on top of** the full AnkiDroid-parity app — every screen
is native SwiftUI and every number comes from the shared engine:

- **MCAT Readiness** — three honest scores (Memory / Performance / Readiness), each
  a range; shows **no score** until ≥200 graded reviews AND ≥50% topic coverage
  (the give-up rule), otherwise the abstain read-out.
- **MCAT Coverage** — a map over the 50-topic AAMC outline (a topic counts once it
  has ≥1 card), rolled up per section and overall.
- **Focus Weak Topics** — ranks topics weakest-first and studies them in that order
  via the engine's `GetPointsAtStakeQueue` RPC (the shared **points-at-stake** Rust
  change). Exercised by `AnkiKitTests.testPointsAtStakeQueueOrdersWeakTopicFirst`.
- **MCAT Library** — one-tap import of curated, pre-scheduled decks (Supabase-backed).

The MCAT-specific engine change (points-at-stake review queue) lives in the shared
desktop fork (`../anki-desktop/main`); iOS calls it through
`AnkiKit/Sources/AnkiKit/BackendPointsAtStake.swift`.

## Branches

| Branch | What |
| --- | --- |
| **`main`** | The full app: AnkiDroid-parity client **+** the MCAT Speedrun layer. The trunk to build on. |
| `wednesday-submission` | Frozen checkpoint of the graded Wednesday MCAT submission. |

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
