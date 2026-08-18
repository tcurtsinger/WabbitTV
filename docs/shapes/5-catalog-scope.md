# Shape Brief — Phase 2 Catalog Scope

**Status:** Implemented / runtime verification pending  
**Phase:** 2 — Catalog and Source Management  
**User decision recorded:** 2026-08-17  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast  
**Selected structure:** A — Header scope menu  
**Draft composition:** `.impeccable\mocks\quiet-broadcast-catalog-scope-a-header-menu.png`

## Job and outcome

A Windows desk or couch user with multiple enabled sources needs to understand which catalog they are browsing and switch between one source and the active unified library without losing the compact directory that already works at large scale. Success is one obvious scope control, a truthful result total, stable focus, and no invented merge of unrelated provider category trees.

## Scope and boundary

- The shared catalog header owns one scope: **All sources** or one enabled source. The choice applies consistently to Live, Movies, Series, and local Search.
- All-source results come from the active local library. Disabled sources remain managed in Settings but do not appear as active results or selectable source scopes.
- Source-scoped Live, Movies, and Series retain the verified category pane and compact title ledger from Phase 1.
- This shape does not add category fusion, a filter bar, sort controls, provider shelves, recommendations, favorites, custom groups, source management actions, or new playback UI.
- The existing native Windows frame, 72 px collapsed rail, Quiet Broadcast tokens, compact row grammar, and directional-return contract remain unchanged.

## Selected topology and first viewport

**A — Header scope menu** places one compact, labeled control at the quiet end of the catalog header. Its visible value is `All sources` or the selected local source name; it is a normal 6 px control, never a pill, chip strip, or second navigation rail.

- In **All sources**, the provider-category pane is absent. One full-width, virtualized media-kind ledger begins immediately below the header because provider categories have no truthful shared hierarchy.
- Every All-sources row retains its media title, small artwork or fixed placeholder, quiet contextual label, and explicit local source label. Source labels make provenance scannable without turning sources into category sections.
- In a single-source scope, the existing roughly 228 px Categories pane returns unchanged and contains only that source's imported categories.
- The header shows the active media kind and a truthful available total for the current scope. Counts and source names tolerate Strong-scale values and long user-assigned labels without moving the control.
- Active unified library identities appear once only when the existing local identity layer has genuinely merged them; ambiguous titles remain separate. The scope surface does not invent or expose a manual deduplication workflow.
- All labels, titles, thumbnails, sources, and counts in the draft composition are synthetic layout evidence.

## Interaction and restoration

- The scope control is one mouse, keyboard, and remote focus target. Enter/Select opens a compact anchored menu; Up/Down moves among `All sources` and enabled sources; Enter/Select applies; Back/Escape dismisses and restores control focus.
- Applying a scope closes the menu and leaves focus on the scope control. Down returns to the first viable result or the source category pane. Changing scope never moves the shell rail.
- The app retains practical browse context independently per media kind and scope during the session: selected provider category where applicable, bounded list position, and last viable row.
- If the selected source becomes disabled or is removed, the catalog falls back to **All sources**, announces the change accessibly, and keeps the user in the same media destination.
- Scope switching is a bounded local database operation and makes no provider request. Loading uses stable directory skeletons; a redacted local-query failure preserves the last usable list and offers Retry.
- On constrained Windows widths, the header control remains visible. All-sources stays a full-width ledger; a single-source category directory continues to use the already shaped in-shell Categories overlay.

## States and ranges

1. **No active source:** existing source recovery state; no empty scope menu.
2. **One enabled source:** the control still offers All sources and that source because source scope restores its provider categories while All sources preserves the unified grammar.
3. **Multiple enabled sources:** All sources first, then stable source roster order; long names ellipsize visually and remain complete to accessibility.
4. **Disabled source:** excluded from active scope choices while its local catalog remains retained. An enabled source whose latest refresh failed remains selectable and continues to use its last-good catalog.
5. **Empty chosen scope or media kind:** plain truthful empty state with a scope-change path, not fabricated catalog activity.
6. **Large catalog:** bounded paging and visible-row virtualization remain mandatory; scope switching never eagerly materializes the entire library.

## Acceptance evidence

- User confirmation of the 1265×713 All-sources Live composition before visible implementation.
- Windowed and constrained-width renders for All sources, one source with categories, one enabled source, long source names, empty scope, and fallback after disable/remove.
- Widget coverage for menu traversal, Enter/Select, mouse parity, Back/Escape, focus return, per-scope practical restoration, and the rail handoff.
- Fixture and real-source evidence that All sources includes enabled contributions only, source scope uses only that source, no provider categories are merged, and switching scope makes no provider call.

## Confirmation gate

The user selected **1A — Header scope menu** and explicitly confirmed the linked 1265×713 first viewport on 2026-08-17. The implementation is complete within this boundary. Automated, synthetic render, audit, and Windows build checks pass; user-run packaged Windows mouse/keyboard/remote interaction and real Strong browse measurements remain pending before runtime verification.
