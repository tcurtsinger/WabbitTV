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
