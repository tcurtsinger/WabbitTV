---
name: Wabbit TV
description: Quiet Broadcast for a local, user-organized IPTV library.
colors:
  graphite: "#111212"
  rail: "#171818"
  surface: "#191A1A"
  raised: "#222321"
  rail-selected: "#262624"
  line: "#343534"
  warm-white: "#F4F0E7"
  quiet-text: "#AAA8A2"
  signal-amber: "#FFB347"
  amber-ink: "#17120A"
typography:
  display:
    fontFamily: "Segoe UI"
    fontSize: "31px"
    fontWeight: 700
    letterSpacing: "-0.7px"
  title:
    fontFamily: "Segoe UI"
    fontSize: "22px"
    fontWeight: 700
  card-title:
    fontFamily: "Segoe UI"
    fontSize: "18px"
    fontWeight: 600
  body:
    fontFamily: "Segoe UI"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.45
  label:
    fontFamily: "Segoe UI"
    fontSize: "12px"
    fontWeight: 700
  nav-label:
    fontFamily: "Segoe UI"
    fontSize: "15px"
    fontWeight: 500
  action-label:
    fontFamily: "Segoe UI"
    fontSize: "14px"
    fontWeight: 700
rounded:
  control: "6px"
  card: "7px"
  panel: "8px"
spacing:
  unit: "8px"
  compact: "12px"
  card-gap: "14px"
  panel: "20px"
  shelf: "24px"
  section: "36px"
  outer: "48px"
components:
  rail-destination:
    backgroundColor: "{colors.rail-selected}"
    textColor: "{colors.warm-white}"
    typography: "{typography.nav-label}"
    rounded: "{rounded.control}"
    padding: "0 12px"
    height: "48px"
  media-card:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.warm-white}"
    typography: "{typography.card-title}"
    rounded: "{rounded.card}"
  direct-entry:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.warm-white}"
    typography: "{typography.card-title}"
    rounded: "{rounded.control}"
    padding: "14px 18px"
  focused-action:
    backgroundColor: "{colors.signal-amber}"
    textColor: "{colors.amber-ink}"
    typography: "{typography.action-label}"
    rounded: "{rounded.control}"
    padding: "12px 16px"
---

# Design System: Wabbit TV

## Overview

**Creative North Star: "Quiet Broadcast."** Wabbit TV is a calm, local-first launch board for a user-owned viewing library: near-black structure recedes so real provider artwork can carry color. It is an Operate surface for a Windows desk or couch; browsing stays organized, legible, and deliberately unpromotional.

**The Local Signal Rule.** Signal amber communicates selection, focus, and the one immediate action—not branding wallpaper. Rabbit personality is reserved for the application icon, empty/onboarding moments, and loading; the everyday shell remains restrained.

**Key Characteristics:**
- Graphite field, warm-white hierarchy, one precise amber signal.
- Dense, task-specific browsing: personal shelves on Home and compact source directories in catalogs, never a hero or provider storefront.
- Crisp spatial navigation with equal mouse, keyboard, and remote access.

## Colors

The frontmatter is normative. Graphite is the app canvas; rail, surface, and raised form a shallow dark hierarchy; line separates without making a grid. Warm white carries reading order, while quiet text handles metadata and source status.

**The Artwork Boundary Rule.** Runtime provider artwork may be colorful. The geometric palettes visible in the proof are clearly synthetic local fixtures, not a product artwork system or a source of additional UI accents.

## Typography

Segoe UI is the Windows-native workhorse throughout. The actual implemented roles are display for the Home heading, title for shelf headings, card-title for media titles, body for explanatory copy, label for metadata, nav-label for 15 px rail labels (500 normally, 700 when selected), and action-label for the 14 px filled action.

**The TV-Distance Rule.** Keep hierarchy through weight, size, and warm-white/quiet-text contrast; do not introduce a decorative display face or compress functional labels below the implemented label role.

## Layout

The persistent rail reserves 72 px; on hover or focus it expands as a 224 px overlay without moving the content. Home uses a 48 px left safe inset (24 px in the implemented narrow layout), 22 px top inset, 32 px right inset, and 48 px bottom inset.

The first pinned shelf is a 264 px horizontal composition: a 248 px context panel, 24 px gap, then a horizontal carousel. Standard shelves use a 14 px card gap, 36 px separation, and 220 px carousel height. Below 780 px, the focused shelf stacks its panel above its carousel; this is a layout adaptation, not a different visual world.

**The Directory-Not-Storefront Rule.** Catalog destinations may use a stable category pane beside a compact, virtualized title list. Small fixed provider thumbnails or Quiet Broadcast placeholders aid television-distance scanning, but titles remain the primary identifier and artwork never turns a functional directory into a poster grid.

**The Shelf-Not-Hero Rule.** Context belongs beside the selected item in the first pinned shelf. It never becomes a promotional banner or reserves invented metadata when there is no item.

## Elevation & Depth

Depth is tonal first: graphite, surface, and raised make the browsing plane. Only an active card gains the implemented modest shadow (0 8px 16px rgba(0,0,0,0.33)) and 1.025 scale. Panels and ordinary cards stay flat except for a 1 px line.

**The Active-Only Lift Rule.** No ambient glow, broad shadow, glass, gradient, or persistent lift; elevation identifies the current target.

## Shapes

Controls use the 6 px radius, cards 7 px, and context panels 8 px. Borders are normally 1 px line; keyboard/remote focus is a crisp 2 px signal-amber edge. Shapes are compact, almost square, and never pill-like.

**The Crisp Edge Rule.** Keep every new visible form inside the documented 6–8 px language unless its own surface is separately shaped.

## Components

- **Rail destination:** 48 px high; selected state uses its slightly raised fill and warm-white icon/text; keyboard/remote focus adds the 2 px amber border. The collapsed icon rail expands on hover or focus, never through hover alone.
- **Focused shelf and media card:** the focused shelf exposes title, kind, selected item, note, and fixture/manual-order status in its panel. Cards hold artwork above a compact text footer; focus and hover may lift the card, but only keyboard/remote focus receives the amber 2 px edge.
- **Empty-state actions:** no-source mode has one amber filled “Add source” action. No-personalization mode uses three dark direct-entry controls with a 2 px amber focused edge. Each is semantic, click/tap capable, and Enter/Select activatable.
- **State grammar:** no-source remains a centered, restrained instruction with one next action; no-personalization remains an informative choice row. Neither fabricates catalog activity or provider content.
- **Source Ledger:** the verified first-source surface remains a graphite task field with a centered 648 px maximum form and a low, full-width dock. The dock has exactly three equal Live, Movies, and Series cells with thin dividers; it never gains a fourth disclaimer cell. Cancel is the left secondary action, Connect and import is the right amber primary action, and completed cells may show real imported counts.
- **Catalog directory:** a stable category pane and one compact virtualized title list form the browse grammar. Each row is one focus target with an optional small fixed provider thumbnail or placeholder, title, and quiet contextual label; the 2 px amber focus edge never changes row geometry.
- **Broadcast Deck player:** playback owns the client below the native Windows frame. Revealed chrome uses one edge-attached graphite identity band and one full-width graphite transport deck, never floating cards. At wide sizes the primary transport cluster is mathematically centered while volume/fullscreen remain right-aligned; constrained windows use the compact inline arrangement. Starting/buffering uses a small edge-free status mark. Recovery starts on one 44 px-class primary action and uses the same 2 px amber focus edge. Explicit fullscreen hides the native frame and Escape restores it before leaving playback.

**The Directional Return Rule.** Left on the first content item opens the rail; Escape returns to the rail; leaving the rail restores the last viable content focus. Arrows move predictably within and between shelves, Enter/Select activates, and mouse hover never gates an action.

## Do's and Don'ts

**Do**
- Do preserve the Windows title bar and Segoe UI identity in this Windows-first surface.
- Do use signal amber for focus, selection, and the immediate no-source action.
- Do use real provider art at runtime and identify development art as fixture-only.
- Do separately shape detailed cards, source setup, player controls, PiP, multiview, and non-Windows platform patterns before adding visible UI.

**Don't**
- Don't create a promotional hero, recommendation rail, provider category shelves, gradients, glass, neon bloom, or decorative blobs.
- Don't treat illustrative titles, source labels, connection state, or artwork as product claims.
- Don't add hover-only behavior or allow focus motion to shift the underlying content layout.
- Don't generalize this Home grammar into an app-wide component library without a separately shaped need.
