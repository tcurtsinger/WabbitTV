---
version: 1
slug: "lib-main-dart"
primary_target: "lib/main.dart"
related_targets: ["lib/src/app_shell.dart","lib/src/features/home/home_screen.dart"]
---

# App Shell + Home

## Scope and mode

- **Mode:** Operate
- **Scope:** Windows app shell and the first Home viewport only. App-shell navigation, focus, shelves, empty/no-personalization states, and focus restoration are in scope. Source setup internals, detailed cards, player controls, PiP, and multiview controls remain separately shaped work.

## Audience, job, and task

Windows enthusiasts and ordinary households use mouse/keyboard or a TV remote to resume deliberately organized or recently watched content. Home must make pinned groups, Favorites, and real viewing continuity faster to reach without becoming a provider storefront.

## Chosen direction and memorable moment

- **World:** Quiet Broadcast — graphite field, warm-white type, restrained signal-amber focus, artwork-led color, crisp edges, short functional motion.
- **Approved composition:** `.impeccable/mocks/quiet-broadcast-home-b-focused-shelf.png`
- **Composition:** Collapsed spatial rail; quiet Home header; first pinned shelf gets a shelf-height metadata panel at left and focused carousel at right; ordinary shelves continue below. No promotional hero.
- **Memorable moment:** focus on a user-pinned shelf quietly reveals useful context without interrupting browsing or expanding into a storefront hero.

## Component grammar

- Corners: restrained 4–8 px radii; cards feel nearly square, never pill-like.
- Lines: 1 px neutral separators; focused item uses a crisp 2 px signal-amber edge.
- Elevation: only the active card lifts modestly; no neon bloom or broad ambient shadow.
- Type: Windows-native workhorse UI face; page title 28–32 px, shelf title 20–22 px, card title 17–19 px, metadata 13–15 px. Warm white primary, quiet gray secondary.
- Spacing: 8 px base rhythm. TV-safe outer inset approximately 40–48 px after the rail. Dense enough for 2.5 shelves at the 16:10 reference viewport.
- Motion: 120–180 ms focus and rail transitions; no bounce, parallax, or ambient motion.

## Fidelity inventory

| Region | Commitment | Medium |
|---|---|---|
| App field | Near-black graphite canvas, no gradients or decorative atmosphere | Flutter color/theme code |
| Native frame | Wabbit TV title and original rabbit-TV/play application icon | Windows runner title plus packaged ICO from `assets/branding/wabbit-tv-icon.png` |
| Navigation rail | Spatially persistent collapsed rail; expands as overlay on focus/hover without shifting content; seven destinations with clear line icons | Semantic Flutter widgets plus established icon package/material icons |
| Header | Quiet Home title and truthful connected-source status only | Semantic Flutter text/widgets |
| Focused shelf | Shelf-height left context panel plus right carousel; remains a shelf, never a hero | Flutter layout/widgets |
| Standard shelves | Pinned groups first; Favorites/Continue/Recent only when nonempty; horizontal virtualization | Flutter widgets/list virtualization |
| Focus state | 2 px amber edge, modest lift, readable from TV distance; identical focus logic for keyboard/remote | Flutter focus system and animation |
| Artwork | Provider artwork at runtime; missing-art placeholder from the same restrained geometry | Runtime raster plus code-native placeholder |
| Development content | Invented titles/artwork are fixture-only and must be clearly synthetic; no real providers or commercial claims | Sanitized local fixture data/assets |
| Progress | Thin progress indicator only when real local history exists | Flutter code |
| Empty states | Restricted rabbit personality only when no sources or no personalization; one obvious next action | Separately shaped state within confirmed Home brief; semantic Flutter UI |

## Do not literalize from the comp

- `Northbound`, `Field Notes`, `Night Signal`, artwork, source labels, descriptions, and connection state are illustrative fixture content, not product claims.
- The comp's exact poster crops, icon drawings, and pixel positions are north-star evidence, not raster UI.
- A metadata panel appears only for a real focused item; it must not reserve misleading content when the shelf is empty.
- The selected rail state and sample progress bar do not justify fake activity or history.

## Constraints and unresolved decisions

- Full keyboard/remote behavior and mouse parity; no hover-only actions.
- Windowed and fullscreen layouts must remain usable; exact breakpoint and card aspect behavior are implementation measurements, not new art direction.
- Home remains unified across enabled sources and never displays provider recommendation/category shelves.
- Runtime networking is only to user-configured providers.
- Detailed card grammar, source setup, player controls, PiP, and multiview require their own confirmed Shapes before visible implementation.

## Verification

- Populated Home: `build/verification/phase0-home-focused-shelf-fixed.png`
- No-personalization Home: `build/verification/phase0-home-no-personalization.png`
- No-source Home: `build/verification/phase0-home-no-sources-fixed.png`
- Independent Impeccable finish verdict: **PASS**
- Flutter analysis, eight widget tests, and packaged Windows debug build: pass
