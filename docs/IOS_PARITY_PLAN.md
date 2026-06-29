# iOS Client - Parity Build Plan (spec + roadmap)

Status: living document. Scope decided 2026-06-29: build a general-purpose
SwiftUI Anki client toward AnkiDroid parity, **parity-first** (MCAT/Rust-change
features deferred to a later phase). Honest expectation: this is an incremental
march, not a one-session "finished clone."

## Architecture (source of truth)
```
rslib (Rust)  ->  AnkiCore.xcframework        [DONE]  scheduler/FSRS, SQLite, sync, rendering
   | C-FFI + protobuf
AnkiKit (Swift)  ->  Backend wrapper + protos  [DONE]  typed RPCs (open, queue, render, answer, ...)
   |
AnkiApp (SwiftUI)  ->  reimplemented UI:
   DesignSystem | Decks/Study | Reviewer | NoteEditor | Browser | Sync | Settings
MCATKit (separate module, depends on AnkiKit)  ->  exam config + 3 scores + coverage   [DEFERRED]
```
- Reused as-is (never reimplemented): scheduling, DB, search, sync, card rendering (all `rslib`).
- Reimplemented in SwiftUI: every screen. Reference behavior = AnkiDroid (Kotlin);
  complex screens (deck options, stats) may embed the desktop Svelte pages in `WKWebView`.
- Backend dispatch: one entry point `run(service, method, protobufBytes)`; indices from
  `anki-desktop/main/out/pylib/anki/_backend_generated.py`.

## Design principles (Emil, adapted to SwiftUI + the card WebView)
- 44pt minimum tap targets; touch-first.
- No layout shift on dynamic content (tabular figures for counts/timers).
- `prefers-reduced-motion` honored; speed over delight for high-frequency actions (the reviewer).
- Accessibility: labels on icon buttons, Dynamic Type, sensible focus order.
- Card WebView CSS: respect notetype CSS, dark mode (`color-scheme`), no zoom on tap.

## Execution model
- Sequential implementer subagents on one feature branch (`feat/ios-client`); each task:
  implement (TDD where practical) -> commit -> spec-compliance review -> code-quality review -> merge.
- Controller (me) provides each subagent full task text + context; subagents do not inherit chat history.

## Task roadmap (each item = one subagent task)
### Phase 0 - Foundation
- T0.1 DesignSystem module: color/spacing/type tokens, Button/Card/Row styles, reduced-motion helpers.

### Phase 1 - Core client
- T1.1 Home/Deck list: per-deck due counts, tap-to-study, sync affordance (replaces the prototype ContentView).
- T1.2 Reviewer polish: notetype CSS injection, media via WKURLSchemeHandler, audio, tap/swipe gestures, undo, answer-button interval previews, timer.
- T1.3 Sync: AnkiWeb login + full sync + media sync + progress/error states.
- T1.4 Settings: account, core preferences subset.

### Phase 2 - Content management
- T2.1 Note add/edit: field editor, notetype + deck pickers, tags.
- T2.2 Card Browser: search, results list, card detail, actions (suspend/flag/delete).
- T2.3 Deck management: create/rename/delete; deck options via embedded desktop Svelte page.

### Phase 3 - Parity extras
- T3.1 Statistics: embed desktop graphs page (WKWebView).
- T3.2 Import/export `.apkg` / `.colpkg`.
- T3.3 Card info, change-notetype, filtered decks.

### Deferred (post-parity, graded items)
- MCATKit: exam config, three scores (memory/performance/readiness), coverage map, give-up rule.
- Required Rust engine change in `rslib` (points-at-stake queue / mastery query) + tests.

## Done so far
- Engine bridge (AnkiCore + AnkiKit), host smoke test, iOS app running a basic review loop on the simulator.
