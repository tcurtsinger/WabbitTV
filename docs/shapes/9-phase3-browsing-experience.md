# Shape Brief — Phase 3 Browsing Experience

**Status:** Verified  
**Phase:** 3 — App Shell and Browsing Experience  
**Confirmed:** 2026-08-18  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast  
**Approved My Library composition:** `.impeccable\mocks\quiet-broadcast-my-library-a-directory-ledger.png`  

## Job and outcome

A Windows desk or couch viewer with a very large local IPTV catalog needs the already functional shell, catalogs, Search, Home, and My Library to feel like one finished daily-driver experience. Success means real local continuity, restrained provider artwork, truthful recovery states, and predictable mouse, keyboard, and remote return behavior without replacing the approved dense directory grammar with a storefront.

## Scope and boundaries

- Retain the verified 72/224 px overlay rail, scoped Live/Movies/Series directories, mixed local Search, source surfaces, Broadcast Deck player, bounded paging, and practical scope/scroll/focus restoration.
- Finish Browse and Search with fixed-geometry provider thumbnails and stable missing, loading, slow, broken, and unsupported-artwork fallbacks. Catalogs remain compact virtual ledgers; there is no poster grid, promotional hero, recommendation rail, or fused provider-category tree.
- Productionize Home with genuine initializing, no-source, no-history, and locally backed **Recently Watched** states. An item enters history only after playback produces usable video. Phase 3 records viewing occurrence, not playback progress; seek/resume remains Phase 5.
- Replace the My Library placeholder with a read-only Favorites/custom-groups directory and selected mixed-item ledger. Phase 4 owns favorite/group creation, mutation, reordering, pinning, and duplicate management.
- Settings/source surfaces and production playback controls keep their verified shapes. Phase 3 may add only narrow integration seams needed for history, artwork, and return truth.

## Selected composition and hierarchy

- Quiet Broadcast remains fixed: graphite field, warm-white hierarchy, quiet metadata, one precise signal-amber focus edge, Segoe UI, 6–8 px geometry, tonal depth, and provider artwork as the only routine color carrier.
- My Library uses **A — Direct Directory + Ledger**. A compact left directory lists Favorites and custom groups with truthful counts; the dominant right plane contains one dense, virtualized, manually ordered mixed Live/Movie/Series ledger with source provenance. One row is one focus target.
- The approved composition is a north star, not literal product data. Its titles, art, groups, counts, and source labels are synthetic layout evidence. It does not authorize Phase 4 actions.
- At constrained Windows widths, the directory becomes the established in-shell launcher/overlay pattern and returns focus to the launcher or selected item rather than becoming a phone layout.

## Artwork policy

- HTTP(S) artwork locators supplied by a configured source are permitted as source-owned artwork input; Wabbit adds no metadata or unrelated artwork service.
- A missing local cache entry begins only after a short dwell while its virtual row remains mounted, so the visible/cache window fills without a click. Rapid scrolling disposes rows and cancels intermediate or queued work; the catalog never schedules the entire result set.
- Requests are bounded, cancellable, coalesced by locator, and concurrency-limited. Raw locators never enter logs, filenames, screenshots, or diagnostics. Decoded size is bounded to the visible thumbnail/card geometry.
- Cached art may appear during passive scrolling. Missing, slow, oversized, corrupt, cancelled, and failed art retains the exact placeholder geometry and never blocks catalog use.
- Start with the smallest measured cache that serves the packaged Strong flow; no generalized media-cache framework or metadata service is introduced without evidence.

## Interaction and state contract

- Every primary screen remains usable with mouse, keyboard, and remote. Enter/Select activates; no action is hover-only.
- Left from the first content target reaches the rail. Back/Escape dismisses the topmost overlay or continuation first, then reaches the rail. Leaving the rail restores the last viable content target.
- Browse, Search, Home, My Library, details, and playback preserve practical destination, scope, directory selection, bounded list/shelf position, and focus on return.
- My Library covers initializing, empty Favorites/groups, populated mixed lists, long/Unicode names, unavailable variants, local-read failure with Retry, next-page extension/failure, and source removal/disable fallout.
- Browse/Search expose truthful importing, refreshing-last-good, refresh-failed-last-good, empty scope/category, no result, page-extension failure, and local-read failure without replacing usable content with a global error when last-good data exists.
- Home does not fabricate personalization. With sources but no history or Phase 4 organization, it keeps direct Live/Movies/Series entry and concise organization guidance.

## Real ranges and performance

- Strong-scale evidence is approximately 56.7K Live, 176.8K Movies, and 47.3K Series across hundreds of provider categories.
- Catalog/Search/My Library queries remain bounded and off the UI isolate; visible collections use lazy builders and keyset paging rather than eager materialization.
- Home shelves load only locally backed rows and remain horizontally lazy.
- Evidence covers the ordinary 1265×713 viewport, constrained 600×713, fullscreen/TV use, high text scale, long names, absent artwork, and enough rows/shelves to cross multiple viewport and cache boundaries.

## Acceptance evidence

- Focused and full serial tests for mouse/Enter/Select parity, remote traversal, overlays, Back/Escape, stale async completion, paging, exact practical restoration, artwork cancellation/cache bounds, history truth, and all material states.
- Actual Flutter renders for Home runtime states, Browse/Search with fixed real-art boundaries, My Library populated/empty/failure, Movie/Series continuation finish, and constrained layouts.
- Independent Impeccable critique and generic Flutter native-source audit with no unresolved material finding, followed by one bounded correction pass if needed.
- Packaged Windows verification across all seven destinations, mouse/keyboard/remote navigation, details/playback return, scope restoration, and no focus trap.
- Real Strong evidence that catalog/Search scrolling stays responsive, focused artwork loads without request backlog or memory/CPU escalation, Recently Watched appears only after usable video, and restart preserves local history.

## Confirmation record

The user confirmed the read-only My Library boundary, Recently Watched-after-usable-video rule, Phase 5 resume boundary, and bounded source-supplied artwork policy on 2026-08-18. The user then selected **A — Direct Directory + Ledger** from three 1265×713 My Library compositions. During packaged Strong verification, the user requested visible rows load without click/focus; the verified amendment uses mounted-window dwell with cancellation and two-request admission. After the rebuilt Release, the user reported `Ok way better. Pass`.
