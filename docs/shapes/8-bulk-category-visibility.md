# Shape Brief — Bulk Category Visibility

**Status:** Verified — user-supplied packaged runtime PASS  
**Phase:** 2 — Catalog and Source Management  
**User confirmation recorded:** 2026-08-17  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast  
**Extends:** `docs/shapes/7-library-visibility.md`  
**Draft composition:** `.impeccable/mocks/quiet-broadcast-bulk-category-visibility-a-directory-toolbar.png`  
**Target continuation:** `lib/src/features/sources/library_visibility_screen.dart`

## Job and outcome

Within one selected source and the currently selected Live, Movies, or Series
kind, a user needs to remove every provider category from active discovery in
one deliberate operation, then recover every category just as directly.
Success is fast decluttering without losing provider data or accidentally
rewriting individual item choices.

This is category-level visibility only. **Hide all categories** sets every
current-category preference to Hidden; **Restore all categories** sets every
current-category preference to Included. Neither action changes an individual
item's hidden state. The existing effective rule remains category included
**and** item included, so restoring all categories does not restore individually
hidden items.

## Recommended direction — directory-toolbar bulk control

Keep the existing Source Category Directory + Item Visibility Ledger intact.
Add a compact **Category visibility** toolbar immediately above the left
provider-category directory, below the kind selector. This placement makes the
scope unambiguous: selected source + currently selected kind + categories only.
It does not compete with the selected category's existing per-category action
in the right ledger.

- The toolbar states a truthful summary such as `909 categories · 12 hidden`.
  It is quiet metadata, not a progress dashboard.
- Its right side holds two explicit outlined actions: **Hide all categories**
  and **Restore all categories**. Disabled actions remain visible with a
  concise reason: Hide is unavailable when none are included; Restore is
  unavailable when none are hidden.
- A mixed state shows both available actions. An all-hidden state leaves
  Restore as the one actionable recovery path; an all-included state leaves
  Hide as the one actionable maintenance path.
- On constrained Windows widths, the same toolbar lives at the top of the
  existing in-shell category-directory overlay. It is never moved into a
  top-level shell menu or hidden behind a mouse-only overflow affordance.

## Deliberate hide-all confirmation and recovery

Hide all can make the active catalog appear empty, so activating it opens an
**inline confirmation tray in the directory toolbar**, not a modal. The tray
replaces the two toolbar actions and says exactly what will change, for example:
`Hide all 909 Live categories? Individual item choices stay unchanged.`

- **Cancel** is the initially focused action for keyboard/remote entry.
- **Hide 909 categories** is the amber confirmation action; count and media
  kind are derived from the current local directory only.
- Cancel, Escape, or Back dismisses the tray and restores focus to **Hide all
  categories** without changing any preference.
- On success, preserve the selected category and practical directory/item
  position. Update category states in place, announce that all current-kind
  categories are hidden and item choices were not changed, and move focus to
  **Restore all categories** (the immediate recovery action).
- **Restore all categories** applies immediately with no confirmation because
  it only returns categories to the normal included state and remains
  reversible. On success, preserve selection/position, announce that item
  choices remain unchanged, and move focus to **Hide all categories**.

## Input, focus, and feedback

- Mouse click, Enter/Select, and remote activation expose the same actions;
  no hover-only control exists. Controls retain the Quiet Broadcast 2 px amber
  focus edge and do not change layout when focused.
- In desktop topology, Up from the first category row reaches the bulk toolbar;
  Down returns to the prior category row. Right continues to the selected
  category's existing ledger actions; Left returns to the directory toolbar in
  the established order. The header's kind selector remains the parent focus
  row.
- Hidden only continues to be recovery, not a second bulk command. After Hide
  all, enabling Hidden only reveals the hidden categories and preserves any
  prior individual-item preferences for inspection.
- During a bulk write, retain the prior directory/ledger geometry and make
  just the toolbar non-interactive with a compact `Updating categories…`
  status. Do not replace the screen with a spinner or rebuild every row one by
  one.
- On a local write failure, keep the last usable directory and selection,
  leave active Browse/Search unchanged, show `Category visibility was not
  changed`, and offer Retry for the same operation plus Cancel. Focus returns
  to the failing action or its confirmation tray; an accessible status message
  does not steal focus.

## States and ranges

1. **All included:** Hide all is available; Restore all is visibly disabled.
2. **Mixed:** both controls are available; exact included/hidden counts are
   shown for the selected kind.
3. **All hidden:** Restore all is available; Hide all is visibly disabled;
   item-level hidden choices remain inspectable.
4. **No provider categories:** omit the toolbar rather than offering a
   meaningless bulk action. Uncategorized items retain only their existing
   item-level visibility controls.
5. **Loading/refresh:** show the existing stable skeleton or last usable
   directory; do not offer a bulk mutation against an unknown category set.
6. **Large directory:** work is one bounded local operation for the selected
   source and kind; the UI never materializes item rows just to hide categories.

## Scope and boundaries

- **In scope:** selected-source, current-kind category Hide all/Restore all;
  inline confirmation for Hide all; local status, recovery, and focus behavior.
- **Out of scope:** individual-item bulk operations, cross-kind or cross-source
  actions, provider requests, delete semantics, rules by language/name,
  Favorites/custom groups, and new top-level navigation.
- Existing per-category and per-item controls remain available and unchanged.
- The bulk action applies to the provider categories currently imported for
  that source and kind. A genuinely new category introduced by a later refresh
  starts Included; this does not create a permanent hide-new-categories rule.
- Builders must preserve v6 refresh semantics: category bulk changes persist
  locally across refresh, while individual item flags are never overwritten by
  either bulk action.

## Acceptance criteria

- User explicitly confirms this draft before visible implementation.
- Widget coverage proves kind/source scoping; all-included, mixed, all-hidden,
  no-category, loading, and local-write-failure states; keyboard/remote/mouse
  activation; confirmation cancel; Back/Escape; and focus recovery.
- Database coverage proves Hide all and Restore all change only category flags
  for the selected source and kind, preserve item flags, are atomic on failure,
  and persist through refresh.
- Named Browse, All Sources, and Search reflect bulk category changes using
  the existing category AND item rule; restoring all categories does not
  surface individually hidden items.
- A synthetic desktop and constrained-width render demonstrate the directory
  toolbar, confirmation tray, and all-hidden recovery before packaged testing.

## Confirmation gate

The user confirmed the directory-toolbar bulk visibility viewport on
2026-08-17 before implementation.

## Implemented evidence

- **Hide all** and **Restore all** each perform one atomic local category update
  scoped to the selected source and media kind. Item flags and Uncategorized
  rows are untouched; provider categories introduced by a later refresh start
  Included.
- Hide all uses the confirmed inline tray with Cancel initially focused;
  Restore all remains immediate. The summary, disabled actions, focus return,
  and loaded ledger position update without rematerializing item pages.
- The shell treats a pending bulk write as busy and cannot exit or unmount the
  visibility continuation before persistence finishes.
- Failure copy distinguishes truthfully between an atomic write that did not
  commit (`Category visibility was not changed`) and a committed local write
  whose view refresh failed (`Category visibility was saved locally; this view
  could not refresh`). Retrying the latter refreshes the view without repeating
  the write.
- `flutter analyze` is clean and the full serial suite passes 283 tests.
  Independent Impeccable critique passes, and the generic Flutter native-source
  audit passes 16/16.
- Debug and Release Windows builds pass at
  `build/windows/x64/runner/Debug/wabbit_tv.exe` (2026-08-18 00:31:48 local) and
  `build/windows/x64/runner/Release/wabbit_tv.exe` (2026-08-18 00:32:32 local).
- Three inspected synthetic Flutter renders cover mixed state, inline Hide-all
  confirmation, and constrained all-hidden recovery in
  `docs/evidence/phase2-bulk-category-visibility/README.md`.

## Packaged runtime verification

On 2026-08-18, the user exercised the packaged Release build against Strong:
Hide all for the active Live scope, restore the desired Live categories, verify
Browse/Search propagation, then refresh and verify retention. The user reported
`Perfect, pass`. This is user-supplied runtime evidence; no screenshot, timing,
or provider title was recorded.
