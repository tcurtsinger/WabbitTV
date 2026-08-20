---
version: 1
slug: "lib-src-features-sources-source-management-screen-dart"
primary_target: "lib/src/features/sources/source_management_screen.dart"
related_targets: ["lib/src/features/sources/source_setup_screen.dart","lib/src/app_shell.dart"]
---

# Source Management

**Scope and mode:** Operate surface for local source management inside the existing shell. It owns the source directory, selected-source ledger, add, rename, refresh, enable or disable, edit, remove, and the Phase 5 local simultaneous-stream override; it does not own browse scope, search, organization, scheduling, cloud, or playback layout.

**Audience and job:** A Windows desk or couch user with one or more existing sources needs to understand each source's current local contribution and perform a deliberate maintenance action without endangering unrelated sources or the last usable catalog.

**Direction and memorable moment:** Inherit Quiet Broadcast. The confirmed desktop composition keeps a compact stable directory at left and the selected source's detail ledger at right, with Refresh as the sole amber immediate action. The approved first viewport is `.impeccable/mocks/quiet-broadcast-source-management-a-directory-detail.png` and the full product contract is `docs/shapes/4-source-management.md`.

**Constraints:** Full mouse, keyboard, and remote focus; Back/Escape and origin-focus restoration; source work off the UI isolate; disabled sources stay durable but are excluded from active results; failed refresh keeps last-good catalog; credentials remain OS-backed and obscured; remove is the only destructive confirmation and initially focuses Cancel; edit saves and refreshes immediately.

**Responsive behavior:** At narrow Windows widths, the source directory and detail content become one vertical task flow, action controls stack in visible order, and the three count cells stack Live, Movies, Series without changing meaning.

**Implemented truth:** The source directory reads a bounded durable roster and keeps one selected source visually anchored while focus moves through its ledger. Each row shows connector, enabled/refresh state, and compact Live/Movies/Series contribution; the detail keeps the full counts. Rename is local-only, Refresh is the sole amber maintenance action, edit saves and refreshes, disable is reversible, and remove is credential-safe and source-scoped. A quiet Simultaneous streams section adds Automatic, 1, and 2 controls plus truthful effective-limit/read/save/retry feedback; choosing 2 is only a local override and never asserts provider permission.

**Verification:** Static critique and generic Flutter native-source audit closed with no remaining P1/P2 findings. Automated verification covers mouse and Enter/Select activation, bounded remote traversal, Back/Escape and editor return, local rename, durable refresh failure, delayed removal focus restoration, high text scale, lifecycle rebinding after disable/remove, connector secrecy, last-good refresh behavior, allowance precedence, failed-save truth, and focus restoration. The Phase 5 limit control is included in the clean 469-test serial pass, inspected synthetic render evidence, independent Impeccable PASS, native-source 16/16 audit, and passing Windows Debug/Release builds. The user-supplied packaged Strong/Windows gate accepted the reported one-stream pre-open block. This evidence does not claim real two-stream permission or success.
