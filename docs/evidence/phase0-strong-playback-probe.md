# Phase 0 Strong Playback Probe Evidence

**Status:** Verified PASS
**Date:** 2026-08-16
**Shape:** `docs/shapes/0-playback-probe.md`
**Target:** `lib/src/spikes/phase0/playback_probe_main.dart`

## Implemented boundary

- Separate Flutter entrypoint only; the ordinary Wabbit application has no route or control for the probe.
- `media_kit` 1.2.6, `media_kit_video` 2.0.1, and `media_kit_libs_windows_video` 1.0.11.
- Memory-only endpoint, username, and obscured password entry.
- Bounded account and discovery requests with no automatic retry, capped retained selections, response byte ceilings, and forced request cancellation on timeout.
- Sequential live, movie, and episode checks with one muted player at a time, a mounted `Video`, nonzero dimensions, an in-memory PNG screenshot gate, five-second observation, and disposal before the next stream.
- Optional two-stream check only when both reported connection fields are known, at least two connections are available, two distinct live candidates exist, and the maintainer explicitly starts it.
- Sanitized evidence excludes provider identity, credentials, endpoints, URLs, IDs, titles, raw JSON, and raw media-engine errors.

## Pre-credential verification

- `dart format --output=none --set-exit-if-changed lib test` — PASS.
- `flutter analyze` — PASS, no issues.
- `flutter test` — PASS, 22 tests after the category-bounded discovery correction.
- `git diff --check` — PASS.
- Windows debug target build — PASS.
- Windows release target build — PASS.
- Real packaged debug window at 1266 x 713 — PASS: no overflow, ledger visible, first Tab produces an amber endpoint focus, and Escape does not start or repeat a request.
- Independent Terra code verdict — PASS after resolving connection admission, bounded/cancelled discovery, series/episode identifiers, startup timing, and rejected-auth recovery.
- Independent Impeccable finish verdict — PASS with no material P1/P2/P3 findings.

The verified no-credential render is `build/verification/phase0-playback-probe-no-credentials.png`.

## Observed real run

- A maintainer-local account check passed with sanitized facts: authentication confirmed, status active, maximum connections 1, and active connections 0.
- Under the original 10-second discovery bound, `Find representative items` ended with the sanitized result `Discovery timed out`.
- On the 60-second/64 MiB retry, the live candidate request passed under the cap, while the unfiltered movie response exceeded the 64 MiB ceiling.
- The category-bounded discovery correction is pending a maintainer-local re-run. This does not verify Phase 0 work item 5.

## Final sanitized Strong result

The category-bounded re-run completed successfully in the packaged release probe:

- Account: authentication confirmed; status active; maximum connections 1; active connections 0.
- Live: PASS; startup 1898 ms; video 1280 x 720; screenshot present.
- Movie: PASS; startup 3283 ms; video 3840 x 2080; screenshot present.
- Episode: PASS; startup 3334 ms; video 1920 x 1080; screenshot present.
- Two streams: skipped, as required by the provider-reported maximum of one connection.

The sanitized result image is `build/verification/phase0-playback-probe-sanitized-results.png`. It contains no provider identity, credentials, endpoint, URL, item title, or provider ID. Phase 0 work item 5 is verified.

## Workstation build notes

The existing process-scoped `TrackFileAccess=false` workaround remains required for this workstation's MSBuild tracker. Flutter plugins also require symlink support. Because Developer Mode is not enabled and changing the machine setting requires elevation, the lead proved the builds with workspace-local directory junctions under generated `windows/flutter/ephemeral/.plugin_symlinks`; no source or system setting was changed. A normal developer setup should enable Windows Developer Mode rather than depend on that generated workaround.

## Result

`media_kit` remains the accepted Windows playback candidate. The real Strong account proved live, movie, and episode rendering with nonzero dimensions and in-memory screenshots. The provider-reported one-connection allowance also proved the conservative admission path: sequential checks ran one at a time and the two-stream check stayed skipped.
