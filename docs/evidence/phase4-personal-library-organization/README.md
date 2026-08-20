# Phase 4 personal library organization render evidence

## Evidence boundary

These PNGs are deterministic, synthetic, credential-free Flutter widget renders of the current production `MyLibraryScreen`, `LibraryOrganizerPane`, `LibraryGroupManagerPane`, and `HomeScreen` widgets. The ignored harness at `build/verification/phase4_organization_render_test.dart` supplies bounded in-memory organization, library, Home, and artwork ports.

The illustrated titles, source names, counts, IDs, memberships, pin order, playback references, and geometric artwork are fixtures. Artwork bytes are decoded from a constant inside the harness. The captures make no provider or network request and contain no provider URL or credential.

This render evidence confirms the implemented composition at the recorded sizes. It is **not itself** packaged Windows runtime proof, real-provider proof, refresh/restart persistence proof, source-mutation proof, playback proof, or full-shell/native-title-bar proof. The separate packaged Strong acceptance gate is recorded below.

## Captures

| File | Size | State shown |
| --- | ---: | --- |
| `01-my-library-organized-1265x713.png` | 1265 x 713 | My Library directory and mixed ledger with quiet Create group, Manage Favorites, and per-item organizer affordances |
| `02-organizer-drawer-1265x713.png` | 1265 x 713 | The approved 360 px Direct Organizer Drawer beside its originating ledger, with Favorite and multiple checked custom groups |
| `03-group-item-order-1265x713.png` | 1265 x 713 | The production 460 px group-management pane with pin/directory/Home controls and responsive manual item-order actions |
| `04-pinned-home-shelves-1265x713.png` | 1265 x 713 | Pinned Favorites followed by a pinned mixed custom group in explicit local Home order |
| `05-delete-confirmation-1265x713.png` | 1265 x 713 | Group deletion confirmation with Cancel focused and truthful retention copy over the prior library view |
| `06-organizer-constrained-600x713.png` | 600 x 713 | The organizer adapted to the full content plane rather than squeezing a third column |

## Verification

- Harness: `build/verification/phase4_organization_render_test.dart` (ignored build-only evidence code).
- Command: `flutter test build\verification\phase4_organization_render_test.dart --concurrency=1 --update-goldens --no-pub`
- Final result: **PASS, 6/6 render cases**.
- Targeted correction recapture: `flutter test build\verification\phase4_organization_render_test.dart --concurrency=1 --plain-name "custom group item-order" --update-goldens --no-pub` — **PASS, 1/1**.
- Repository validation after the final correction audit: format stable; `flutter analyze --no-pub` **PASS**; `flutter test --concurrency=1 --no-pub` **PASS, 400/400**.
- Windows builds: Debug and Release **PASS** at `build\windows\x64\runner\Debug\wabbit_tv.exe` and `build\windows\x64\runner\Release\wabbit_tv.exe`.
- Independent native-source closure review: **PASS**, with no remaining P1/P2 findings.
- Capture path: Flutter's golden matcher; the harness does not call `RenderRepaintBoundary.toImage` or `toByteData` directly.
- Theme and fonts: the harness reproduces Wabbit's production Material 3 dark color scheme and loads Windows Segoe UI plus Flutter Material Icons explicitly.
- Visual inspection: all final surfaces were inspected. No overflow, clipping, placeholder glyph, raw locator, hierarchy break, or focus-geometry shift remains at the recorded sizes.
- Process hygiene: the final render process exited normally; no Flutter, Dart, or `dartaotruntime` process was left running by this task.

## Bounded correction record

The first pinned-Home evidence run exposed that artwork decode cache sizing attempted to round infinite layout extents. Production `SourceArtwork` now omits decode cache dimensions when an extent is non-finite; the final pinned-shelf capture loads fixture artwork without an exception.

The first actual 460 px group-management capture then exposed a clipped `Remove from group` action. The item-order actions now reflow into two equal move controls plus a full-width remove control below 600 px, while retaining one row at wider widths. The corrected 460 px state received one targeted recapture and inspection before the final 6/6 run.

## What the evidence establishes

- My Library keeps the direct directory-and-ledger hierarchy while exposing group creation and explicit management as secondary actions.
- One item organizer can show Favorite plus several custom-group choices without turning each media row into a toolbar.
- Group management keeps remote-safe explicit movement and destructive confirmation inside the established in-shell continuation.
- Favorites and custom groups render as bounded Home shelves in the explicit persisted shelf order.
- The constrained organizer preserves the same task and hierarchy in a full-plane continuation.

## Packaged Strong acceptance

**PASS — user-supplied, 2026-08-18.** The user ran the packaged Release checklist and confirmed that one Save updated Favorite plus two groups, memberships appeared in all selected locations, pinned Favorites/groups followed the chosen Home order before Recently Watched, unpin and membership removal were non-destructive, refresh/restart preserved organization, and mouse/keyboard/remote return behavior worked. The user reported `Pass, confirmed`. No provider title, locator, credential, screenshot, or timing was recorded, and no packaged result is inferred from the synthetic renders themselves.
