# Shape Brief — Phase 4 Personal Library Organization

**Status:** Implemented and packaged Strong verified  
**Phase:** 4 — Personal Library Organization  
**Decision date:** 2026-08-18  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast  
**Approved composition:** `.impeccable/mocks/quiet-broadcast-phase4-library-organization-a-organizer-drawer.png`

## Job and outcome

A viewer with a very large imported catalog needs to turn a small set of useful Live channels, Movies, and Series into a personal library without altering provider data. Success means one item can be favorited and added to several custom groups in one deliberate save; groups can be created, named, ordered, pinned to Home, and removed; every choice survives provider refresh and restart.

## Locked product boundaries

- Favorites and custom groups contain stable `library_items`, never provider rows or copied media records.
- Favorites may be pinned to Home and participate in the same explicit pinned-shelf order as custom groups.
- Custom groups are mixed-media and manually ordered. Live, Movie, and Series entries may coexist in one group.
- There is **no automatic merging, manual merging, fuzzy duplicate matching, or variant-combining UI** in Phase 4. Existing source variants remain separate library identities.
- Removing a favorite, group membership, group, or Home pin never deletes or hides the underlying source item.
- Smart/rule groups, recommendations, metadata enrichment, and playback-progress behavior remain out of scope.

## Selected composition and hierarchy

- Retain the verified My Library **Direct Directory + Ledger** topology, compact row density, virtual paging, source provenance, and one-row/one-focus-target grammar.
- A quiet `Create group` action lives in the Library directory header. Favorites remains the first stable directory entry; custom groups follow their explicit local order.
- **A — Direct Organizer Drawer** is the selected item-organization composition. The dominant ledger remains visible while a compact right in-shell drawer shows the selected item, Favorite state, a multi-select custom-group checklist, and explicit Cancel/Save actions.
- The drawer is a secondary action. Enter/Select keeps its ordinary Live playback or Movie/Series continuation behavior. Keyboard/remote Right or the application-menu action opens Organize; mouse users receive a quiet trailing organizer hit target without introducing another traversal stop.
- Browse, Search, Home shelves, My Library, and Movie/Series details use the same organizer contract. They do not invent surface-specific favorite/group menus.
- Group administration is separate from item organization. `Manage group` opens an in-shell continuation with Rename, Pin/Unpin, pinned-shelf Move Up/Down, Delete, and an explicit item-order mode with Move Up/Down and Remove. Daily browsing stays uncluttered.

## Favorites and ordering

- Favorites are deterministically ordered newest-saved first; Phase 4 does not add manual item ordering to Favorites.
- Custom-group items use explicit local ordinal order. Adding an item appends it; Move Up/Down changes only that group.
- Pinned Favorites and custom groups use one explicit Home shelf order. Pin appends to the end; Move Up/Down changes only the shelf order.
- Unpin removes only the Home shelf. The collection and all memberships remain intact.

## Interaction and focus contract

- Opening Organize focuses the first changed control when one exists, otherwise Favorite. Arrow keys traverse Favorite, the virtual checked-group list, Cancel, and Save without escaping the drawer.
- Space/Enter/Select toggles a checkbox; Save commits the complete desired membership set once. Cancel and Back/Escape discard unsaved changes and restore the exact originating item.
- The drawer traps focus only while open. Back/Escape dismisses confirmation first, then the drawer, then follows the established screen-to-rail contract.
- Create, rename, and destructive confirmation inputs remain usable by mouse, physical keyboard, and TV keyboard. Destructive Delete defaults focus to Cancel and states that items remain in the catalog.
- Reordering always has explicit Move Up/Down actions; drag may be added as mouse convenience only if it does not replace remote controls.
- While a save or reorder transaction is pending, conflicting navigation and repeated submission are blocked. The prior usable view remains visible.

## Persistence and transactional truth

- Favorite and multi-group changes from one drawer Save are applied in one local database transaction. Partial group membership success is never shown.
- Create, rename, delete, pin, unpin, collection reorder, and group-item reorder each have one bounded local transaction and a typed, credential-free result.
- Provider refresh may change availability or the preferred playable source variant, but it cannot remove favorites, groups, membership, manual order, or pin order.
- Unavailable members remain visibly retained in personal collections with a quiet `Source unavailable` state and no artwork request or playback action until an active visible variant returns.
- No provider request, credential read, or raw locator is required for organization mutations.

## States and recovery

- Cover initializing, no favorites, no groups, empty selected group, populated mixed group, unavailable member, long/Unicode group names, saving, save failure, stale local read, paging extension/failure, and source refresh/removal fallout.
- A failed save leaves the persisted state and visible ledger unchanged, uses fixed local-safe copy, and offers Retry/Cancel without leaking SQLite or source details.
- If the write commits but the follow-up read fails, say the change was saved locally and retry only the read. Never claim it was not changed.
- Delete group confirmation names the group and states that its items remain in Wabbit and their sources.
- Empty Home organization remains truthful: no synthetic shelves and no recommendation substitution.

## Responsive and performance rules

- At the ordinary 1265×713 Windows viewport the 240–270 px directory, dominant ledger, and compact organizer drawer coexist without collapsing rows into cards.
- At constrained widths the established directory launcher/overlay remains; Organize becomes a full content-plane continuation rather than a squeezed third column and returns to the exact row.
- Group and item directories remain bounded, virtualized, and keyset-paged. Checkbox state is keyed by stable collection identity rather than mounted widget state.
- Bulk membership save is set-based and transactional; it never loops one database isolate/transaction per checked group.
- Home loads only pinned collections and bounded first-shelf pages. No eager materialization of all group items or artwork occurs.

## Evidence and acceptance

- Focused database tests cover favorite idempotency, one-save multi-group replacement, custom-group CRUD, deterministic ordering, pin ordering including Favorites, source refresh/restart persistence, unavailable variants, and source-safe removal.
- Widget and shell tests cover mouse/Enter/Select parity, organizer focus trapping/restoration, TV-keyboard naming, confirmations, remote Move Up/Down, stale completions, busy navigation guards, Home shelf order, and exact return after playback.
- Strong-scale tests cover many groups, a long manually ordered mixed group, bounded paging, and transaction/heartbeat behavior off the UI isolate.
- Actual Flutter renders cover My Library default, open organizer, group management, pinned Home shelves, confirmation/failure, and constrained layout.
- Independent Impeccable critique and generic Flutter native-source audit close with no unresolved material issue before packaged Windows verification.
- Packaged Strong verification proves favorite/group changes survive refresh and restart, multiple groups update in one save, pinned Favorites/groups follow the chosen Home order, unpin preserves content, and removing membership never changes source data.

## Composition translation boundary

The approved image is a north star for topology, density, and hierarchy—not literal product data. Its titles, artwork, counts, group names, and checked states are synthetic. The build retains existing Wabbit icons, real local source state, accessible semantic controls, and responsive Flutter behavior. The mock does not authorize a third-party metadata service, duplicate merging, or a permanent three-column layout at constrained widths.

## Implementation evidence

The confirmed composition is implemented through the shared `LibraryOrganizerPane`, `LibraryGroupManagerPane`, My Library Create/Manage entry points, bounded local organization APIs, and pinned Home shelves. Six credential-free actual-Flutter renders passed and were inspected at the ordinary and constrained viewports; see `docs/evidence/phase4-personal-library-organization/README.md` for the synthetic boundary and correction record.

The user completed the packaged Strong checklist on 2026-08-18 and reported `Pass, confirmed`. This user-supplied runtime acceptance covers the persistence, atomicity, ordering, non-destructive behavior, and input paths listed above; no provider title, locator, credential, screenshot, or timing was recorded.

## Confirmation record

The user confirmed that Favorites can be pinned to Home, rejected both automatic and manual merging, approved adding one item to multiple checked groups in one save, selected **A — Direct Organizer Drawer**, and confirmed this complete brief on 2026-08-18.
