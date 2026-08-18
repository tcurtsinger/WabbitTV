# Phase 2 Source Management render evidence

These are synthetic, network-free Flutter widget renders of the current `SourceManagementScreen`. They use invented labels and counts only. They are visual-state evidence, not proof of provider connectivity, catalog durability, credential handling, or packaged Windows runtime behavior.

| Render | Size | State |
| --- | ---: | --- |
| [`02-one-enabled-1265x713.png`](02-one-enabled-1265x713.png) | 1265×713 | One enabled Xtream fixture with Strong-scale synthetic counts |

## Capture limitation

The focused Flutter render harness writes its PNG but does not terminate after capture, so the representative-only run was interrupted once nonzero output existed. The full empty, multiple-source, failure, dialog, and constrained-width matrix remains pending. The temporary harness remains under `build/verification/` and is ignored by Git.

## Visual inspection

- The current directory/detail topology, selected-row focus edge, status hierarchy, compact action geometry, and three-count ledger are visible at the required desktop size.
- Strong-scale synthetic totals render correctly, including the six-digit Movies count (`176,792`).
- The square at the directory row's trailing edge remains a widget-test Material Icons font limitation; this synthetic capture is not runtime proof of a missing chevron.

## Real Strong refresh correction — 2026-08-17

The first packaged Windows refresh remained in `Refreshing` and subsequent source/catalog reloads showed unavailable states. Sanitized inspection confirmed that the prior local catalog remained intact; no source credentials, endpoints, item titles, or playlist URLs were recorded.

The defect was in the local refresh path, not the provider data:

- refresh issued one equality delete per item against an unindexed FTS identifier, making a Strong-scale refresh quadratic;
- the long write window allowed transient local database read failures to replace already usable source and catalog views;
- a refresh worker that exited without its normal terminal event could leave the source marked busy until startup recovery.

The bounded correction clears and rebuilds FTS once per source/media stage, applies a bounded SQLite wait and WAL reader/writer behavior, preserves the last local roster/catalog on noninitial reload failure, coalesces overlapping scope reloads, and performs source-scoped recovery for an abnormal refresh-worker exit. It does not add scheduling, background services, or provider-specific machinery.

### Verification

- `flutter analyze`: PASS, no issues.
- `flutter test --concurrency=1`: PASS, 228/228.
- The 50k refresh regression completes off the UI isolate while concurrent roster and library reads remain usable.
- Windows debug build: PASS; output `build/windows/x64/runner/Debug/wabbit_tv.exe`.
- Independent correction audit: PASS, no P0/P1 findings.
- User-run corrected Windows result: the existing last-good Strong catalog recovered without reimport; refresh completed successfully in about 20 seconds; browsing/navigation and the final source state remained good.

This closes the real Strong refresh/browse portion of the Phase 2 runtime gate. It does not by itself prove the remaining real Strong Search responsiveness item recorded in `PLAN.md`.
