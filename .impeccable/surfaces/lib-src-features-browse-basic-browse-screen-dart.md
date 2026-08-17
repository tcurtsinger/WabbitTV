---
version: 1
slug: "lib-src-features-browse-basic-browse-screen-dart"
primary_target: "lib/src/features/browse/basic_browse_screen.dart"
related_targets: ["lib/src/app_shell.dart","lib/src/features/sources/source_catalog_database.dart","lib/src/features/sources/source_setup_screen.dart"]
---

# Basic Browse

## Scope and mode

- **Mode:** Operate
- **Scope:** Phase 1's first-source Live, Movies, and Series catalog browse family, plus only the minimal Movie and Series continuation needed to start Phase 1 playback. It owns source-category navigation, a large virtual title list, loading/empty/error states, and browse-context restoration.
- **Boundary:** It does not own source setup, multi-source or unified scope, M3U, search, filters, user-selectable sort, favorites, custom groups, duplicate handling, enriched metadata, source variants, final card/grid visuals, playback controls, PiP, or multiview.

## Audience, job, and task

A Windows desk or couch user who has finished importing their own first Xtream source needs to locate a known channel, movie, or series in a provider catalog that can contain tens of thousands of items. The task is category to title to the next truthful action, with predictable mouse, keyboard, and TV-remote traversal—not provider discovery or promotion.

## Chosen direction and memorable moment

- **World:** Inherit Quiet Broadcast: graphite structure, warm-white hierarchy, quiet metadata, precise signal-amber focus, compact square geometry, and provider artwork as the color carrier.
- **Approved composition:** `.impeccable/mocks/quiet-broadcast-basic-browse-hybrid-approved.png`.
- **Composition:** Source Directory List: a stable Categories pane beside one dominant virtual title list. The approved hybrid uses C's small artwork-forward television scan cue within B's compact text-ledger density. It remains a directory, never a hero, shelf, or storefront.
- **Memorable moment:** an amber-focused compact row can be recognized at TV distance by its title and its small artwork swatch, while the user always sees the provider category that contains it.

## First viewport and component grammar

- Existing 72 px collapsed overlay rail remains untouched. The content header shows `Live`, `Movies`, or `Series`, the passive first-source name, and a truthful total; it contains no Phase 1 scope selector or discovery controls.
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
- **Unresolved decisions:** None. The user approved the hybrid first viewport and the default `All <kind>` behavior on 2026-08-16.
