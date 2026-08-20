# Phase 6 Xtream Live Guide and startup render evidence

**Evidence status:** Complete. Phase 6 implementation, final automation, final UI review, the seven-state synthetic Flutter render checkpoint, Windows Debug/Release packages, corrected packaged Xtream Guide behavior, representative M3U URL/local-file readiness, and final daily-driver user acceptance passed. Phase 6 and Windows V1 are complete; UI/UX polish continues as ongoing unnumbered maintenance, not Phase 7.

## Evidence boundary

These PNGs are deterministic, credential-free Flutter widget renders of the current production `GuideScreen`, `BasicBrowseScreen`, `SourceManagementScreen`/`GeneralSettingsSection`, and `WabbitShell` startup fallback. The ignored harness at `build/verification/phase6_guide_startup_render_test.dart` supplies bounded in-memory Guide, EPG, catalog, source-management, Home, startup-preference, admission, and playback ports.

All source names, category names, channel names, schedules, counts, catalog identities, and playback references are synthetic fixtures. The playback resolver uses the non-network `fixture://` scheme and is not invoked by these states. The capture performs no provider request, network request, real catalog/database read, or credential-store access, and it stores no provider URL or credential.

This evidence confirms the implemented Flutter composition at the recorded sizes. It is **not** packaged Windows runtime proof, provider timezone proof, stream compatibility proof, performance proof, or proof that broad guide coverage exists for a specific provider.

## User-supplied packaged Guide observation

The user exercised the packaged Windows Guide across multiple categories, supplied a screenshot, and reported that schedules were not visible while the preparing message repeated during scrolling. A subsequent read-only inspection of the local catalog database used only sanitized aggregates: it made no provider or network request, read no credential store, performed no database write, and retained no provider, source, channel, program, URL, username, or credential value.

At that packaged checkpoint, **149 channel requests had settled: 148 empty, 1 available, 0 error, 0 refreshing, and 4 programs persisted**. No active or abandoned refresh lease remained. This proves that acquisition and parsing succeeded at least once and that the sampled provider coverage was sparse; it does not establish why each successful empty response contained no usable program or predict coverage for unqueried channels.

The repeated preparing presentation was therefore not evidence of a stuck provider request. The corrected product limits aggregate status to the mounted/near-visible rows, retains bounded settled window state across reverse scrolling, and explicitly cancels superseded acquisition before a new source or category scope is shown.

The user then exercised the corrected packaged Guide and supplied the exact result: `Ok pass`. This confirms the corrected Preparing/reverse-scroll/category behavior only. No title, timing, screenshot, resource, credential, or additional provider coverage was supplied for that rerun.

## Packaged local M3U picker correction

The user reported that selecting `Choose M3U file` froze the packaged app in a Windows `Not Responding` state and required Alt+F4. Source tracing confirmed that Wabbit performs no playlist read before selection: the runtime adapter asks the owned Windows dialog for a path, the form stores the returned path, and local-file acquisition begins only after `Connect`. The contents of the test playlist therefore could not cause the pre-selection freeze inside Wabbit.

The direct correction is UI-only: one in-flight picker request, an `endOfFrame` barrier so the pending state paints before entering the synchronous modal boundary, disabled conflicting actions while pending, redacted retryable failure truth, and exact focus restoration after cancel, failure, or selection. The file-selector adapter, bundled plugin, Windows runner, M3U parser, and import path were not changed. Independent review reports **PASS**.

In the rebuilt production Release, the lead observed the pending state paint and the owned Windows file dialog appear. Escape canceled the dialog and returned immediately to a responsive form with exact `Choose M3U file` focus. Reopening the dialog, selecting the Downloads test playlist, and confirming populated the existing field. The app was then closed without pressing `Connect`, importing, or adding a source. This packaged checkpoint proves only the picker lifecycle; the local-file source/import/browse/playback flow was accepted separately afterward.

After being asked to retry the corrected local M3U file flow in the new packaged Release, the user replied exactly `Pass`. This user-supplied result accepts the picker defect correction and corrected packaged chooser flow only. It included no steps, timing, screenshot, or import/browse/playback result, and none is inferred from the one-word acceptance.

## Final M3U and Windows V1 acceptance

The representative M3U URL was previously user-reported to have worked great. No URL, timing, screenshot, title, resource measurement, provider coverage, or credential detail is added or inferred from that statement.

For the corrected local-file path, the required full flow was stated exactly as `Connect → import → browse → playback`. The user then replied exactly `Yes, full flow passed`. This supplies the previously missing local-file readiness evidence and closes the final daily-driver user gate. Phase 6 and Windows V1 are complete. It does not add timings, screenshots, titles, resource measurements, provider-wide coverage, credentials, or any M3U guide claim.

## Captures

| File | Size | State shown |
| --- | ---: | --- |
| `01-guide-matrix-1265x713.png` | 1265 x 713 | Classic channel-by-time Guide matrix with one synthetic Xtream source, `All Live`, six exact channels, current focus, and immediate schedule |
| `02-guide-matrix-high-text-600x713.png` | 600 x 713 | The same matrix grammar at constrained Windows width and 2x text scale, retaining the fixed channel plane and horizontally scrollable time plane |
| `03-live-now-next-1265x713.png` | 1265 x 713 | Existing compact Live directory rows with quiet exact cached Now/Next metadata |
| `04-guide-unsupported-1265x713.png` | 1265 x 713 | Truthful short-guide unsupported state while every visible channel remains tunable |
| `05-guide-stale-last-good-1265x713.png` | 1265 x 713 | Failed refresh with saved schedule retained, concise failure truth, and bounded Retry |
| `06-settings-general-startup-1265x713.png` | 1265 x 713 | App-level General startup selector with Home, Previous screen, and Last channel inside Settings |
| `07-last-channel-unavailable-home-1265x713.png` | 1265 x 713 | Exact Last-channel target unavailable, safe Home fallback, and one quiet nonblocking notice |

## Verification

- Harness: `build/verification/phase6_guide_startup_render_test.dart` (ignored build-only evidence code).
- Full capture command: `flutter test build\verification\phase6_guide_startup_render_test.dart --concurrency=1 --update-goldens --no-pub`.
- Missing-state targeted capture after a fixture assertion correction: `flutter test build\verification\phase6_guide_startup_render_test.dart --concurrency=1 --update-goldens --no-pub --plain-name "renders quiet Live row Now and Next metadata"` — **PASS, 1/1**.
- Determinism command: `flutter test build\verification\phase6_guide_startup_render_test.dart --concurrency=1 --no-pub` — **PASS, 7/7**.
- Final corrected-tree checkpoint: formatting checked **100 files with 0 changes**; analysis reports no issues; the full serial suite passes **581/581 in 80.125 seconds**; diff-check passes; and independent closure plus picker correction review report **PASS**. The final unchanged-render command passed **7/7**. SHA-256 and decoded-dimension comparison matched every generated golden to its tracked PNG, so no capture was replaced, recopied, or reinspected.
- Windows package checkpoint: **PASS** with the process-scoped `$env:TrackFileAccess='false'` workstation workaround. The cold/default Debug build completed in 40.7 seconds (**42.132 seconds wall time**) at `build/windows/x64/runner/Debug/wabbit_tv.exe` (1,140,736 bytes; 2026-08-19 14:22:29.022 -05:00; SHA-256 `77C8EF3FA4884EC9470828BC0D8347C12292D600818D73C1ADE51F1054AFF341`) and the normal/default Release build completed in 46.9 seconds (**48.068 seconds wall time**) at `build/windows/x64/runner/Release/wabbit_tv.exe` (183,296 bytes; 2026-08-19 14:23:51.199 -05:00; SHA-256 `D112C13F8FF39927C50A86A0E4CE96F890E99DF1811E120164A81A971BEB2B7F`). Both used `FLUTTER_TARGET=lib/main.dart`; decoded defines contained only standard Flutter metadata and no Wabbit fixture/probe define. No Flutter, Dart, Wabbit, MSBuild, or compiler process remained.
- Capture path: Flutter's golden matcher. The harness does not call `RenderRepaintBoundary.toImage` or `toByteData` directly.
- Fonts/icons: Windows Segoe UI and Flutter Material Icons are loaded explicitly by the harness.
- Dimension verification: all seven tracked PNGs were decoded after capture; six are exactly 1265 x 713 and the constrained/high-text capture is exactly 600 x 713.
- Visual inspection: all seven states were inspected together once in a generated ignored contact sheet. No visible overflow, clipped primary action, missing focus boundary, raw locator, credential, broken matrix, lost channel-tuning target, or missing fallback notice was found. The constrained timeline intentionally clips horizontally and remains scrollable rather than changing into cards.
- Post-correction inspection: no PNG hash changed, so there was no changed capture requiring a second visual inspection.
- Correction pass: no product visual correction was requested from this inspection. One harness text assertion was corrected before its missing PNG was captured; the subsequent complete determinism run passed without changing the recorded artifacts.
- Process hygiene: successful Flutter render processes exited normally. No Phase 6 render `flutter_tester` or Dart process remained after verification.
- Post-packaged-correction render checkpoint: the ignored harness was advanced only across the production Guide port's cancellation and manual-retry seams, then the final deterministic no-update run passed **7/7**. SHA-256 and decoded dimensions matched all seven generated PNGs to their recorded artifacts, so no PNG was copied, replaced, or reinspected. The existing seven captures do not synthesize the long-page empty-window scroll sequence from the packaged report; that correction is covered by behavior tests rather than represented as provider proof in a synthetic image.

## What the evidence establishes

- The Guide uses the confirmed classic matrix rather than a card or synopsis surface.
- Reference and constrained/high-text layouts preserve a practical channel tuning plane and time-grid relationship.
- Live browsing can add quiet cached Now/Next truth without replacing the channel title or compact ledger grammar.
- Unsupported acquisition and failed refresh with last-good data remain Guide-local states; channels stay available to tune.
- Startup behavior is controlled from one app-level General Settings entry.
- An unavailable exact Last-channel startup target falls safely to Home and reports that outcome without exposing the saved identity.

The PNG evidence remains synthetic and local. The sanitized packaged aggregate above is separate from the PNGs and establishes only the exact persisted state reported there. The corrected packaged Guide rerun and picker-only packaged exercise confirm only the behaviors stated above. In the lead-observed bounded picker proof, the selected Downloads test playlist was not connected or imported, and the later one-word user `Pass` supplied no additional step-level evidence. The subsequent explicit `Yes, full flow passed` response applies only to the defined `Connect → import → browse → playback` local-file flow, while the representative M3U URL claim remains bounded to the user's report that it worked great. Those separately supplied results close Phase 6 and Windows V1; they do not expand the synthetic captures or imply timings, screenshots, titles, resource measurements, provider-wide coverage, credentials, or M3U guide behavior.
