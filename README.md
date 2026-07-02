# MCAT Speedrun — iPhone companion

The iOS companion for **MCAT Speedrun**, a fork of Anki that shares Anki's Rust
engine (`rslib`) on-device via a C-FFI `xcframework`. Exam: **MCAT** (scored 472–528).

> **Grade this repo off the `wednesday-submission` branch.** It contains the MCAT
> features (Memory / Performance / Readiness scores, coverage map, Focus Weak
> Topics, in-app Library, self-hosted sync, rustls on-device TLS). The `main`
> branch took a different, non-MCAT direction and does not carry the
> points-at-stake engine change.

Shares the engine with the desktop app → https://github.com/kimkhoi2202/anki-mcat

## What it does
- Real review sessions on the **same deck as desktop**, on the shared Rust engine.
- Three honest scores (**Memory / Performance / Readiness**), each a range; shows
  **no score** until ≥200 graded reviews AND ≥50% topic coverage (the give-up rule).
- **Coverage map** over the 50-topic AAMC outline, and **Focus Weak Topics** via
  the `GetPointsAtStakeQueue` engine RPC.
- **Two-way sync** with the desktop through a self-hosted sync server.

## Prerequisites (macOS, Apple Silicon)
- **Xcode 16+**
- **Rust** (`rustup`) with iOS targets:
  ```bash
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
  ```
- **XcodeGen**: `brew install xcodegen`

## Build & run
The iOS engine is compiled from the **desktop fork's `rslib`**, so the two repos
must sit **side by side** (the build reads `../../anki-desktop/main/rslib`):

```
mcat-speedrun/
  anki-desktop/main/   # clone of anki-mcat
  anki-ios/            # this repo
```

1. **Clone both, side by side:**
   ```bash
   mkdir mcat-speedrun && cd mcat-speedrun
   git clone -b main https://github.com/kimkhoi2202/anki-mcat.git anki-desktop/main
   git clone -b wednesday-submission https://github.com/kimkhoi2202/anki-mcat-ios.git anki-ios
   ```
2. **Build the shared engine into an xcframework** (gitignored, so this step is required):
   ```bash
   cd anki-ios/AnkiCore && ./build-xcframework.sh
   ```
3. **Generate the Xcode project:**
   ```bash
   cd ../AnkiApp && xcodegen generate
   ```
4. **Open & run** `AnkiApp/AnkiSpeedrun.xcodeproj` in Xcode:
   - **Simulator (easiest — no signing):** pick an iPhone simulator → Run.
   - **Real device:** set your own **Development Team** under Signing & Capabilities → Run.

## Get decks in the app (no account needed)
- Open **MCAT → Library** (in-app) → **Download & Import** e.g. *"MCAT Speedrun —
  Full Deck (all 50 topics)"*. It scores at 100% coverage on import.
- Or, on the **Readiness** screen, tap **"Load a scored demo deck (simulated history)"**.

## Sync (optional)
Sign in on the **Sync** screen with your self-hosted server URL, username, and
password to pull the same collection reviewed on desktop.

## License
**AGPL-3.0-or-later.** Built on **Anki** by Ankitects Pty Ltd
(https://apps.ankiweb.net); some components are BSD-3-Clause. Credit to the Anki
and AnkiDroid projects.
