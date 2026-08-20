---
version: 1
slug: "lib-src-features-playback-player-screen-dart"
primary_target: "lib/src/features/playback/player_screen.dart"
related_targets: ["lib/src/app_shell.dart","lib/src/features/browse/playback_handoff.dart"]
---

# Production Player

## Scope and mode

- **Mode:** Operate
- **Scope:** Production playback for Live, Movie, and Episode handoffs, including essential controls, fullscreen, bounded retry, sanitized recovery, progress/resume, real available tracks, Corner Signal, and fixed two-stream Live Multi-view.
- **Boundary:** No detached PiP, freely resizable PiP, 2×2 or mixed-media Multi-view, fuzzy/title-derived variants, zapping, next episode, or simultaneous mixed audio.

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
- Eligible Movie/Episode playback automatically resumes after 30 seconds watched when at least 60 seconds remains; Start over remains explicit, and near-finished items restart. Tracks opens one focus-trapped deck ledger with truthful available audio/subtitle choices.
- PiP moves the active session into the 320 px (256 px constrained) Corner Signal across the six content destinations. Live Add channel reuses the Live directory, admits a second session before transport creation, and opens equal side-by-side Multi-view with one shared deck and one audible tile.
- Starting is bounded to twenty seconds for a first usable frame. A failed transport is disposed, retried once quietly, then replaced by redacted Retry/Back or Open Settings recovery with collapsed sanitized details.
- Phase 1 replacement/retry keeps one transport; admitted Phase 5 Live Multi-view may own exactly two sessions. Credentials and final stream URIs exist only inside active sessions and never reach diagnostics or logs.

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
- **Phase 5 verified state — 2026-08-19:** schema v11 progress, resume/Start over, tracks, admission, Corner Signal, stop-confirmation, equal Live Multi-view, audio transfer, and collapse are implemented. Format/analyze/diff checks pass, the serial suite is 469/469, Debug and Release build, eleven renders plus the targeted constrained recapture were inspected, independent Impeccable reports PASS, and the native-source audit passes 16/16. The user then reported `Ok pass` after the packaged Strong/Windows checklist. Strong's one-stream allowance correctly blocked the second open, so actual two-stream success was not exercised and no resource or available-track value was recorded.
