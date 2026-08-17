# Shape Brief — Phase 1 Production Player

**Status:** Implemented and verified — source, synthetic packaged player, and real Strong production flow PASS  
**Phase:** 1 — Strong End-to-End Slice  
**Confirmed:** 2026-08-17  
**Implemented:** 2026-08-17  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast  
**Selected composition:** A — Broadcast Deck  
**Approved comp:** `.impeccable/mocks/quiet-broadcast-player-a-broadcast-deck.png`

## Job and outcome

A Windows desk or couch user activates a Live channel, Movie, or Episode and immediately enters reliable, distraction-free playback. Success means the stream starts, essential controls remain familiar and remote-friendly, failures are recoverable, and leaving restores the exact originating browse context.

## Scope and boundary

- One full-client production playback takeover for the existing typed Live, Movie, and Episode handoffs.
- Includes essential daily-use controls, explicit fullscreen, one bounded quiet retry, sanitized recovery, and a collapsed technical-details disclosure.
- Keeps one active playback session and disposes every prior transport before an opening, retry, replacement, or return.
- Excludes PiP, multiview, source variants, resume/history, audio and subtitle selection, channel zapping, next episode, detached windows, provider-limit settings, and any second session.

## Selected direction and composition

**Broadcast Deck** inherits Quiet Broadcast rather than inventing a player theme.

- Playback takes over the entire Wabbit client area and hides the application rail while preserving the dark native Windows title bar.
- Video owns the stage using aspect-preserving contain behavior with graphite letterbox/pillarbox; it is never cropped to fit the window.
- Revealed chrome has one thin solid-graphite identity band at the top and one compact full-width solid-graphite transport deck at the bottom.
- The top band carries Back, the truthful title, and media kind/Live state. The bottom deck carries the timeline where applicable, transport controls, volume, and fullscreen.
- Chrome uses warm-white hierarchy, quiet gray supporting state, compact square controls, crisp 1 px seams, 6–8 px restrained corners, and one 2 px signal-amber focus edge. There are no gradients, glass, glow, floating cards, pills, provider brands, or storefront patterns.

## Controls and interaction

- Chrome is visible on entry for four seconds. Mouse movement, Up, Enter, or Select reveals it again.
- It auto-hides only when no control retains focus. Down from the control field can return focus to the video stage and hide the chrome.
- Enter/Select activates. Arrow movement between controls is spatial and deterministic. Mouse and keyboard/remote share the same actions.
- **Live:** Play/Pause, mute/volume, and fullscreen. It does not display a fake seek timeline or seek actions.
- **Movie/Episode:** Play/Pause, ten-second backward/forward, elapsed/duration timeline, mute/volume, and fullscreen. Left/Right adjusts a focused timeline or volume control.
- Fullscreen is explicit and never automatic. Escape/Browser Back exits fullscreen first when active; otherwise it exits playback.
- Exiting cancels and disposes the active session before restoring the originating Live row, Movie Play continuation, or Series episode focus.

## States and failure behavior

1. **Starting:** restrained Wabbit loading mark, `Starting <title>`, and an immediately usable Back action.
2. **Playing:** unobstructed video when the chrome is hidden.
3. **Buffering:** quiet non-blocking status over the video without replacing the current frame.
4. **Paused:** chrome stays visible.
5. **Failure after one quiet retry:** title, primary `Try again`, and secondary `Back`. Missing saved credentials instead offer primary `Open Settings`.
6. **Technical details:** collapsed by default and limited to a sanitized failure category, media kind, attempt count, and local time. Credentials, URLs, endpoints, provider IDs, provider responses, titles beyond the visible item title, and raw media-engine errors never appear.

The first usable video frame has a twenty-second deadline. A transport/start failure disposes the failed session, retries once quietly, and then shows recovery. An explicit Try Again starts a new bounded two-attempt cycle.

## Layout ranges

- The reference window is 1265 × 713, with larger/fullscreen and constrained Windows sizes required at verification.
- Video remains the dominant plane at every supported size. The top band clamps long titles; the bottom deck keeps one stable timeline row and compact control row rather than wrapping into a card grid.
- At constrained width, control spacing and volume length compress while 44 px-class actions, focus visibility, and the full control set remain intact.

## Fidelity inventory

| Region | Commitment | Implementation medium |
|---|---|---|
| Native frame | Existing dark Windows title bar and Wabbit TV identity | Windows runner/native frame |
| Video stage | Real active media, contain fit, graphite letterbox/pillarbox | `media_kit_video` `Video` |
| Top identity band | Back, truthful item title, media kind/Live state | Semantic Flutter widgets and established Material icons |
| Timeline | Real elapsed/duration and seek position for Movie/Episode only | Flutter semantics, focus, pointer, and player streams |
| Transport deck | Compact square transport, volume, and fullscreen controls | Flutter widgets, keyboard actions, and media session adapter |
| Focus state | Stable 2 px amber edge with no layout shift | Flutter Focus system |
| Starting/buffering | Restrained code-native loading state; no artwork or provider claim | Flutter widgets and player state |
| Recovery | Redacted Retry/Back/Open Settings with collapsed safe details | Flutter widgets and coarse failure model |
| Demonstration video | Comp imagery is synthetic composition evidence only | Never shipped; runtime provider media replaces it |

## Do not literalize from the comp

- The city image is synthetic demonstration material, not bundled playback content or a product claim.
- The comp's light Windows title bar is incorrect for Wabbit; retain the existing dark native title bar.
- `City Desk`, progress, duration, volume, and playback state are illustrative. Runtime values must come from the active item/session.
- The exact photographic crop, pixel positions, and generated icons are north-star evidence. Core text and controls remain semantic, code-native, accessible Flutter UI.

## Acceptance evidence

- Widget coverage for Live versus VOD controls, four-second reveal/hide behavior, mouse and keyboard/remote traversal, timeline/volume adjustment, fullscreen Back behavior, retry/disposal ordering, redaction, and exact focus restoration.
- Packaged Windows renders and interaction at 1265 × 713, larger/fullscreen, and constrained width.
- **PASS:** A real Strong production run played one Live item, Movie, and Episode from the ordinary product flow.
- **PASS:** Forced synthetic failure coverage proves quiet retry, the sanitized recovery/technical-details boundary, and usable prior-catalog preservation; no failure was induced against the maintainer's provider during the successful production run.

## Closure record

On 2026-08-17, the ordinary maintainer-local production run rendered visible video for one Live item, Movie, and Episode. Movie and Episode showed truthful VOD controls and timeline. Escape restored Live to browse and the Movie to its focused Play action before browse; the automated continuation suite covers the equivalent Episode return path. No recovery or error state surfaced during that successful sequential run. No provider title, identifier, URL, or credential was recorded.

## Confirmation record

The user confirmed full-client takeover with the Windows title bar preserved, essential controls in Phase 1, reveal-on-input/focus-aware four-second auto-hide, and composition **A — Broadcast Deck** on 2026-08-17.
