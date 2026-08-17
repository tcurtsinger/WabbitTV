---
version: 1
slug: "lib-src-features-sources-source-setup-screen-dart"
primary_target: "lib/src/features/sources/source_setup_screen.dart"
related_targets: ["lib/src/app_shell.dart","lib/src/features/home/home_screen.dart"]
---

# Source Setup

**Scope and mode:** Operate surface for Phase 1 Xtream-only first-source setup inside the existing shell. It owns the Home/Settings entry, four-field form, foreground three-stage import, errors, cancellation, and Source ready handoff; it does not own browse-list or player design.

**Audience and job:** A Windows desk or couch user connects a provider they already have and needs an understandable path from credentials to a durable local catalog. Success is a committed source, three imported counts, and an explicit Live/Movies/Series destination choice.

**Direction and memorable moment:** Inherit Quiet Broadcast. Source Ledger keeps one centered form above a stable full-width dock whose exactly three equal cells move from Waiting through Importing to Complete/Error. The approved composition is `.impeccable/mocks/quiet-broadcast-source-ledger-c-stage-dock-approved.png`.

**Constraints:** OS-backed password storage; no password in SQLite/logs; provider/catalog work off the UI isolate; no partial active source on initial cancellation or failure; full mouse/keyboard/remote focus and Back/Escape restoration; no M3U, source CRUD, browse design, or player controls.

**Implemented direction:** Source Ledger is now a Quiet Broadcast task field with an **Add source** header, **Source details** form, left Cancel/right Connect and import actions, and a low exactly-three-cell Live/Movies/Series dock. The outer form/ready container is not a fourth card or disclaimer; field surfaces carry the only local treatment. Source ready renders the verified imported counts and three browse handoffs.

**Verification:** Packaged UI and fixture-backed behavior passed 2026-08-16. Root format pass; `flutter analyze` reported no issues; the full suite passed 53 tests. Debug and release Windows packages passed with process-scoped `TrackFileAccess=false` after approved Developer Mode and VC.ATL setup. The packaged app was visually inspected at 1265x713 and a larger restored window with no overflow; dock topology, action order, focus, and keyboard traversal passed. Packaged Escape from Server URL was fixed with the screen-scoped handler, rebuilt, and verified returning to Home. Independent review closure: PASS after three P2 fixes. No provider call or credentials were used, so the live Strong check remains pending. Browse lists and production playback remain separate Shapes.
