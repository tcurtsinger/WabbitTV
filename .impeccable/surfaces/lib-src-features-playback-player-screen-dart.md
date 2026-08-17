---
version: 1
slug: "lib-src-features-playback-player-screen-dart"
primary_target: "lib/src/features/playback/player_screen.dart"
related_targets: ["lib/src/app_shell.dart","lib/src/features/browse/playback_handoff.dart"]
---

# Production Player

## Scope and mode

- **Mode:** Operate
- **Scope:** Phase 1 single-session production playback for Live, Movie, and Episode handoffs, including essential controls, explicit fullscreen, bounded retry, sanitized recovery, and exact return to browse.
- **Boundary:** No PiP, multiview, source variants, resume/history, tracks/subtitles, zapping, next episode, detached window, provider-limit settings, or second transport.

## Audience, job, and task

A Windows desk or couch user has deliberately selected something from their own provider and needs the content to start, remain controllable with mouse/keyboard/remote, recover truthfully, and return them to the exact originating context.

## Chosen direction and memorable moment

- **World:** Inherit Quiet Broadcast—graphite structure, warm-white hierarchy, signal-amber focus, compact square controls, and functional motion only.
- **Approved composition:** `.impeccable/mocks/quiet-broadcast-player-a-broadcast-deck.png`.
- **Composition:** Full-client aspect-preserving video with a thin revealed top identity band and one full-width bottom Broadcast Deck. The shell rail is hidden; the dark native Windows title bar remains.
- **Memorable moment:** one input reveals a crisp, familiar control deck over the user's video; four seconds later the chrome yields the whole client area back to playback without losing remote focus or context.

## Interaction and state contract

- Chrome appears initially and on mouse movement, Up, Enter, or Select; it hides after four seconds only when no control is focused. Down can return focus to the video stage and hide it.
- Live uses Play/Pause, volume/mute, and fullscreen. Movie/Episode add ten-second seeking and a truthful timeline. Fullscreen is explicit; Back exits fullscreen first, otherwise disposes and restores origin focus.
- Starting is bounded to twenty seconds for a first usable frame. A failed transport is disposed, retried once quietly, then replaced by redacted Retry/Back or Open Settings recovery with collapsed sanitized details.
- One transport exists at a time. Credentials and final stream URI exist only inside the active session and never reach diagnostics or logs.

## Component grammar and fidelity

- Solid graphite edge-attached bands; no gradients, glass, glow, cards, pills, or provider branding.
- 44 px-class square actions, 6–8 px corners, 1 px seams, and a stable 2 px amber focus edge.
- Segoe UI hierarchy: truthful title first, quiet state second. Long titles clamp without moving controls.
- Real provider video is the only runtime imagery. The approved comp's city image, values, state, light title bar, and generated icons are nonliteral composition evidence.
- Flutter renders semantic text/controls and `media_kit_video` renders the contain-fit stage; no rasterized UI.

## Constraints and unresolved decisions

- Reference 1265 × 713 plus larger/fullscreen and constrained Windows verification; full mouse, keyboard, and remote parity.
- Current Strong allowance is one connection, so every opening/retry disposes the previous session first.
- **Unresolved decisions:** None. The user confirmed the brief and composition A on 2026-08-17.

## Verification state

- **Implemented:** 2026-08-17.
- Impeccable critique scored 32/40 before one bounded polish pass; the three accepted findings are closed.
- Generic Flutter native-source audit passed 16/16. Windows packaged synthetic verification passed at the reference, larger/fullscreen, and constrained sizes after correcting fullscreen-from-maximized title-bar behavior.
- Final real Strong production flow passed on 2026-08-17: Live, Movie, and Episode each rendered visible video; VOD controls/timeline were truthful; Escape restored the confirmed browse context; no provider-identifying data or credentials were recorded.
- Forced synthetic failure coverage remains the evidence for retry/recovery because no provider failure was induced during the successful real run. The Phase 1 player gate is closed.
