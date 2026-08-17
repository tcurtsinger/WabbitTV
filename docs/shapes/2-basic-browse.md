# Shape Brief — Phase 1 Basic Browse

**Status:** Implemented and verified — synthetic/package and real Strong browse PASS
**Phase:** 1 — Strong End-to-End Slice
**Confirmed:** 2026-08-16
**Implemented:** 2026-08-17
**Mode:** Operate
**Inherited direction:** Quiet Broadcast
**Selected structure:** Source Directory List — Compact Thumbnail Directory hybrid
**Approved composition:** `.impeccable\mocks\quiet-broadcast-basic-browse-hybrid-approved.png`

## Job and outcome

A Windows desk or couch user with one successfully imported Xtream source needs to browse an unwieldy provider catalog of Live channels, Movies, and Series by category and title. Success is a legible, compact, virtualized list that remains fast and predictable at tens of thousands of items, reaches the truthful next action, and returns the user to the same category, position, and item without becoming a provider storefront.

## Scope and boundary

- One closely coupled browse family covers the Live, Movies, and Series destinations: all use the single ready source, its imported categories, the same two-pane topology, bounded list queries, and the existing shell/focus contract.
- Includes the minimum continuations required by locked product behavior: Live hands off to playback immediately; Movie opens a plain title-plus-Play continuation; Series opens a plain season/episode continuation whose provider detail loads lazily.
- Excludes source setup, all-source/unified scope, M3U, search, filters, user-visible sorting, favorites, groups, duplicates, recommendations, category shelves, hero/storefront presentation, enriched details, source variants, final card/grid treatment, player controls/errors, PiP, and multiview.

## Selected direction and first viewport

**Source Directory List** is a functional two-pane content field inside the verified Quiet Broadcast shell.

- Keep the existing collapsed 72 px rail; it expands as its existing overlay and never moves browse content.
- The quiet header carries the destination title, passive first-source name, and a truthful total. It has no Phase 1 source-scope selector or discovery action.
- A fixed roughly 228 px **Categories** pane starts with `All Live`, `All Movies`, or `All Series`; it then shows imported provider categories and shows `Uncategorized` only if it exposes actual ungrouped records.
- The dominant right pane names the selected category and contains a vertical virtualized list.
- The approved hybrid takes C's small artwork-forward TV scanning cue and B's compact text-ledger density: each compact row has a small fixed provider thumbnail/logo or restrained placeholder, a title, quiet contextual label when useful, and optional forward affordance. The row—not its artwork or chevron—is one focus target.
- Provider art can add color but cannot become a poster wall, grid, card system, or invented metadata. Every development title, count, category, and thumbnail remains clearly synthetic compositional evidence.

## Interaction and restoration

- First entry selects `All <kind>` and the first available row. Returning to a destination restores the last viable category, scroll position, and row focus.
- Up/Down traverses categories or titles. List-end movement requests the next bounded page while retaining focus; items are never eagerly built for the entire catalog.
- Left from a title goes to the selected category; Left again reaches the existing rail. Right from a category returns to that category's remembered title. Enter/Select chooses a category or activates a title.
- Back/Escape first returns from Movie or Series continuation to the exact practical browse context; otherwise it follows the existing shell rule to open the rail. Playback return restores the same browse context.
- Mouse may select and scroll, but no action is hover-only. Keyboard/remote focus is the existing crisp 2 px signal-amber edge with no layout shift.

## States and ranges

1. **Catalog query, category change, and next-page extension:** bounded skeleton rows preserve list geometry; no blocking spinner or eager item construction.
2. **No source or catalog not ready:** restrained state leads to the existing Source Setup surface, without duplicating setup.
3. **Empty category:** plain truthful message and one direct `All <kind>` return path.
4. **Catalog/query failure:** concise redacted recovery message, usable existing catalog preserved, and a Settings/source recovery path.
5. **Lazy Series failure:** selected-series context stays intact; Retry and Back are clear; no raw response, URL, or credential-bearing information appears.
6. **Long labels:** compact stable rows visually clamp/ellipsis names but expose complete accessible labels and nonexclusive pointer/focus help.
7. **Missing/broken artwork:** fixed Quiet Broadcast placeholder preserves the exact thumbnail space and does not block list use.
8. **Constrained Windows width:** when two readable panes no longer fit, replace the fixed Categories pane with one header **Categories** launcher. It opens a full-height in-shell overlay; dismissal restores launcher focus and selection restores title focus. This is structural adaptation, not a new mobile visual world.

## Minimal continuation contract

- **Live:** row activation starts the separately shaped playback handoff immediately.
- **Movies:** row activation opens only title, optional thumbnail/placeholder, and `Play`. It has no synopsis, cast, recommendations, or extra actions.
- **Series:** row activation opens only title, season navigation, and episode list. Fetch its provider detail lazily; episode activation hands off to playback. It has no show hero, related content, episode-card wall, or enrichment.

## Acceptance evidence

- Windowed and fullscreen Windows renders at the approved 1265×713 composition plus a constrained-width Categories-overlay render.
- Widget coverage for title/category traversal, remote-equivalent focus, mouse parity, empty/loading/error states, long labels, absent art, incremental loading, and exact practical focus/scroll restoration.
- A real Strong clean-install browse proves all three kinds are reachable from Source ready and can traverse their imported categories without exposing credentials.
- A large sanitized fixture proves bounded query/render behavior rather than eager construction; no provider request is made solely for list scrolling.
- Movie and Series minimal continuations, lazy Series failure/retry, and handoff context are verified before Phase 1 closes. Production playback controls and playback-error visuals remain separately shaped.

## Closure record

On 2026-08-17, the ordinary maintainer-local production run rendered Live, Movies, and Series catalogs and categories after Strong import (sanitized totals: 56,712 Live, 176,792 Movies, 47,253 Series). It also verified the Live/Movie/Episode player handoffs and the confirmed Escape/focus return behavior without recording provider data or credentials. Closing and reopening retained the source and immediately restored the persisted catalog.

## Confirmation record

The user approved the **Compact Thumbnail Directory hybrid** on 2026-08-16: C's small artwork-forward television feel combined with B's compact text-ledger density, inside the shared two-pane Source Directory List. The user also approved `All <kind>` as the default entry category and the narrow-window Categories overlay. This brief is limited to Phase 1 functional browse; later visual redesign remains deferred.
