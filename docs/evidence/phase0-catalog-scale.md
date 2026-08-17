# Phase 0 Synthetic Catalog Scale Evidence

**Status:** Verified PASS  
**Date:** 2026-08-16  
**Target:** `lib/src/spikes/phase0/catalog_scale_probe.dart`

## Boundary

- Generates exactly 50,000 deterministic synthetic Live, Movie, and Series records in code; no provider catalog, credentials, playlist, copyrighted titles, or committed bulk fixture file is used.
- Runs in `Isolate.run` against one temporary file-backed SQLite FTS5 database.
- Uses one transaction and one prepared insert, then performs a deterministic FTS search.
- Closes the database and deletes only its own temporary directory in `finally`.
- Records measurements as a baseline, not as a performance target or reason to add a Rust/native catalog layer.

## Packaged Windows baseline

The debug Windows package compiled with `WABBIT_CATALOG_SCALE_PROBE=true` emitted one sanitized diagnostic line:

| Measurement | Result |
|---|---:|
| Records | 50,000 |
| Live | 16,667 |
| Movies | 16,667 |
| Series | 16,666 |
| Import | 172 ms |
| FTS5 search | 4 ms |
| Deterministic anchor matches | 10 |
| Temporary database | 6,594,560 bytes |
| Main-isolate heartbeat ticks | 2 |

The positive heartbeat while the database work ran in the background isolate confirms the main isolate remained schedulable during this packaged baseline. The raw sanitized line is stored at `build/verification/phase0-catalog-scale-stdout.txt`; stderr was empty. Debug and release Windows packages both built successfully with the diagnostic flag.

## Verification

- `dart format --output=none --set-exit-if-changed lib test` — PASS.
- `flutter analyze` — PASS, no issues.
- `flutter test --concurrency=1` — PASS, 24 tests.
- `git diff --check` — PASS.
- Packaged debug diagnostic — PASS with the measurements above.
- Independent Terra review — PASS with no material P1/P2/P3 findings.

## Result

The direct Dart `sqlite3`/FTS5 approach remains accepted. A generated 50k catalog imported and searched off the UI isolate without a measured reason to introduce Rust, a native catalog service, or optimization machinery in Phase 0.
