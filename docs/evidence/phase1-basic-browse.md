# Phase 1 Basic Browse Evidence

**Status:** PASS — source, synthetic fixture, packaged interaction, and real Strong browse verified  
**Date:** 2026-08-17  
**Shape:** `docs/shapes/2-basic-browse.md`  
**Targets:** `lib/src/features/browse/basic_browse_screen.dart`, `lib/src/features/browse/minimal_continuations.dart`

## Verified boundary

- One ready Xtream source drives shared Live, Movies, and Series directories. Each opens at `All <kind>`, exposes real imported categories, and uses bounded cursor pages rather than loading a catalog into UI memory.
- The approved Source Directory List keeps a 228 px Categories pane and dense fixed-height title rows at wide Windows sizes. Below 760 px it replaces the pane with one Categories launcher and a dismissible in-shell overlay.
- Live emits a typed playback handoff. Movie opens only title and Play. Series loads provider detail only when opened, then exposes season and episode navigation; no production player UI, recommendations, synopsis, or enriched detail was added.
- Browse rows never request provider artwork while scrolling. They retain fixed 50 x 36 neutral Quiet Broadcast placeholders and one focus target per row.
- Returning from a continuation or remount restores practical category, loaded pages, scroll position, and item focus. Keyboard-only tests cross virtual-list cache boundaries for title, wide/narrow category, season, and episode navigation and keep the focused target visible.

## Data and responsiveness evidence

- SQLite schema v3 retains a grouped browse index and adds the aligned global All index. `EXPLAIN QUERY PLAN` tests prove both query shapes avoid a temporary order sort.
- A generated 50,000-row catalog is traversed by bounded cursor pages off the main isolate with a positive heartbeat.
- Series responses remain capped at 4 MiB. UTF-8 decode, JSON decode, and season/episode mapping run inside `Isolate.run`; a generated payload over 1 MiB with 16,000 episodes parsed while a 1 ms main-isolate heartbeat advanced.
- Series credentials are read only for the explicit lazy request. Playback handoffs contain source ID, title, provider item ID, and extension only; their diagnostics are redacted.

## Impeccable verification

- Confirmed Shape: Compact Thumbnail Directory hybrid—C's television scanning cue with B's compact density.
- Formal critique: 29/40 before polish. Both P1 items were corrected: no-source Add source is the one amber primary action, and category labels use the 15 px navigation role. The long-season visibility issue was also corrected.
- Detector: PASS with zero findings. Browser overlay/live tooling was correctly skipped for native Flutter.
- Native-source audit was limited by `ORCHESTRATION.md` to generic Flutter checks plus source-backed Windows interaction contracts; iOS/Android conformance was not scored. Initial audit findings—virtual focus visibility, UI-isolate Series parsing, and synthetic placeholder colors—were fixed. Re-audit: **PASS, 16/16**, with no material P0/P1/P2.
- Independent static finish review: PASS after adding the global ordered browse index and removing browse-time image requests.

Critique snapshot: `.impeccable/critique/2026-08-17T06-05-17Z__lib-src-features-browse-basic-browse-screen-dart.md`.

## Automated and package verification

- `dart format --output=none --set-exit-if-changed lib test` — PASS.
- `flutter analyze` — PASS, no issues.
- `flutter test --concurrency=1` — PASS, 98 tests in the final Phase 1 closure run.
- `git diff --check` and scoped whitespace checks — PASS.
- Windows debug fixture package — PASS with `WABBIT_BROWSE_FIXTURE=live` and process-scoped `TrackFileAccess=false`.
- Windows release fixture package — PASS with the same flag/workaround.
- Packaged Windows browse/player interaction at reference, larger/fullscreen, and constrained sizes passed as part of the final Phase 1 closure. No repository screenshot file is claimed.

## Real Strong browse and closure

On 2026-08-17, an ordinary maintainer-local production run imported the Strong source and rendered Live, Movies, and Series catalogs and their categories. Sanitized totals were **56,712 Live**, **176,792 Movies**, and **47,253 Series**. No provider titles, identifiers, URLs, or credentials were recorded. The same run verified real Live, Movie, and Episode playback and the confirmed Escape/focus-return path.

The final packaged rerun showed the persisted real library as **All sources** with real-library no-personalization copy; no local-fixture wording remained. Closing and reopening retained the source and immediately exposed the persisted catalog without credential re-entry.

With the existing synthetic error/persistence coverage and the final real browse-and-play pass, Basic Browse and its Phase 1 acceptance items are closed.
