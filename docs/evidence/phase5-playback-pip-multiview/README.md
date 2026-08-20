# Phase 5 playback, Corner Signal, and Multi-view render evidence

**Phase status:** Complete — user-supplied packaged Strong/Windows acceptance on 2026-08-19

## Evidence boundary

These PNGs are deterministic, synthetic, credential-free Flutter widget renders of the current production `PlayerScreen`, `WabbitShell`, `PipOverlay`, `PipStopConfirmation`, `MultiviewScreen`, browse selection, and source-management surfaces. The ignored harness at `build/verification/phase5_playback_render_test.dart` supplies bounded in-memory playback managers, transports, admission ports, catalog ports, and source-management ports.

All titles, source names, counts, track labels, variant labels, playback positions, and geometric video frames are fixtures. Resolved targets use the non-network `fixture://` scheme. The capture performs no provider, network, database, or credential access and stores no provider URL or credential.

This evidence confirms the implemented Flutter composition at the recorded sizes. It is **not** packaged Windows runtime proof, real-provider proof, native-decoder proof, stream compatibility proof, actual picture-in-picture window proof, or proof that a provider permits two simultaneous streams. Those runtime boundaries require separate packaged/provider acceptance.

## Captures

| File | Size | State shown |
| --- | ---: | --- |
| `01-tracks-deck-1265x713.png` | 1265 x 713 | Player Tracks deck with synthetic audio and subtitle choices |
| `02-terminal-recovery-no-variants-1265x713.png` | 1265 x 713 | Terminal playback recovery when no exact pre-existing variant is available |
| `03-terminal-recovery-exact-variant-1265x713.png` | 1265 x 713 | Terminal playback recovery with one injected exact pre-existing variant |
| `04-corner-signal-reference-1265x713.png` | 1265 x 713 | Corner Signal reference composition over Home with Return, Move, Mute, and Close controls |
| `05-corner-signal-constrained-600x713.png` | 600 x 713 | Corner Signal and Home at the constrained Windows width |
| `06-settings-stop-confirmation-1265x713.png` | 1265 x 713 | Settings navigation stop-playback confirmation while Corner Signal remains visible |
| `07-second-channel-selection-1265x713.png` | 1265 x 713 | Active playback preserved while selecting a second Live channel |
| `08-multiview-side-by-side-1265x713.png` | 1265 x 713 | Equal two-up side-by-side Multi-view with one audible pane |
| `09-multiview-side-by-side-600x713.png` | 600 x 713 | Equal side-by-side Multi-view at the constrained width and 2x text scale, with the compact shared deck and selected/audible state retained |
| `10-source-limit-block-1265x713.png` | 1265 x 713 | Second-channel admission blocked before a second transport when the source limit is one |
| `11-source-limit-control-1265x713.png` | 1265 x 713 | Local Automatic, 1, and 2 simultaneous-stream controls in source Settings |

## Verification

- Harness: `build/verification/phase5_playback_render_test.dart` (ignored build-only evidence code).
- Capture command: `flutter test build\verification\phase5_playback_render_test.dart --concurrency=1 --update-goldens --no-pub`.
- Determinism command: `flutter test build\verification\phase5_playback_render_test.dart --concurrency=1 --no-pub`.
- Original complete capture and determinism result: **PASS, 11/11 render cases**.
- Targeted constrained correction capture: `flutter test build\verification\phase5_playback_render_test.dart --concurrency=1 --plain-name "constrained side-by-side multiview" --update-goldens --no-pub` — **PASS, 1/1 render case**.
- Targeted constrained determinism check: the same command without `--update-goldens` — **PASS, 1/1 render case**. Unchanged states were not recaptured.
- Capture path: Flutter's golden matcher. The harness does not call `RenderRepaintBoundary.toImage` or `toByteData` directly.
- Fonts: Windows Segoe UI and Flutter Material Icons are loaded explicitly by the harness.
- Visual inspection: the original eleven PNGs were inspected together once, and the corrected constrained Multi-view replacement was inspected once after capture. The final recorded states showed no visible overflow, clipped primary action, placeholder glyph, raw locator, missing focus boundary, broken 16:9 Corner Signal frame, unequal Multi-view split, or loss of the compact shared deck at 600 x 713 and 2x text scale.
- Correction pass: only the constrained Multi-view case was recaptured after the product adopted equal side-by-side tiles at compact widths. No visual-artifact correction was required. The initial baseline single-case harness check was stopped when asynchronous fake-transport teardown stalled; the ignored fixture teardown was made non-blocking, after which successful render runs exited normally.
- Process hygiene: the successful render processes exited normally. No Phase 5 Flutter or Dart test process was left running by this task.

## What the evidence establishes

- Playback exposes a bounded track-selection deck and redacted terminal recovery without inventing provider variants.
- Corner Signal remains a fixed 16:9 composition with its four required controls at reference and constrained widths.
- Settings navigation asks before stopping active playback.
- Second-channel selection preserves the active session, and source-limit admission blocks the second open before transport creation.
- Multi-view keeps equal side-by-side panes at the reference and constrained widths while the 600 x 713, 2x-text composition uses a compact shared deck and keeps exactly one audible session.
- Source Settings exposes the local Automatic, 1, and 2 simultaneous-stream choices without claiming a higher provider allowance.

The PNG evidence remains synthetic and local. The separately recorded user-supplied packaged acceptance below does not convert these captures into provider, decoder, resource, or two-stream-success proof.

## Repository verification checkpoint

- Schema v11 progress persistence, eligible Movie/Episode resume with Start over and near-finished restart, bounded retry/recovery, real available track selection, admission precedence, Corner Signal, stop confirmation, Live second-channel selection, equal side-by-side Multi-view, one-audible-tile transfer, collapse, and source-limit controls are implemented.
- `dart format --output=none --set-exit-if-changed lib test`, `flutter analyze --no-pub`, and `git diff --check` pass.
- The full serial suite passes **469/469**.
- Windows Debug and Release builds pass.
- Independent Impeccable review reports **PASS**. The generic Flutter native-source audit passes **16/16**.
- All eleven synthetic captures were inspected, and the corrected constrained Multi-view capture was inspected after its targeted recapture.

## Packaged measurement attempt

A temporary credential-free Windows Release fixture attempted real `media_kit` playback using a local generated lavfi input. It made no network or provider request. The native input produced no video, so the attempt is recorded as **unsupported** rather than as playback evidence. It does not establish PiP, two-surface playback, CPU, memory, decoder, startup, transition, or stability behavior; the single process sample in the aggregate must not be quoted as a media-playback measurement.

The ignored aggregate is `build/verification/phase5-windows-packaged-measurement.json`. It records zero active sessions after teardown, an exited fixture process, and no lingering measured process. After the attempt, the ordinary production Release was rebuilt successfully, replacing the temporary fixture entry point. This unsupported attempt supplies no target-hardware measurement and is not the basis of the packaged gate acceptance.

## Packaged gate closeout

On 2026-08-19, the user ran the packaged Phase 5 Strong/Windows checklist and reported `Ok pass`. This is user-supplied acceptance; no provider title, timing, CPU or memory value, decoder detail, available-track result, screenshot, or two-stream success was recorded or inferred.

Strong reports a one-stream allowance. Its second-stream request correctly blocks before a second transport is created, and that pre-open block is the real-provider Multi-view admission evidence for this account. Actual two-stream success was not exercised and remains conditionally unavailable without a genuinely permitted source. The user accepted this bounded evidence boundary and the Phase 5 gate is complete. Synthetic/local two-session captures and tests still establish behavior only and must not be presented as provider, network, decoder, permission, or real two-stream-success evidence.
