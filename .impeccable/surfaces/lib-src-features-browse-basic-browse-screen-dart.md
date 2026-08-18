---
version: 1
slug: "lib-src-features-browse-basic-browse-screen-dart"
primary_target: "lib/src/features/browse/basic_browse_screen.dart"
related_targets: ["lib/src/app_shell.dart","lib/src/features/sources/source_catalog_database.dart","lib/src/features/sources/source_setup_screen.dart"]
---

# Basic Browse

## Scope and mode

- **Mode:** Operate
- **Scope:** The Live, Movies, and Series catalog browse family, including Phase 2's confirmed All Sources / named-source header scope. It owns the shared scope launcher, source-category navigation when one source is selected, the full-width unified ledger when All Sources is selected, bounded title loading, and practical browse-context restoration.
- **Boundary:** It does not own source setup or management, Search, filters, user-selectable sort, favorites, custom groups, manual duplicate handling, enriched metadata, source variants, playback controls, PiP, or multiview.

## Audience, job, and task

A Windows desk or couch user who has finished importing their own first Xtream source needs to locate a known channel, movie, or series in a provider catalog that can contain tens of thousands of items. The task is category to title to the next truthful action, with predictable mouse, keyboard, and TV-remote traversal—not provider discovery or promotion.

## Chosen direction and memorable moment

- **World:** Inherit Quiet Broadcast: graphite structure, warm-white hierarchy, quiet metadata, precise signal-amber focus, compact square geometry, and provider artwork as the color carrier.
- **Approved composition:** `.impeccable/mocks/quiet-broadcast-basic-browse-hybrid-approved.png`.
- **Composition:** Source Directory List: a stable Categories pane beside one dominant virtual title list. The approved hybrid uses C's small artwork-forward television scan cue within B's compact text-ledger density. It remains a directory, never a hero, shelf, or storefront.
- **Memorable moment:** an amber-focused compact row can be recognized at TV distance by its title and its small artwork swatch, while the user always sees the provider category that contains it.

## First viewport and component grammar

- Existing 72 px collapsed overlay rail remains untouched. The content header shows `Live`, `Movies`, or `Series`, a truthful total, and the confirmed compact `All sources` / named-source scope control from `.impeccable/mocks/quiet-broadcast-catalog-scope-a-header-menu.png`.
- All Sources removes the provider-category pane and uses one full-width, source-labeled ledger. A named-source scope restores that source's category pane unchanged. Provider categories are never merged across sources.
- A roughly 228 px Categories pane begins with `All <kind>`, then imported provider categories, and `Uncategorized` only when it exposes real ungrouped items.
- The main plane names the selected category and renders bounded, virtualized compact rows. A row is one focus target: fixed small provider thumbnail or Quiet Broadcast placeholder, title, quiet category label where useful, and an optional forward affordance. Thumbnails are decoration, never the only identifier or interaction target.
- Rows retain stable geometry: long labels clamp/ellipsis visually while their complete accessible names remain available. No focus movement shifts the list.

## Interaction and state contract

- Entering a destination restores its exact practical category, scroll position, and focused row; a first visit opens `All <kind>` on its first available row. Up/Down moves within the active virtual list. Left reaches the selected category, Left again reaches the rail; Right returns to the remembered row. Enter/Select chooses categories or activates the row. Back/Escape leaves a minimal continuation first, then opens the rail.
- On a constrained Windows width where both panes cannot remain readable, the Categories pane becomes one header launcher and a full-height in-shell overlay. Its focus returns to the launcher on dismissal and to the selected/restored title on selection; this is not a mobile redesign.
- Loading and next-page extension use stable skeleton rows. Empty categories provide `All <kind>` return. No source/catalog-not-ready state leads to existing Source Setup. Local query and lazy Series errors are concise, redacted, preserve prior usable context, and offer retry/Back. Missing artwork uses a fixed placeholder.
- Live activates playback immediately. Movies open only a plain title-plus-Play continuation. Series opens only a plain season/episode continuation, lazily loads its detail, and lets an episode activate playback. Playback behavior and error UI remain separately shaped.

## Constraints and unresolved decisions

- Bounded database queries and visible-row virtualization are mandatory for tens of thousands of records; ordering is stable but not user-configurable in Phase 1.
- Full mouse, keyboard, and remote parity; no hover-only action; crisp 2 px amber keyboard/remote focus; practical Back/focus restoration.
- Development thumbnails and labels are synthetic evidence only. Runtime artwork must never block browsing or create a false metadata claim.
- **Unresolved decisions:** None. The user approved the original hybrid directory on 2026-08-16 and confirmed the Phase 2 header-scope / full-width All Sources extension on 2026-08-17.

## Implementation checkpoint

- The Phase 2 scope extension is implemented with one shared locally persisted controller, bounded All Sources and named-source queries, per-kind/per-scope practical restoration, disabled-source fallback, and exact-source playback handoff.
- Focused tests, the full serial 223-test suite, static analysis, five-case synthetic actual-Flutter render evidence, independent critique/polish, final source-audit closure, and the Windows debug build pass.
- Runtime verification remains pending for packaged Windows mouse/keyboard/remote interaction and real Strong browse measurements. The synthetic captures do not prove provider behavior.
