# Phase 2 Catalog Scope and Local Search render evidence

## Evidence boundary

These PNGs are deterministic, synthetic, network-free Flutter widget renders of the production `BasicBrowseScreen` and `LocalSearchScreen`. The harness supplies credential-free in-memory scope, catalog, and search ports. All artwork locators are `null`, so rendering cannot fetch provider artwork.

This evidence confirms the implemented content-plane composition at the recorded sizes. It is **not** evidence of a real provider import or refresh, packaged Windows runtime behavior, playback, the native title bar, or the full app shell and rail. Real Strong-account measurements remain a separate Phase 2 gate.

All source names, counts, titles, IDs, and playback references shown here are synthetic fixtures.

## Captures

| File | Size | State shown |
| --- | ---: | --- |
| `catalog-all-sources-1265x713.png` | 1265 x 713 | Full-width unified Live ledger with source labels and focused first row |
| `catalog-named-source-1265x713.png` | 1265 x 713 | Named-source Live catalog with provider categories restored |
| `search-mixed-results-1265x713.png` | 1265 x 713 | One mixed Live, Movie, and Series local-result ledger across two sources |
| `search-tv-keyboard-1265x713.png` | 1265 x 713 | Modal TV keyboard with exact shaped key set and focused `A` key |
| `search-constrained-600x713.png` | 600 x 713 | Narrow Windows Search adaptation with the mixed ledger intact |

## Verification

- Render harness: `build/verification/catalog_search_render_test.dart`
- Command: `flutter test --update-goldens build/verification/catalog_search_render_test.dart`
- Result: 5/5 render cases passed.
- Visual inspection: all five final PNGs were inspected after one correction pass. No overflow, clipping, accidental provider call, or hierarchy-breaking defect was visible at these sizes.
- The initial widget-test render exposed placeholder squares for Material icons. The harness now explicitly loads Windows Segoe UI and Flutter's Material Icons font; the final PNGs contain the intended glyphs. Flutter-test rasterization can still differ subtly from the packaged Windows renderer.
- The successful render process exited normally. No Flutter or Dart process was left running by this capture task.

## Implementation checkpoint

- Catalog Scope and Local Search implementation is complete, including shared locally persisted scope, bounded local-only mixed search, and exact-source Xtream/M3U playback handoff with required M3U headers.
- `dart format --output=none --set-exit-if-changed lib test`: PASS, no changed formatting.
- `flutter analyze`: PASS, no issues.
- `flutter test --concurrency=1`: PASS, 228/228.
- `flutter build windows --debug`: PASS; output `build/windows/x64/runner/Debug/wabbit_tv.exe`.
- Independent Impeccable critique and the bounded polish pass: PASS.
- Generic Flutter source audit: three initial P1 browse races were fixed; final closure reports no remaining P1/P2 findings.

## Pending Phase 2 runtime gate

The corrected packaged Windows build now passes the real Strong refresh and browse/navigation portion: the existing last-good catalog recovered without reimport, refresh completed in about 20 seconds, and the final source state remained good. Phase 2 is still in progress only for a real Strong Search responsiveness pass: record approximate result latency for a known-title query, scroll the mixed ledger, and confirm activation reaches the appropriate media flow. Neither the synthetic renders nor a successful Windows build substitutes for that remaining interaction evidence.
