---
version: 1
slug: "lib-src-features-search-local-search-screen-dart"
primary_target: "lib/src/features/search/local_search_screen.dart"
related_targets: ["lib/src/app_shell.dart","lib/src/features/browse/basic_browse_screen.dart","lib/src/features/sources/source_catalog_database.dart"]
---

# Local Search

## Scope and mode

- **Mode:** Operate
- **Scope:** Phase 2 local-library Search with the shared All Sources / named-source scope, one mixed Live/Movie/Series result ledger, and the confirmed minimal TV keyboard overlay.
- **Boundary:** No provider search request, recommendation, recent/trending history, filter bar, grouped type sections, voice entry, metadata enrichment, favorites, custom groups, or new playback behavior.

## Direction and approved compositions

- Inherit Quiet Broadcast: graphite planes, warm-white hierarchy, quiet metadata, compact 6 px controls, fixed 2 px amber focus, and synthetic/provider artwork confined to small row thumbnails.
- Mixed ledger: `.impeccable/mocks/quiet-broadcast-local-search-a-mixed-ledger.png`.
- Remote keyboard: `.impeccable/mocks/quiet-broadcast-local-search-a-tv-keyboard.png`.
- One clear field and one virtualized mixed ledger are the focal task. All Sources rows expose source provenance; media type is always explicit.

## Interaction contract

- Physical keyboard input uses the text field directly and runs only bounded local search. Enter/Select from remote navigation opens the A–Z/0–9 keyboard with Space, Back, Clear, and Done.
- Empty query remains instructional and never dumps the catalog. Clear keeps the field available. Done closes the overlay and moves to the first viable result when one exists.
- Escape/browser Back dismisses the keyboard without clearing the query, then follows the shell return contract. Scope and practical query/list focus survive session navigation.
- Live, Movie, and Series activation reuse the established playback and minimal-continuation contracts.

## Constraints

- Off-UI-isolate bounded queries and visible-row virtualization are mandatory at Strong scale. Search never contacts a provider and never exposes FTS syntax.
- Mouse, keyboard, and remote parity; no dead directional cells; changing status/result counts use accessible announcements without stealing focus.
- The user confirmed result structure **2A**, remote input **3A**, and both first viewports on 2026-08-17.

## Implementation checkpoint

- The confirmed surface is implemented as bounded local-only mixed search with the shared persistent scope, physical-keyboard input, exact shaped TV-keyboard key set, session restoration, and existing Live/Movie/Series activation paths.
- Exact-source playback preserves the chosen Xtream variant or M3U locator and required M3U headers without provider search calls.
- Focused tests, the full serial 223-test suite, static analysis, five-case synthetic actual-Flutter render evidence, independent critique/polish, final source-audit closure, and the Windows debug build pass.
- Runtime verification remains pending for packaged Windows mouse/keyboard/remote interaction and real Strong search/activation measurements. The synthetic captures do not prove provider behavior.
