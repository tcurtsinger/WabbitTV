# Shape Brief — Home

**Status:** Verified  
**Phase:** 0 — Direction and Feasibility  
**Confirmed:** 2026-08-16  
**Verified:** 2026-08-16  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast from `0-app-shell.md`  

## Job and outcome

Give the user one unified launch board for content they deliberately organized or actually watched. Success means Home gets the user back to a pinned group, favorite, or unfinished item quickly without becoming a provider storefront or pretending to recommend content.

## Scope and boundary

- Includes Home hierarchy, personalized shelves, real local-history continuity, source/no-personalization empty states, shelf focus behavior, and return-position restoration.
- Home is always unified across enabled sources.
- Excludes provider-scoped Home variants, promotional recommendations, source category feeds, source setup internals, group editing internals, and the detailed card system owned by later feature Shapes.

## Structural direction — Personal Shelves

- No promotional hero. The first useful shelf begins immediately below a quiet Home header.
- Pinned custom groups appear first in explicit user order, one horizontal shelf per group.
- Favorites, Continue Watching, and Recently Watched follow and disappear when empty.
- A compact Resume item may appear only when real playback history exists.
- Channels, movies, and series may share a pinned shelf with restrained media-type labels while retaining the group's manual order.
- Home remains within Quiet Broadcast: graphite field, warm-white type, signal-amber focus, artwork-led color, and no decorative rabbit treatment during routine browsing.

## Interaction contract

- Up/Down changes shelves; Left/Right moves within a shelf.
- Back returns to the app-shell rail.
- Enter/Select follows the media contract: live tunes immediately; movies and series open details.
- Returning from detail or playback restores the exact shelf, horizontal position, and focused item when practical.
- Mouse wheel/trackpad and pointer behavior may accelerate navigation but cannot expose exclusive actions.
- Shelf labels, position, and focus remain readable at television distance.

## States and ranges

- No sources: a restrained Wabbit empty state leads directly to Add Source.
- Sources but no personalization: direct Live, Movies, and Series entry points plus concise Favorite/Create Group guidance.
- One or many pinned custom groups
- Empty and populated Favorites, Continue Watching, and Recently Watched
- Mixed-media shelves with long titles, missing artwork, and unavailable source variants
- Enough shelves/items to require vertical and horizontal virtualization rather than eager rendering

## Acceptance evidence

- Representative windowed and fullscreen Home renders using the approved Quiet Broadcast world
- No promotional hero or provider-generated recommendation/category shelf
- Keyboard/remote-only traversal across and within shelves with predictable Back behavior
- Demonstration of exact focus/shelf restoration after detail and playback return
- No-source and no-personalization states with one obvious next action
- Lead comparison against this brief and independent rendered review before the Home gate closes

## Verification evidence

- Approved composition: `.impeccable\mocks\quiet-broadcast-home-b-focused-shelf.png`
- Populated render: `build\verification\phase0-home-focused-shelf-fixed.png`
- No-personalization render: `build\verification\phase0-home-no-personalization.png`
- No-source render: `build\verification\phase0-home-no-sources-fixed.png`
- Mouse/keyboard/remote focus, source-neutral fixture labels, responsive window bounds, and all three Home states covered by `test\widget_test.dart`
- Independent Impeccable finish verdict: **PASS**
