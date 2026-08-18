# Phase 2 — Library Visibility evidence

**Status:** Verified — user-supplied packaged Release Strong runtime PASS.

The user explicitly confirmed the linked 1265×713 Impeccable viewport before
implementation. Library Visibility uses schema v6 local flags on provider
categories and individual catalog items. Active named Browse, All Sources, and
Search require both the category and item to be included. Refresh retains those
flags; restoring a category never restores individually hidden items.

The four render captures below were taken 2026-08-17 from the real
`LibraryVisibilityScreen` widget using an in-memory `LibraryVisibilityPort`.
They are synthetic, credential-free, and make no provider or network calls.

| Image | Dimensions | State |
| --- | ---: | --- |
| `01-desktop-mixed-1265x713.png` | 1265 x 713 | Desktop directory + selected Live-category ledger; category-level hidden state is visible. |
| `02-hidden-only-recovery-1265x713.png` | 1265 x 713 | Hidden-only recovery: an individually hidden item remains available to restore. |
| `03-uncategorized-1265x713.png` | 1265 x 713 | Uncategorized ledger: no category-wide hide/restore control is offered. |
| `04-constrained-directory-600x713.png` | 600 x 713 | Narrow layout with the in-shell provider-category directory open. |

Generation harness (ignored build artifact):
`build/verification/library_visibility_render_test.dart`

Run:

```powershell
$env:TrackFileAccess = 'false'
& 'C:\Users\txtra\tools\flutter-sdk-3.47.0\flutter\bin\flutter.bat' test build\verification\library_visibility_render_test.dart --concurrency=1 --update-goldens
```

The command produces temporary goldens under `build/verification` and copies
only these four reviewed PNGs into this evidence directory.

## Automated, audit, and package evidence

- `dart format`, `flutter analyze`, and the full serial suite passed: **268
  tests**.
- Independent Impeccable critique and generic Flutter native-source audit:
  **PASS 16/16**.
- Windows Debug package: `build/windows/x64/runner/Debug/wabbit_tv.exe`
  (2026-08-17 22:30:45 local).
- Windows Release package: `build/windows/x64/runner/Release/wabbit_tv.exe`
  (2026-08-17 22:31:49 local).

## Sanitized real-scale local-copy measurement

The provider catalog was copied locally for measurement only. The original
catalog was not touched: SHA-256 prefix before and after was
`7FA99A79013E8399`. No provider names, credentials, item titles, or locators
were recorded.

| Operation | Result |
| --- | --- |
| Schema v5 → v6 migration and roster | 1,629 ms |
| Warm roster | 173 ms |
| Live categories / first page / next page | 32 / 4 / 3 ms |
| Movie categories / first page / next page | 98 / 3 / 2 ms |
| Series categories / first page / next page | 25 / 3 / 2 ms |
| Existing local Search, Spider first / count / next | 14 / 8 / 13 ms (318 total) |
| Existing local Search, Fox first / count / next | 11 / 9 / 11 ms (632 total) |

The category plan used the source-group availability index rather than a
catalog-wide availability scan. Search retained the enforced FTS → library →
member → catalog → source access order.

## Packaged runtime evidence — PASS

On 2026-08-18, the user ran the packaged Release build against Strong, used
Hide all for the active Live scope, restored the desired Live categories,
confirmed Browse/Search propagation, refreshed, and reported `Perfect, pass`.
This is user-supplied runtime evidence. No screenshot, timing, or provider title
was recorded. Individual-item behavior remains supported by the automated and
database evidence above; this entry does not claim a separate packaged item run.
