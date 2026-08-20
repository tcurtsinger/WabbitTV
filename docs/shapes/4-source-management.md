# Shape Brief — Phase 2 Source Management

**Status:** Implemented and extended through Phase 5 bounded verification  
**Phase:** 2 — Catalog and Source Management  
**User decisions recorded:** 2026-08-17  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast  
**Selected structure:** A — Source Directory + Detail Ledger  
**Draft composition:** `.impeccable\mocks\quiet-broadcast-source-management-a-directory-detail.png`

## Job and outcome

A user who already has one or more local sources needs to see each source's current contribution and status, make a deliberate maintenance action, and return to a usable library. Success is clear source state, a safe action path, and no ambiguity about which catalog contribution is affected.

## Scope and boundary

- Settings → Sources owns the source roster, add-source entry, source rename, refresh, enable/disable, edit, remove, and source status/last-usable-catalog feedback.
- It reuses the verified Source Ledger fields and three-stage Live/Movies/Series dock for adding or editing a connector.
- It does not define unified/source browse scope controls, search, custom groups, duplicate handling, scheduling, cloud sync, or player behavior.
- The existing 72 px collapsed rail, Windows title bar, Quiet Broadcast tokens, focus-return contract, and no-hover-only rule remain unchanged.

## Chosen topology and first viewport

**A — Source Directory + Detail Ledger** is a single desktop content plane: a compact, stable source directory on the left and the selected source's detail ledger on the right. Selecting a source changes the detail ledger without moving the roster. This supports a small daily source list and a growing multi-source library while retaining predictable remote scanning.

- The content field begins with **Sources** and a restrained local-management explanation, never a hero, storefront, or provider-branded destination.
- The left directory makes each source one focus target: user-assigned name first; connector type, enabled/disabled state, refresh status, and real category counts second.
- The right ledger names the selected source, states its enabled/refresh condition, exposes **Refresh**, **Edit**, **Disable** or **Enable**, and **Remove**, then presents actual Live, Movies, and Series totals in three equal compact cells.
- The implemented Phase 5 extension adds a quiet **Simultaneous streams** section with local `Automatic`, `1`, and `2` choices. Automatic explains the effective provider-reported or conservative-one result; selecting `2` is a local override, not a claim that the provider permits it.
- The composition uses graphite planes, warm-white task hierarchy, thin gray dividers, compact 6–8 px controls, and a crisp amber focus edge. Amber identifies only the current focus/immediate action.

## States and real ranges

- **Source count:** empty, one daily source, and multiple supported sources. No source-plan, provider-health, or invented provider metadata is shown.
- **Per source:** user-given name; Xtream, M3U URL, or local M3U-file connector type; enabled/disabled state; last refresh outcome; and real Live/Movies/Series counts when available.
- **Known scale reference:** the verified first Strong source contained 56,712 Live, 176,792 Movies, and 47,253 Series items. The directory and detail labels must tolerate these totals and long user-assigned names.
- **Material states:** loading roster; no sources; enabled/ready; disabled with retained local catalog; refreshing; refresh failure with last usable catalog retained; editing; removal confirmation; removal failure; and post-remove empty state.
- A disabled source remains visible and clearly says it is excluded from active results; it is not presented as deleted.

## Interaction and feedback

- Mouse selects a directory row and uses explicit labeled actions or an accessible action control; no maintenance action is hover-only.
- Keyboard/remote arrows traverse directory rows and detail actions predictably. Enter/Select activates. A 2 px amber focus edge never changes layout geometry.
- Back/Escape from detail or editor returns to the directory and restores the origin row. Back/Escape from the directory follows the existing shell rule to open the rail.
- **Refresh** gives explicit foreground status for the selected source while retaining its usable catalog. Failure keeps the source detail open with concise redacted recovery and Retry/Edit paths.
- **Rename** changes only the local display name and does not refresh.
- **Disable/enable** is immediate and reversible without confirmation. Disabling retains local catalog data but excludes that source from active unified results.
- **Edit** opens the existing Source Ledger fields prefilled for the selected connector type; credentials are obscured. The user confirmed **Save and refresh immediately**: saving changed endpoint or credential details triggers that source's refresh rather than deferring it to a second manual action.
- **Remove** is the only destructive confirmation. It names the selected source and explains that its credentials and active catalog contribution are removed while unrelated sources remain unchanged. Initial confirmation focus is Cancel; Escape/Back cancels; the amber **Remove source** action confirms. Completion restores focus to the next viable row, Add source, or rail.
- At narrow Windows widths, the directory remains vertical and detail actions stack in visible order. The three category cells stack Live → Movies → Series without changing meaning.
- Connection-allowance loading, save, failure, Retry, and focus restoration stay inside the selected-source ledger. A failed save reports no change; an Automatic read failure does not invent a provider allowance.

## Acceptance evidence

- Desktop 1265×713 and constrained-width renders for empty, one enabled source, multiple sources with a disabled source, refresh failure retaining last-good data, edit, and removal confirmation.
- Widget coverage for mouse, keyboard, and remote-equivalent focus; focus restoration; Back/Escape; all source actions; and destructive-action confirmation.
- Fixture and real-source evidence that a failed refresh retains the prior catalog, disabling excludes only the selected source, and removing clears only the selected source's credentials and active contribution.
- Long-name and large-count overflow verification using the Strong-scale totals.
- Lead flow exercise and independent visual review against this confirmed brief and Quiet Broadcast.
- Phase 5 coverage verifies local override → provider report → conservative-one precedence and that a blocked second request creates no transport. The source-limit control is included in the 469-test serial pass, inspected synthetic render evidence, independent Impeccable PASS, native-source 16/16 audit, and passing Debug/Release builds. The user-supplied packaged Strong/Windows gate accepted the reported one-stream pre-open block; this surface does not establish real two-stream permission or success.

## User decision record

On 2026-08-17, the user selected **A — Source Directory + Detail Ledger**, confirmed that editing source endpoint or credential details must **Save and refresh immediately**, and explicitly approved the recorded 1265×713 first viewport after the quiet outlined **Add source** action was added. The original Phase 2 surface is implemented and verified; Phase 5 extends only its selected-source ledger with the recorded connection-allowance control and retains every original boundary.
