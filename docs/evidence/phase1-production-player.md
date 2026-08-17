# Phase 1 Production Player Evidence

**Status:** PASS — source, synthetic packaged player, and real Strong production flow verified  
**Date:** 2026-08-17  
**Shape:** `docs/shapes/3-production-player.md`  
**Targets:** `lib/src/features/playback/player_screen.dart`, `lib/src/features/playback/playback_transport.dart`, `lib/src/app_shell.dart`

## Verified boundary

- A typed Live, Movie, or Episode handoff takes over the Wabbit client area while preserving the underlying browse state and origin focus for return.
- The final Xtream stream URI is assembled just in time from the saved source credential. Provider base paths are preserved, a trailing `player_api.php` is removed, and credentials/final URIs never enter UI diagnostics or ordinary logs.
- One `media_kit` transport exists at a time. Opening, retry, runtime recovery, exit, and widget disposal share a coalesced teardown so a caller cannot return to browse before active cancellation/disposal completes.
- The first usable frame has a 20-second deadline. One quiet retry is available per cycle; terminal recovery remains redacted and offers Retry/Back or Open Settings without raw engine/provider details.
- Live exposes Play/Pause, mute/volume, and fullscreen without a false timeline. Movie and Episode add a truthful timeline and ten-second seeking.
- Chrome starts visible, reveals on input, remains visible while any nested control has focus, and yields to the stage through Down. Mouse and keyboard/remote-style activation share the same actions.

## Impeccable verification

- Confirmed Shape and approved composition: **A — Broadcast Deck**.
- Formal critique used two isolated reviewers: `/root/phase1_player_critique_a` and `/root/phase1_player_critique_b`. First-run score: **32/40**. The native-inapplicable HTML/CSS detector returned **0 findings**.
- The three accepted critique findings were closed in one bounded polish pass: the wide primary transport cluster is centered independently of right-side utilities, recovery uses deterministic primary focus plus the same 2 px amber grammar, and starting/buffering status is an edge-free bounded mark rather than a floating card.
- Questions were skipped because the confirmed Shape and approved composition made those corrections deterministic. No ignore file, browser overlay, live server, or temporary web artifact was used; browser-only tooling is not applicable to native Flutter.
- Generic Flutter native-source audit: **PASS, 16/16**, with no material P0/P1/P2/P3. iOS/Android conformance was intentionally not scored.

Critique snapshot: `.impeccable/critique/2026-08-17T15-27-27Z__lib-src-features-playback-player-screen-dart.md`.

## Automated and package verification

- `dart format --output=none --set-exit-if-changed lib test` — PASS.
- `flutter analyze` — PASS, no issues.
- `flutter test test/player_screen_test.dart` — PASS, 15 tests.
- `flutter test --concurrency=1` — PASS, 98 tests.
- `git diff --check` — PASS. The repository remains the intentional all-untracked pre-commit baseline.
- Final Windows production debug build — PASS with process-scoped `TrackFileAccess=false`.
- Final Windows production release build — PASS with the same workstation-only invocation workaround.
- Separate synthetic, network-free production-player fixture debug build — PASS.

## Packaged Windows interaction

The separate fixture uses the real player surface, real window fullscreen port, synthetic local state, and an in-memory transport that ignores its URI. It made no provider request and used no real credential.

- **1266 x 713 native window:** stage and contain plane rendered without overflow; mouse movement revealed the top identity band and bottom deck; clicking Pause changed the semantic action to Play and showed the 2 px amber focus edge.
- **Keyboard/remote-style flow:** Right moved focus from Play to Forward 10 seconds; Down returned focus to the synthetic video stage and hid the chrome.
- **Large 2560 x 1440 window:** the timeline remained full width while the primary VOD transport cluster stayed centered and utilities remained right-aligned.
- **Constrained 501 x 713 window:** the compact deck retained every control, readable elapsed/duration text, and visible focus without overflow.
- **Fullscreen:** the first packaged pass found that `window_manager` left the native title bar visible when fullscreen began from a maximized window. Wabbit now explicitly hides the Windows title bar before entering fullscreen and restores it after exit. The corrected packaged rerun showed a borderless client; Escape restored the dark native title bar without leaving playback, and the next Escape exited the fixture.

The Windows inspection was bounded and interactive. No repository screenshot file is claimed.

## Real Strong production-flow evidence

On 2026-08-17, the ordinary packaged production flow started from Wabbit's no-source state and imported the maintainer-local Strong source successfully. Sanitized imported totals were **56,712 Live**, **176,792 Movies**, and **47,253 Series**. Live, Movies, and Series each rendered their catalog and categories.

- One real Live item rendered visible moving video.
- One real Movie and one real Episode each rendered visible video with truthful VOD controls and timeline.
- No recovery or error state surfaced during this successful sequential run.
- Escape returned Live to browse and returned the Movie first to its focused detail Play action and then to browse. The automated continuation suite remains the evidence for the equivalent Episode return path.
- After closing and reopening, the ordinary product retained the source and immediately exposed the persisted catalog without credential re-entry.
- The final packaged rerun correctly identified the real persisted library as **All sources** with real-library no-personalization copy; no local-fixture wording remained.

## Closure boundary

- The two-attempt lifecycle, late runtime-error path, and sanitized failure/recovery boundary remain covered by the source and widget suite; no failure was fabricated against the maintainer's provider during the successful production run.
- The packaged fixture continues to be scoped to visual/control/window verification with synthetic state; the production run above separately proves real rendering and ordinary browse-and-play return.
- With the prior synthetic failure/persistence coverage, the real import, browse, playback, and restart results close the Phase 1 player gate.
