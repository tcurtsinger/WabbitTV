# Phase 1 Source Setup Evidence

**Status:** PASS — packaged, fixture, and real Strong source setup verified  
**Date:** 2026-08-17  
**Shape:** `docs/shapes/1-source-setup.md`  
**Target:** `lib/src/features/sources/source_setup_screen.dart`

## Verified boundary

- The ordinary Windows application routes no-source Home and Settings to the same Xtream-only Source Ledger. It has a four-field Source details form, obscured/revealable password, Cancel-left and Connect-and-import-right actions, and Source ready counts with Browse Live, Browse Movies, and Browse Series handoffs.
- The Quiet Broadcast composition was inspected at 1265x713 and in a larger restored window: no overflow, form remains focal, and the low dock has exactly three equal Live, Movies, and Series cells with no disclaimer/fourth cell.
- Keyboard traversal and visible focus were checked. Packaged Escape from Server URL initially failed; the screen-scoped handler was corrected, debug/release packages rebuilt, and Escape was verified returning to Home.
- Source import is worker-owned and cancellable. Local SQLite holds pending data until credential write and activation; tests cover cleanup and secret exclusion.

## Automated and packaged verification

- Root format pass — PASS.
- `flutter analyze` — PASS, no issues.
- `flutter test --concurrency=1` — PASS, 53 tests.
- `git diff --check` — PASS.
- Windows debug and release packages — PASS using the process-scoped `TrackFileAccess=false` workaround after approved Windows Developer Mode and VC.ATL setup.
- Independent review — closure PASS after all three P2 findings were fixed.

## Local synthetic coverage

Local HttpServer and SQLite tests, without provider data, cover a generated 50k import with positive main-isolate heartbeat, category-to-item linkage, persistence/reopen, absence of username/password/server URL/token values from SQLite, credential write ordering and cleanup, and bounded/forced cancellation of a stalled response.

## Real Strong production evidence and privacy

On 2026-08-17, the ordinary maintainer-local production flow started from Wabbit's no-source state, successfully imported Strong, and persisted the source. Sanitized totals were **56,712 Live**, **176,792 Movies**, and **47,253 Series**. After the app closed and reopened, the persisted catalog was immediately available without credential re-entry. The existing SQLite and captured-log coverage remains the evidence that credentials and credential-bearing URLs do not appear in SQLite or ordinary logs; no username, password, endpoint, provider response, title, identifier, or URL was recorded for this live run.

## Result

The Source Setup implementation matches its confirmed Shape in packaged UI, fixture-backed behavior, and the real Strong source-add/restart acceptance path. Its Phase 1 source-setup gate is closed.
