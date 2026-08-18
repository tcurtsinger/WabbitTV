# Shape Brief — Source Library Visibility

**Status:** Verified — user-supplied packaged runtime PASS  
**Phase:** 2 — Catalog and Source Management  
**User decisions recorded:** 2026-08-17  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast  
**Recommended structure:** A — Source Category Directory + Item Visibility Ledger  
**Draft composition:** `.impeccable/mocks/quiet-broadcast-library-visibility-a-directory-ledger.png`

## Job and outcome

A Windows desk or couch user with a large, noisy provider catalog needs to keep only the categories and individual channels, movies, and series they care about in active browsing. Success means unwanted provider material disappears everywhere the user normally discovers content, while the imported source data remains local, intact, and easy to restore.

This feature manages **source library visibility**. It is not Favorites and it does not create a custom group. Favorites save individual items for quick access; custom groups are user-named, manually ordered mixed-media collections that may be pinned to Home. Visibility instead decides whether an imported provider category or item participates in active Browse and Search.

## Confirmed behavior

- Visibility is local, reversible, and source-specific. It never changes the provider account, deletes imported catalog rows, removes credentials, or makes a provider request.
- Category and individual-item inclusion are both required. An item participates in the active library only when its provider category is included **and** its own item preference is included.
- Hiding a provider category excludes all of its available items from that named source's Browse results, All Sources, and Search. The category also leaves the ordinary named-source category pane.
- Hiding one channel, movie, or series excludes only that item from named-source Browse, All Sources, and Search.
- Restoring a category restores only the category-level inclusion. Any items individually hidden before or while the category was hidden remain hidden.
- Category visibility is independent for Live, Movies, and Series even when a provider reuses the same displayed category name.
- A category preference follows the same source, media kind, and provider category across refreshes, so newly imported items under a hidden category remain hidden. Individual preferences follow the imported provider item identity across refreshes.
- `Uncategorized`, when present, remains a truthful local grouping. Its items may be hidden individually; there is no invented provider category identity to persist.

## Selected direction and first viewport

**A — Source Category Directory + Item Visibility Ledger** extends Settings → Sources with one quiet **Manage visibility** action for the selected source. It opens a full in-shell maintenance surface rather than a modal or an expandable block inside the already dense source ledger.

- The header names **Manage visibility**, identifies the selected local source, and states **Local visibility only**. A quiet Back action returns to that source's detail and restores origin focus.
- One compact rectangular selector switches Live, Movies, and Series without changing source. It is not a pill strip or new top-level navigation.
- The left pane is a bounded, virtualized provider-category directory. Each row shows the category name, available item count, and Included or Hidden state. Selecting a row updates the right pane without changing visibility.
- The selected category's right pane names the category, shows its count and state, and provides one explicit **Hide category** or **Restore category** action. Category visibility is never changed merely by browsing the directory.
- Below the category action, one dense, virtualized item ledger shows title, media kind, and Included or Hidden state. Each item row is one focus target; Enter/Select toggles **Hide item** or **Restore item** without deleting or moving it.
- The draft deliberately shows an included selected category with individually hidden items, proving the two visibility levels are independent. Every name and count in the composition is synthetic.

## Hidden-only recovery

The compact **Hidden only** control is the recovery path, not a destructive filter.

- Off: the category directory and selected-category item ledger show all imported entries with their current local state.
- On: the left pane retains categories that are hidden or contain at least one individually hidden item. The right pane shows only hidden items for the selected category.
- A category hidden at the category level still exposes its retained item states. Restoring it does not rewrite those item states.
- Turning Hidden only off restores the prior selected category and practical list position when still viable.

## Interaction and layout

- Mouse, physical keyboard, and TV-remote paths have parity. No visibility action is hover-only.
- Up/Down traverses the active pane; Left/Right moves predictably between category and item panes. Enter/Select chooses a category, invokes the explicit category action, or toggles the focused item according to the focused target.
- The selected category uses a restrained raised fill. Only actual keyboard/remote focus uses the fixed 2 px signal-amber edge, and the edge never changes row geometry.
- State changes are immediate local operations. Focus remains on the changed category action or item row, its Included/Hidden label updates in place, and an accessible status announcement does not steal focus.
- Back/Escape returns first from the item pane to the selected category when needed, then to the selected source detail, preserving practical kind, category, scroll, and focus context for the session.
- At constrained Windows widths, the category directory becomes the existing in-shell directory launcher/overlay pattern and the item ledger remains the primary plane. It does not become a phone layout.

## States and ranges

1. **Loading:** stable directory and row skeletons retain the two-pane geometry.
2. **No provider categories:** an `Uncategorized` item ledger remains available when real items exist; otherwise show a plain empty state.
3. **All included:** truthful zero-hidden summary; Hidden only yields a direct empty recovery message.
4. **Category hidden:** category remains present in this maintenance surface with a Restore category action and its retained item preferences.
5. **Individual items hidden:** rows remain recoverable even while their category is included.
6. **Refresh:** the last usable visibility view stays available; preferences apply to the refreshed available catalog without a second user action.
7. **Local query/update failure:** preserve the last usable directory, state that no visibility change was saved, and offer Retry.
8. **Large source:** category and item reads remain bounded and virtualized; opening visibility never materializes the full catalog.

## Scope and boundaries

- **Primary visible target:** `lib/src/features/sources/source_management_screen.dart` and the new selected-source visibility continuation it launches.
- **Affected behavior:** named-source Browse, All Sources, and local Search must all honor the same effective visibility rule.
- **Untouched:** provider data, source enable/disable/remove, catalog scope, Favorites, custom groups, Home pins, duplicate merging, playback, recommendations, and remote keyboard design.
- No bulk rule builder, language detection, smart collection, category-name matching across media kinds, provider category fusion, delete flow, or background scheduler belongs in this first version.
- The earlier real Strong Search latency was corrected separately. Visibility was not used to hide or mask that performance/correctness defect.

## Implemented evidence

- The user explicitly confirmed the linked 1265×713 viewport on 2026-08-17 before implementation.
- Schema v6 persists local `hidden` flags on provider categories and individual catalog items. Active named Browse, All Sources, and Search require both flags to be included; maintenance views intentionally retain hidden entries for recovery.
- Refresh upserts preserve category and item preferences. Restoring a category changes only that category flag and leaves individually hidden items hidden.
- The real Settings continuation opens from Manage visibility, performs bounded category and 100-item page reads off the UI isolate, and returns focus to its launcher after invalidating shared catalog scope once.
- `dart format`, `flutter analyze`, and the full serial 268-test suite pass. Independent critique and generic Flutter native-source audit pass 16/16.
- Four inspected synthetic Flutter renders are recorded in `docs/evidence/phase2-library-visibility/README.md`; Debug and Release Windows packages both build.
- A sanitized copy-only Strong catalog migrated v5→v6 in 1,629 ms; category reads and first/next 100-item pages were 2–98 ms across all three media kinds. The source catalog hash was unchanged.

## Deferred non-blocking evidence

- Additional non-blocking state renders for loading, empty, and local failure may be added when their behavior changes; the four implemented-state renders already cover the shaped desktop, recovery, uncategorized, and constrained contracts.

## Confirmation gate

The user confirmed **A — Source Category Directory + Item Visibility Ledger** on 2026-08-17 before implementation.

## Packaged runtime verification

On 2026-08-18, the user exercised the packaged Release build against Strong:
Hide all for the active Live scope, restore the desired Live categories, verify
Browse/Search propagation, then refresh and verify retention. The user reported
`Perfect, pass`. This user-supplied result closes the shared visibility
surface's sole remaining runtime gate; no screenshot, timing, or provider title
was recorded. Individual-item semantics remain covered by the recorded
automated/database evidence rather than a newly claimed packaged item run.
