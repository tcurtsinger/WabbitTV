# Shape Brief — Phase 2 Local Search

**Status:** Implemented / runtime verification pending  
**Phase:** 2 — Catalog and Source Management  
**User decisions recorded:** 2026-08-17  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast  
**Selected result structure:** A — One mixed Live/Movie/Series ledger  
**Selected remote text entry:** A — Minimal in-app TV keyboard  
**Draft compositions:**  
- `.impeccable\mocks\quiet-broadcast-local-search-a-mixed-ledger.png`  
- `.impeccable\mocks\quiet-broadcast-local-search-a-tv-keyboard.png`

## Job and outcome

A Windows desk or couch user needs to find a known title across tens of thousands of local Live channels, Movies, and Series without remembering which source or provider category contains it. Success is a direct local query, one scan-friendly mixed ledger, an equally complete physical-keyboard and TV-remote path, and activation into the existing truthful playback or continuation flow.

## Scope and boundary

- Search operates only on the imported local catalog and uses the same **All sources / one source** header control shaped for catalog browse. It makes no provider network request.
- One result ledger mixes Live, Movie, and Series matches. It does not create tabs, grouped result sections, filter chips, sort controls, recommendations, recent searches, trending content, or a content dump before a query exists.
- Result activation reuses existing behavior: Live hands off directly to playback; Movie opens its minimal Play continuation; Series opens its minimal season/episode continuation.
- Search does not own favorites, custom groups, deduplication controls, enriched metadata, voice input, provider discovery, or a general-purpose on-screen keyboard.
- The native Windows frame, 72 px collapsed rail, Quiet Broadcast tokens, compact row density, fixed 2 px amber focus edge, and no-hover-only rule remain unchanged.

## Selected topology and first viewport

**A — One mixed ledger** keeps Search as a single local task surface.

- The header names **Search** and carries the shared compact scope control at the same position as Live, Movies, and Series.
- One clear search field spans the content plane. It contains the query, a search affordance, and one explicit **Clear** action; it is not split into multiple modes or advanced controls.
- A non-empty query produces one bounded, virtualized ledger in stable local order. Every row is one focus target and shows a fixed small artwork/placeholder, a clear `LIVE`, `MOVIE`, or `SERIES` label, title, and optional quiet context.
- In **All sources**, every row shows its local source name. In a single-source scope, the redundant source column may recede while the result type remains explicit.
- A blank query shows only a restrained instruction to search the local library. It never fills the surface with all titles, provider promotion, suggestions, history, or invented activity.
- The visible sample query, titles, source names, artwork, result count, and ordering in both draft compositions are synthetic layout evidence.

## Physical keyboard, mouse, and remote input

- A physical keyboard types directly into the native text field, keeps standard cursor/editing behavior, and updates bounded local results after a short debounce. Mouse selection, caret placement, Clear, row activation, and scrolling have full parity.
- Enter/Select on the search field from remote navigation opens the minimal in-app TV keyboard as one in-shell modal overlay. It contains exactly the letters A–Z, numbers 0–9, **Space**, **Back**, **Clear**, and **Done**.
- Arrow keys traverse the visible key geometry with no dead cells. Within a row, Left/Right moves one key; Up/Down chooses the nearest key center in the adjacent row, including the wider footer actions. Enter/Select activates the focused key.
- **Back** deletes one character. **Clear** empties the query without closing the keyboard. **Done** closes the overlay and moves focus to the first viable result; if no result exists, focus returns to the search field.
- Back/Escape closes the overlay without clearing the query and restores search-field focus. Back/Escape from the search surface then follows the shell's existing rail-return rule.
- The TV keyboard has no shift state, punctuation page, prediction, animation flourish, or decorative theme. Literal local matching is case-insensitive; physical-keyboard input remains available for punctuation and other characters.

## States and ranges

1. **Empty query:** quiet instruction only; no catalog dump.
2. **Short, typical, long, or Unicode query:** safe literal local search, visual ellipsis where required, full accessible value, and no query-language operators exposed to the user.
3. **No matches:** names the current query and scope and leaves the field plus Clear available; no recommendation fallback.
4. **Searching or extending results:** stable skeleton rows preserve geometry; prior usable results may remain until replacement is ready.
5. **Local search failure:** concise redacted error, query retained, Retry and Clear available, no database text or source credential material.
6. **Scope change with a query:** reruns the same local query in the new scope and keeps focus predictable.
7. **Large catalog:** bounded result pages and visible-row virtualization; neither query input nor TV keyboard causes eager catalog construction.
8. **Session return:** restores the practical query, scope, scroll position, and viable focused row for the current app session; no search history is persisted or presented.

## Accessibility and responsive behavior

- The full query, result title, media kind, and source are present in accessible labels even when visually clamped. Search status and result-count changes are announced without stealing focus.
- The amber 2 px focus edge never changes field, row, or key geometry. Minimum remote and pointer targets remain television-friendly, and the keyboard's visible order matches its directional order.
- At constrained Windows widths, the scope remains in the header, result metadata compresses before titles, and the TV keyboard stays inside the content safe area without becoming a phone layout.

## Acceptance evidence

- User confirmation of both 1265×713 Search compositions before visible implementation: mixed ledger and TV-keyboard overlay.
- Windowed and constrained-width renders for empty query, results, no matches, loading, failure, long/Unicode query, All sources, one source, and keyboard overlay.
- Widget coverage for physical typing, mouse parity, remote keyboard traversal, Back/Clear/Done, scope changes, result activation, focus restoration, and announcements.
- Large sanitized fixture evidence that search remains bounded and off the UI isolate, plus real-source evidence that Live/Movie/Series results activate correctly without any provider search request.

## Confirmation gate

The user selected **2A — One mixed Live/Movie/Series ledger** and **3A — Minimal in-app TV keyboard**, then explicitly confirmed both linked 1265×713 first viewports on 2026-08-17. The implementation is complete within this boundary. Automated, synthetic render, audit, and Windows build checks pass; user-run packaged Windows mouse/keyboard/remote interaction and real Strong search/activation measurements remain pending before runtime verification.
