# Phase 3 browsing experience render evidence

## Evidence boundary

These PNGs are deterministic, synthetic, credential-free Flutter widget renders of the current production `HomeScreen`, `MyLibraryScreen`, `BasicBrowseScreen`, `LocalSearchScreen`, `MovieContinuation`, and `SeriesContinuation` widgets. The ignored harness at `build/verification/phase3_browsing_render_test.dart` supplies only bounded in-memory data and artwork ports.

The illustrated titles, source names, counts, IDs, playback references, watch times, and geometric artwork are fixtures. Artwork bytes are decoded from constants inside the harness; the capture makes no provider or network request and contains no provider URL or credential.

This evidence confirms the implemented content-plane composition at the recorded sizes. It is **not** packaged Windows runtime proof, real-provider proof, import/refresh proof, playback proof, native-title-bar proof, or full-shell/rail proof. The separate packaged Strong acceptance result is recorded below without relabeling these synthetic captures.

## Captures

| File | Size | State shown |
| --- | ---: | --- |
| `01-home-no-source-1265x713.png` | 1265 x 713 | Runtime Home with no configured source and one focused Add source action |
| `02-home-no-history-1265x713.png` | 1265 x 713 | Runtime Home with a source but no local watch history; Live, Movies, and Series direct entries remain available |
| `03-home-recently-watched-1265x713.png` | 1265 x 713 | Populated local Recently Watched shelf with focused first card and synthetic artwork |
| `04-my-library-populated-1265x713.png` | 1265 x 713 | Approved wide directory-and-ledger composition with Favorites and custom groups |
| `05-my-library-constrained-600x713.png` | 600 x 713 | Narrow Windows adaptation with the directory collapsed into a bounded launcher above the mixed ledger |
| `06-browse-fixed-artwork-1265x713.png` | 1265 x 713 | All-sources Live directory with fixed 50 x 36 artwork slots and source provenance |
| `07-search-fixed-artwork-1265x713.png` | 1265 x 713 | Local mixed search ledger with fixed 50 x 36 artwork slots across Live, Movie, and Series results |
| `08-movie-continuation-1265x713.png` | 1265 x 713 | Minimal Movie continuation with fixed 120 x 84 artwork, an always-visible Back action, and one compact primary Play action |
| `09-series-continuation-1265x713.png` | 1265 x 713 | Minimal Series continuation with fixed 120 x 84 artwork, an always-visible Back action, seasons, and a dense episode ledger |

## Verification

- Harness: `build/verification/phase3_browsing_render_test.dart` (ignored build-only evidence code).
- Command: `flutter test build\verification\phase3_browsing_render_test.dart --concurrency=1 --update-goldens --no-pub`
- Result: **PASS, 9/9 render cases**.
- Targeted continuation recapture: `flutter test build\verification\phase3_browsing_render_test.dart --concurrency=1 --plain-name continuation --update-goldens --no-pub` — **PASS, 2/2 render cases**.
- Capture path: Flutter's golden matcher; the harness does not call `RenderRepaintBoundary.toImage` or `toByteData` directly.
- Fonts: Windows Segoe UI and Flutter Material Icons are loaded explicitly by the harness.
- Visual inspection: all nine final PNGs were inspected together and the Browse, Search, Movie, and Series artwork surfaces were inspected again at a larger scale. No overflow, clipping, placeholder glyph, focus-geometry shift, accidental raw locator, or hierarchy-breaking defect was visible at the recorded sizes.
- The updated Movie and Series continuation PNGs were each inspected once after the compact always-visible Back and compact Play changes; both preserve the bounded content frame without clipping or overflow.
- Bounded correction pass: the first artwork capture occurred before the test rasterizer completed in-memory image decoding. The harness now waits for Flutter's image decode, asserts that `Image` widgets are present, and then captures; the final PNGs show the intended synthetic artwork inside unchanged fixed geometry.
- Process hygiene: the successful render process exited normally; no Flutter, Dart, or `dartaotruntime` process was left running by this task.

## What the evidence establishes

- Home truthfully distinguishes no source, no history, and local watch-history states.
- My Library preserves the approved directory-not-storefront hierarchy at wide and constrained Windows widths.
- Browse and Search keep titles primary while artwork remains a small, fixed scanning aid.
- Movie and Series activation land on restrained continuations rather than promotional detail pages.
- The evidence remains synthetic and local; it does not substitute for packaged Strong-provider acceptance.

## Packaged Strong acceptance

The first Release exercise exposed that uncached thumbnails loaded only after the row received focus. The correction lets the mounted virtual-row window begin artwork after a short dwell without click/focus, while keeping the shared loader limited to two requests and cancelling rows that leave the mounted window. `flutter analyze` passed, the full serial suite passed **360/360**, and the corrected Windows Release build completed at `build/windows/x64/runner/Release/wabbit_tv.exe` (2026-08-18 16:05 local). The user reran the packaged build and reported `Ok way better. Pass`.

This is user-supplied runtime acceptance. No provider title, locator, credential, screenshot, or request log is retained in this evidence folder.
