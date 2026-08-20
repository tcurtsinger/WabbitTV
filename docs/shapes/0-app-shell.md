# Shape Brief — Windows App Shell

**Status:** Verified  
**Phase:** 0 — Direction and Feasibility  
**Confirmed:** 2026-08-16  
**Verified:** 2026-08-16  
**Mode:** Operate  

## Job and outcome

Give desk and couch viewers one stable frame for reaching Home, Live, Movies, Series, Search, My Library, and Settings without exposing provider complexity. Success means a user always knows where they are, can move between destinations with mouse, keyboard, or remote, and returns from playback to the exact prior browsing context.

## Scope and boundary

- Includes the persistent navigation rail, page frame, source-scope/header region, destination switching, focus ownership, window/fullscreen adaptation, and transition into/out of playback.
- Supports ordinary resizable Windows 11 windows and fullscreen/TV use from the first implementation.
- Excludes Home content and row composition, source setup internals, catalog-card design details, playback controls, PiP controls, and multiview controls; each receives its own Shape when it becomes active.

## Interaction contract

- The slim rail is always spatially present and expands on mouse hover or keyboard/remote focus without pushing or reflowing content.
- Left/Menu reaches the rail; leaving it restores the prior content focus.
- Shell-level remote Menu opens the rail only when no contextual surface owns that key; My Library Organize and other topmost contextual behavior remain authoritative.
- Enter/Select activates. Back/Escape dismisses the topmost transient state before navigating backward.
- Selecting a live channel tunes immediately. Movies and series open a detail screen first.
- Playback hides the shell. Returning restores the prior destination, source scope, scroll position, and focused item when practical. Later PiP overlays the shell.
- No action is hover-only. Focus must remain visible, predictable, and television-legible.

## Selected direction — Quiet Broadcast

- Near-black graphite canvas, warm-white typography, a restrained signal-amber interaction/focus accent, and minimal decorative color outside imported artwork.
- The rail anchors the left edge; a quiet top band carries page title, source scope, and contextual actions while content owns most of the viewport.
- Focus uses a crisp amber edge, modest elevation, and a clear label rather than neon glow.
- Motion is brief and functional: focus movement, rail expansion, and destination transitions only. No bounce, parallax, or ambient motion.
- The same rail, header, focus, card-proportion, and playback-transition language must scale across every top-level destination.
- Wabbit personality does not decorate routine navigation; it is reserved for the icon, onboarding, loading, and empty states.

## Verification evidence

- Windows debug build: `build\windows\x64\runner\Debug\wabbit_tv.exe`
- Keyboard/remote runtime: collapsed rail, overlay expansion without content shift, destination activation, and destination-specific focus restoration verified
- Native frame: Wabbit TV title and packaged rabbit-TV application icon verified
- Automated coverage: `test\widget_test.dart`
- Independent Impeccable finish verdict: **PASS**
- Post-V1 sidebar polish: four deterministic credential-free Flutter renders pass 4/4 in `docs/evidence/sidebar-polish/README.md`; final independent review reports **PASS** with no remaining P0/P1/P2 findings

## States and ranges

- Windowed and fullscreen layouts
- Collapsed, hovered, and focused rail
- Mouse, keyboard, and remote focus ownership
- Destination change and Back/Escape restoration
- Entering and returning from fullscreen playback
- Long destination/source names must remain legible without destabilizing the shell

## Acceptance evidence

- Representative Windows renders at an ordinary desktop window and fullscreen/TV viewport
- Keyboard/remote-only traversal through every top-level destination with no focus trap
- Mouse traversal with no exclusive hover action
- Rail expansion shown not to move the content field
- Playback enter/return demonstration restoring destination, scope, scroll, and focus
- Lead comparison against this brief and independent rendered review before the app-shell gate closes

## Implemented Phase 6 extension

The user confirmed `docs/shapes/12-phase6-xtream-live-guide-startup.md` on 2026-08-19, and that extension is implemented and accepted. `Guide` is one rail destination immediately after Live, stable Previous-screen restoration includes Guide, and the shell's overlay rail, focus, Back/Escape, and playback-return grammar remain intact. Phase 6 and Windows V1 are complete; later UI/UX refinement is ongoing unnumbered maintenance rather than Phase 7.

## Post-V1 left-sidebar polish — complete; user approved

On 2026-08-20 the user authorized all five bounded critique findings, explicitly choosing remote/accessibility correctness and Settings bottom-anchored behind a restrained separator. The initial independent critique found: (1) the documented remote Menu route was absent, (2) collapsed selected-location truth was too subtle, (3) high-text and television-distance behavior was incomplete, (4) expanded destinations could be announced twice, and (5) pointer and utility hierarchy were under-articulated.

The correction implements all five without redesigning Quiet Broadcast:

- a shell-level remote Menu route opens navigation without stealing a topmost contextual Menu action;
- a persistent 2 px non-amber marker preserves selected location while amber remains active focus;
- 48 px-minimum rows wrap complete labels, scroll at short heights, and reveal the focused destination through 1.5x/2x text;
- destination and Now Playing semantics announce one authoritative button/selected name;
- quiet row hover and the click cursor give pointer truth, while Settings occupies a separated bottom utility seam and the passive playmark no longer spends amber.

Final independent review reports **PASS** with no remaining P0/P1/P2 findings. Formatting checked 100 files with 0 changes, analysis is clean, the full serial suite passes 587/587 in 81.055 seconds, scoped diff-check passes, and the four-state actual-Flutter render checkpoint passes 4/4. Debug completed in 46.187 seconds at `build/windows/x64/runner/Debug/wabbit_tv.exe` (1,140,736 bytes; 2026-08-20 10:36:58.778 -05:00; SHA-256 `41CA311CF6D1DE92A5FA16B45E1E1B5A817B09F80C3945071E0E2639AB529919`); Release completed in 47.954 seconds at `build/windows/x64/runner/Release/wabbit_tv.exe` (183,296 bytes; 2026-08-20 10:38:04.592 -05:00; SHA-256 `411B7E51BEA6779EFF51A5E3C97356066B59B142D6FC2479986A7F25A2603E1B`). Both target `lib/main.dart` with no custom WABBIT defines.

After the corrected Release and its evidence were presented, the user replied exactly `Approved`. That concise response closes the post-V1 sidebar gate; it does not supply or imply any additional timings, screenshots, or interaction details.
