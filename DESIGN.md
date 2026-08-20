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

**The Mounted Artwork Window Rule.** Fixed thumbnails in virtualized Browse, Search, Home, and My Library rows may begin loading after a short mounted-row dwell without requiring click or focus. Only the bounded visible/cache window participates; fast-scrolled rows cancel queued or active work, and the shared loader admits at most two requests. Artwork never expands a dense directory into a poster wall or blocks title navigation.

## Typography

Segoe UI is the Windows-native workhorse throughout. The actual implemented roles are display for the Home heading, title for shelf headings, card-title for media titles, body for explanatory copy, label for metadata, nav-label for 15 px rail labels (500 normally, 700 when selected), and action-label for the 14 px filled action.

**The TV-Distance Rule.** Keep hierarchy through weight, size, and warm-white/quiet-text contrast; do not introduce a decorative display face or compress functional labels below the implemented label role.

## Layout

The persistent rail reserves 72 px; on hover or focus it expands as a 224 px overlay without moving the content. Its destination rows are 48 px minimum rather than fixed: at high text scale they grow, wrap complete labels, and remain reachable in one vertically scrollable focus plane. Content destinations lead; Settings is bottom-anchored behind one restrained separator whenever height permits and remains reachable through the same scroll plane when height is constrained. Home uses a 48 px left safe inset (24 px in the implemented narrow layout), 22 px top inset, 32 px right inset, and 48 px bottom inset.

The first pinned shelf is a 264 px horizontal composition: a 248 px context panel, 24 px gap, then a horizontal carousel. Standard shelves use a 14 px card gap, 36 px separation, and 220 px carousel height. Below 780 px, the focused shelf stacks its panel above its carousel; this is a layout adaptation, not a different visual world.

My Library uses a 270 px personal-collection directory beside a dominant mixed-media ledger. The item organizer is a 360 px right drawer at the ordinary Windows viewport; group administration uses a 460 px right continuation. Below the shell's 760 px content threshold, either continuation owns the full content plane instead of squeezing a third column.

Corner Signal uses a 320 px fixed 16:9 playback surface at ordinary Windows widths and a 256 px surface below 760 px, inset 20 px from one of four corners. Multi-view always keeps two equal side-by-side Live planes; constrained widths retain that equality and compress only the shared deck instead of stacking the streams.

**The Directory-Not-Storefront Rule.** Catalog destinations may use a stable category pane beside a compact, virtualized title list. Small fixed provider thumbnails or Quiet Broadcast placeholders aid television-distance scanning, but titles remain the primary identifier and artwork never turns a functional directory into a poster grid.

**The Shelf-Not-Hero Rule.** Context belongs beside the selected item in the first pinned shelf. It never becomes a promotional banner or reserves invented metadata when there is no item.

## Elevation & Depth

Depth is tonal first: graphite, surface, and raised make the browsing plane. Only an active card gains the implemented modest shadow (0 8px 16px rgba(0,0,0,0.33)) and 1.025 scale. Panels and ordinary cards stay flat except for a 1 px line.

**The Active-Only Lift Rule.** No ambient glow, broad shadow, glass, gradient, or persistent lift; elevation identifies the current target.

## Shapes

Controls use the 6 px radius, cards 7 px, and context panels 8 px. Borders are normally 1 px line; keyboard/remote focus is a crisp 2 px signal-amber edge. Shapes are compact, almost square, and never pill-like.

**The Crisp Edge Rule.** Keep every new visible form inside the documented 6–8 px language unless its own surface is separately shaped.

## Components

- **Rail destination:** 48 px minimum; selected state uses its slightly raised fill, warm-white icon/text, and a persistent 2 px quiet structural location marker, while keyboard/remote focus alone adds the 2 px amber border. Complete labels wrap at 1.5x/2x text; focus reveals the destination inside the scrollable short-height rail. Each row exposes one authoritative button/selected semantic name, one click cursor, and a quiet raised hover state that never imitates focus. The collapsed icon rail expands on hover or focus, and no action is hover-only. Settings is the separated bottom utility destination rather than another uninterrupted content sibling; the passive playmark remains quiet text so amber stays semantic.
- **Focused shelf and media card:** the focused shelf exposes title, kind, selected item, note, and fixture/manual-order status in its panel. Cards hold artwork above a compact text footer; focus and hover may lift the card, but only keyboard/remote focus receives the amber 2 px edge.
- **Empty-state actions:** no-source mode has one amber filled “Add source” action. No-personalization mode uses three dark direct-entry controls with a 2 px amber focused edge. Each is semantic, click/tap capable, and Enter/Select activatable.
- **State grammar:** no-source remains a centered, restrained instruction with one next action; no-personalization remains an informative choice row. Neither fabricates catalog activity or provider content.
- **Source Ledger:** the verified first-source surface remains a graphite task field with a centered 648 px maximum form and a low, full-width dock. The dock has exactly three equal Live, Movies, and Series cells with thin dividers; it never gains a fourth disclaimer cell. Cancel is the left secondary action, Connect and import is the right amber primary action, and completed cells may show real imported counts.
- **Source Management directory:** Settings uses a compact source directory beside one selected-source ledger. The selected row keeps a restrained raised fill while its 2 px amber edge is reserved for actual focus. Rows show connector, enabled/refresh state, and compact contribution counts; the ledger keeps full counts and explicit actions. Refresh is the sole amber maintenance action, Rename remains a quiet local-only control, and Remove is the only confirmed destructive action.
- **Library Visibility ledger:** Manage visibility opens an in-shell, source-local directory rather than a modal. A compact Live/Movies/Series selector and Hidden only recovery control lead to a bounded provider-category directory and dense item ledger. Selecting a category is non-destructive; one explicit Hide/Restore category action controls the category, while each item retains its own state. The category header adds equal quiet-outline Hide all and Restore all actions with a concise mixed-state summary. Hide all replaces that action row with an inline confirmation rather than opening a modal; Restore all is immediate. Both are scoped to the selected source and kind and never rewrite item or Uncategorized state. Selected rows use raised fill, focused controls use the unchanged 2 px amber edge, and narrow Windows widths keep the bulk row inside the existing directory overlay rather than becoming a phone layout.
- **Catalog directory:** a compact header scope control switches between All Sources and one named source. All Sources uses one full-width, source-labeled virtual ledger; a named source restores its stable category pane beside the compact title list. Provider category trees are never fused. Each row is one focus target with an optional small fixed provider thumbnail or placeholder, title, and quiet contextual label; the 2 px amber focus edge never changes row geometry.
- **Live Now/Next — implemented Phase 6 contract:** an existing compact Live row may add one quiet secondary line only when exact source/channel `get_short_epg` data is locally available. Channel identity remains primary; missing data never fabricates a program title, creates an eager provider request fan-out, or turns the directory into cards.
- **Xtream Live Guide — implemented Phase 6 contract:** `Guide` follows Live in the rail and uses one classic matrix for one enabled Xtream source and one visible provider category at a time, including `All Live`. A compact focusable channel column stays fixed beside a bounded horizontal time ruler and exact-duration program blocks. The header owns source, category, and conditional `Go to now`; a restrained focus-context line exposes full local-time labels. Signal amber marks focus, not the current-time ruler. Constrained Windows keeps the matrix and narrows/scrolls its time window instead of becoming cards or an agenda.
- **Local Search:** Search shares the persisted catalog scope and uses one bounded, local-only mixed Live/Movie/Series ledger. Its native text field supports physical keyboard and mouse input; remote activation opens the restrained A–Z/0–9 keyboard with Space, Back, Clear, and Done. All Sources rows retain source provenance, an empty query never dumps the catalog, and result activation reuses the existing Live playback and Movie/Series continuations.
- **Personal Library directory:** Favorites remains the first stable entry; custom groups follow their explicit local order. Create group stays a quiet directory-header action, while Manage Favorites/Manage group remains a secondary ledger-header action. Mixed Live, Movie, and Series rows keep one title-led focus target plus the shared quiet organizer affordance.
- **Direct Organizer Drawer:** Organize preserves the originating ledger and presents one item summary, Favorite, a bounded multi-select group list, and explicit Cancel/Save. One Save represents the complete desired membership set. At constrained widths the same surface becomes a full content-plane continuation and returns to the exact origin; it never becomes a modal menu attached to every row.
- **Group management continuation:** Create and rename support physical and TV keyboards. Pin/unpin, directory order, Home shelf order, and manual group-item order use explicit controls rather than drag-only interaction. The 460 px item-order toolbar reflows its move actions above a full-width remove action, and Delete focuses Cancel while stating that catalog/source items remain intact.
- **Pinned personal shelves:** Favorites and custom groups share one explicit Home shelf order. Pin appends, move changes only shelf order, and unpin removes only the shelf. Empty collections remain truthful; no promotional or recommendation row substitutes for missing personal content.
- **Broadcast Deck player:** playback owns the client below the native Windows frame. Revealed chrome uses one edge-attached graphite identity band and one full-width graphite transport deck, never floating cards. At wide sizes the primary transport cluster is mathematically centered while volume/fullscreen remain right-aligned; constrained windows use the compact inline arrangement. Starting/buffering uses a small edge-free status mark. Recovery starts on one 44 px-class primary action and uses the same 2 px amber focus edge. Explicit fullscreen hides the native frame and Escape restores it before leaving playback.
- **Tracks ledger:** Tracks extends the Broadcast Deck as one edge-attached graphite ledger with truthful available audio and subtitle choices, explicit Auto/Off defaults, and a Done return. It traps focus while open and never exposes raw locators or engine detail.
- **Corner Signal:** continued playback sits in one fixed 16:9 graphite panel with an 8 px corner, thin line, restrained active shadow, and Return, Move corner, Mute, and Close controls. It moves only among four fixed corners over the seven implemented content destinations, including Guide. Settings and management replace navigation with a centered Stop playback and continue confirmation whose initial safe action is Cancel.
- **Multi-view:** two Live stages keep equal visual weight with one 2 px divider and one full-width shared graphite deck. The selected/audible tile alone receives the amber edge; audio transfer, mute, collapse, and stop remain one compact control field. At constrained width the deck compacts while the two stages stay side-by-side.
- **Source connection allowance:** the selected-source ledger adds a quiet Simultaneous streams section with Automatic, 1, and 2 controls. It explains the effective local/provider/default value without presenting two as provider permission; saving, failure, retry, and focus restoration remain in the existing ledger grammar.
- **General startup setting — implemented Phase 6 contract:** Settings adds one fixed app-level `General` entry outside source rows. Its single startup control offers Home, Previous screen, and Last channel. Last channel means the exact last Live identity that produced usable video; it never means title search or a merged substitute.

**Phase 6 implementation checkpoint — 2026-08-19.** The implemented Now/Next, Guide, Corner Signal-on-Guide, and General startup surfaces follow confirmed Shape 12. The user's first packaged Strong guide run settled 149 channels as 148 empty, 1 available, 0 error, and 0 refreshing, with 4 programs overlapping the Guide window. That proves sparse short-EPG availability and no stuck lease, but the repeated/stuck `Preparing` presentation was a real defect rather than provider absence. The corrected contract derives status from the active viewport, retains only three 40-row snapshots (120 channel IDs), distinguishes malformed data from valid empty schedules, releases obsolete work with prompt generation-safe cancellation and lease cleanup, permits manual Retry to bypass only persisted errors, surfaces typed local-persistence recovery, and keeps paging, category, and `Go to now` lifecycle exact.

The final corrected tree passes 581/581 serial tests in 80.125 seconds, clean analysis and diff-check, independent closure, seven deterministic credential-free Flutter renders, and cold/default Debug plus normal/default Release Windows packages using the process-scoped FileTracker workaround. Debug completed in 42.132 seconds at 1,140,736 bytes with SHA-256 `77C8EF3FA4884EC9470828BC0D8347C12292D600818D73C1ADE51F1054AFF341`; Release completed in 48.068 seconds at 183,296 bytes with SHA-256 `D112C13F8FF39927C50A86A0E4CE96F890E99DF1811E120164A81A971BEB2B7F`. Both packages target `lib/main.dart` with no WABBIT fixture/probe defines. After running the corrected Guide Release, the user reported `Ok pass`; at the user-observed level this closes the repeated/stuck `Preparing`, reverse-scroll, and rapid category/scope packaged behavior. No title, timing, screenshot, program-coverage, resource, or credential claim is attached to that acceptance.

The subsequent packaged local-file picker report was a real Windows lifecycle defect: `Choose M3U file` appeared frozen/`Not Responding` and required Alt+F4. Wabbit does not read the playlist before selection; it receives a path first and starts local-file acquisition only after `Connect`. The direct correction keeps the existing owned Windows picker and adds one in-flight request, an `endOfFrame` pending paint, blocked conflicting actions, redacted recovery, and exact focus restoration without changing the adapter, plugin, runner, parser, or importer. Independent review passes. In the rebuilt Release, the lead observed the pending state and owned dialog, canceled with Escape to the responsive exact Choose focus, reopened, selected the Downloads test playlist, and saw the field populate. The app then closed without importing or adding a source. When subsequently asked to retry the corrected local M3U file flow in the new packaged Release, the user replied exactly `Pass`; this accepted the picker defect correction and corrected chooser flow only at that checkpoint. The representative M3U URL was separately user-reported to have worked great. After the required corrected local-file flow was stated exactly as `Connect → import → browse → playback`, the user replied exactly `Yes, full flow passed`. This closes representative M3U readiness, final daily-driver acceptance, Phase 6, and Windows V1 without inferring timings, screenshots, titles, resource measurements, provider coverage, or credentials beyond the supplied evidence.

**The Directional Return Rule.** Left on the first content item opens the rail; Escape returns to the rail; leaving the rail restores the last viable content focus. Arrows move predictably within and between shelves, Enter/Select activates, and mouse hover never gates an action.

**Post-V1 left-sidebar polish checkpoint — 2026-08-20.** The user approved remote/accessibility correctness, bottom-anchored Settings with a separator, and all five initial independent critique findings: the absent documented remote Menu path, weak collapsed selected orientation, incomplete high-text/television-distance behavior, duplicate expanded semantic announcements, and under-articulated pointer/utility hierarchy. The implemented rail now routes shell-level remote Menu to navigation only when no contextual surface owns it, preserves My Library's contextual Organize action, retains selected-location truth separately from amber focus, wraps and reveals all destinations through 2x text and short heights, announces each target once, and gives pointer users a restrained row hover/click affordance.

Final independent review reports **PASS** with no remaining P0/P1/P2 findings. Formatting checked 100 files with 0 changes, analysis is clean, the full serial suite passes 587/587 in 81.055 seconds, diff-check passes, and four deterministic credential-free Flutter sidebar renders pass 4/4 in `docs/evidence/sidebar-polish/README.md`. Fresh production packages pass: Debug completed in 46.187 seconds at 1,140,736 bytes (2026-08-20 10:36:58.778 -05:00; SHA-256 `41CA311CF6D1DE92A5FA16B45E1E1B5A817B09F80C3945071E0E2639AB529919`) and Release completed in 47.954 seconds at 183,296 bytes (2026-08-20 10:38:04.592 -05:00; SHA-256 `411B7E51BEA6779EFF51A5E3C97356066B59B142D6FC2479986A7F25A2603E1B`). Both target `lib/main.dart` with no custom WABBIT defines. The user then replied exactly `Approved`, closing this bounded packaged polish checkpoint without adding unreported interaction detail.

## Do's and Don'ts

**Do**
- Do preserve the Windows title bar and Segoe UI identity in this Windows-first surface.
- Do use signal amber for active focus and the immediate no-source action; keep resting selected-location truth structural and non-amber.
- Do use real provider art at runtime and identify development art as fixture-only.
- Do keep the completed Phase 6 Xtream Live Guide and startup behavior within confirmed `docs/shapes/12-phase6-xtream-live-guide-startup.md` and preserve the separate, bounded evidence for Strong Guide, representative M3U URL, corrected local-file full flow, and final daily-driver acceptance. Treat later UI/UX polish as ongoing unnumbered maintenance, not Phase 7. Separately shape any later detailed-card or non-Windows pattern if it is ever authorized. Player controls, Corner Signal, and first two-stream Multi-view already follow their confirmed Shapes.

**Don't**
- Don't create a promotional hero, recommendation rail, provider category shelves, gradients, glass, neon bloom, or decorative blobs.
- Don't treat illustrative titles, source labels, connection state, or artwork as product claims.
- Don't add hover-only behavior or allow focus motion to shift the underlying content layout.
- Don't generalize this Home grammar into an app-wide component library without a separately shaped need.
