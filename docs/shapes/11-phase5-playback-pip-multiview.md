# Shape Brief — Phase 5 Playback, PiP, and Multiview

**Status:** Verified — user-supplied packaged Strong/Windows PASS  
**Phase:** 5 — Playback, PiP, and Multiview  
**Confirmed:** 2026-08-19  
**Implemented:** 2026-08-19  
**Verified:** 2026-08-19  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast  
**Selected resume behavior:** A — Automatically resume, with Start over available  
**Selected PiP composition:** A — Corner Signal  
**Selected multiview composition:** A — Add channel from the active Live player

## Job and outcome

A Windows desk or couch viewer needs playback to retain useful progress, expose real media tracks, continue in a quiet in-app overlay while browsing, and intentionally combine two permitted Live streams without losing the verified Broadcast Deck behavior. Success means resume and recovery are truthful, PiP remains predictable across the app, multiview never exceeds the effective connection limit, and every transition preserves understandable focus and return behavior.

## Resume behavior

- Movies and episodes automatically resume after 30 seconds watched when at least 60 seconds remains.
- `Start over` remains available so the viewer can deliberately restart from zero.
- Near-finished items restart next time rather than resuming into the final seconds.
- Resume applies to Movies and Episodes only. Live playback never presents a fake resume position.

## Tracks and recovery

- Audio and subtitle selection use a deck-attached Tracks ledger that extends the established Broadcast Deck rather than introducing a separate player theme.
- Playback receives one quiet retry before showing redacted recovery actions.
- Recovery offers `Retry`, `Back`, and `Settings` as applicable without exposing credentials, raw locators, provider responses, or media-engine detail.
- There is no fuzzy, title-derived, or merged source-variant recovery. An exact pre-existing variant may be offered only when that identity already genuinely exists; Phase 5 does not create matching or merging behavior.

## Connection admission

- The effective concurrent-stream limit is resolved in this order: local override, provider-reported limit, then a conservative default of one.
- Settings exposes `Automatic`, `1`, or `2` for the local connection-limit choice.
- A blocked playback or multiview request creates no transport. Admission is decided before opening another stream.
- Strong's reported one-stream limit must therefore block a second stream before any second transport is created.

## Corner Signal PiP

- **A — Corner Signal** is the selected in-app PiP composition.
- The active 16:9 playback surface may move among four fixed corners while the viewer browses Home, Live, Movies, Series, Search, or My Library.
- Remote-accessible actions are `Return`, `Move corner`, and `Close`; mouse and keyboard expose the same actions.
- Entering Settings or a management surface while PiP is active asks `Stop playback and continue?` rather than carrying playback into a sensitive or administratively dense surface.
- PiP is an in-app overlay only. It is not a detached operating-system window and is not freely resized.

## Two-stream Live multiview

- **A — Add channel from the active Live player** is the selected multiview composition.
- From an active Live player, `Add channel` moves the first stream into the PiP state while the existing Live directory selects the second stream.
- After admission, the result is an equal side-by-side two-up layout with one shared deck.
- Exactly one tile is audible. Selecting the other tile transfers audio focus; simultaneous mixed audio is never presented.
- Back collapses multiview to the original Live stream.
- Multiview is Live-only and fixed at two streams. It never combines Live with Movie or Episode playback.

## Interaction and focus contract

- The verified Broadcast Deck remains the full-player foundation. Phase 5 extends its deck and transitions without replacing its control grammar, redaction boundary, or focus edge.
- Resume, Start over, Tracks, PiP, Add channel, tile-audio transfer, collapse, and stop-confirmation actions are reachable by mouse, physical keyboard, and remote-style traversal.
- Opening a ledger or confirmation traps focus only within that transient surface. Back/Escape dismisses the topmost transient state first.
- Returning from PiP or multiview restores the practical originating player or directory target rather than resetting the destination.
- Pending admission, transport replacement, retry, or collapse blocks repeated conflicting submission and does not leave an abandoned transport.

## State and persistence contract

- Persist only local playback progress and the minimum local preferences needed for the confirmed behavior. Progress is keyed to the existing stable library identity and survives restart and provider refresh without merging identities.
- Progress is recorded from truthful playback state, not merely from opening a player.
- Cover fresh playback, eligible resume, Start over, near-finished restart, track availability and absence, quiet retry, redacted terminal failure, PiP transition and stop confirmation, one-stream admission block, two-stream success, tile audio transfer, and collapse.
- A failed second-stream opening leaves the original Live stream usable and audible.
- No provider credential, URL, endpoint, raw locator, provider response, or unsanitized engine error enters persistence, logs, screenshots, or diagnostics.

## Responsive and performance rules

- The ordinary verification viewport remains 1265 × 713, with constrained Windows, fullscreen, and TV-distance use also required.
- Corner Signal keeps a fixed 16:9 footprint, avoids covering the active navigation target when moved among its four positions, and does not trigger a storefront or phone-layout conversion.
- Two-up multiview gives both Live streams equal visual weight and retains one compact shared deck without stacking independent control surfaces.
- Stream admission and transport lifecycle remain bounded. No blocked request allocates a decoder or network transport.
- Real Windows evidence records CPU, memory, decoder behavior, startup, transition latency, and stability for ordinary playback, PiP, and genuinely permitted two-stream multiview.

## Hard boundaries

- No detached-window PiP.
- No freely resizable PiP.
- No 2×2 or larger multiview.
- No mixed Live/VOD multiview.
- No automatic or manual merging, fuzzy matching, or title-derived variant failover.
- No casting, transcoding, downloads, DVR, telemetry, or recommendation behavior.

## Evidence and acceptance

- Focused persistence and player tests cover the resume thresholds, Start over, near-finished restart, track selection, one quiet retry, redaction, exact identity separation, and restart persistence.
- Shell and widget tests cover mouse/keyboard/remote parity, Corner Signal movement and controls across the six allowed destinations, Settings/management stop confirmation, focus trapping/restoration, stale completions, and transport disposal ordering.
- Admission tests prove local override → provider report → conservative-one precedence and prove a blocked second request creates no transport.
- Multiview tests cover active-Live add flow, equal two-up layout, one audible tile, explicit audio transfer, failed second-stream preservation, and Back collapse to the original stream.
- Actual Flutter renders cover eligible resume, Tracks, Corner Signal in ordinary and constrained browsing, stop confirmation, admission block, and equal two-up multiview.
- Independent Impeccable critique and generic Flutter native-source audit close with no unresolved material issue before packaged Windows verification.
- Packaged verification covers resume after restart, Start over, track selection where real tracks exist, PiP navigation and return, redacted failure recovery, and connection admission.
- Strong's reported one-stream limit must visibly block stream two before opening it. Real two-stream proof requires a source that actually permits two concurrent streams; synthetic evidence does not stand in for that provider proof.

## Implementation checkpoint

- Schema v11 persists Movie/Episode progress against stable library identities and implements the confirmed eligible-resume, Start over, and near-finished restart thresholds.
- One production `PlaybackManager` owns active sessions, selected audio, one quiet retry, real available track selection, and admission precedence. Blocked admission creates no transport.
- The Broadcast Deck, Corner Signal, stop confirmation, existing Live-directory second-channel flow, equal side-by-side Multi-view, shared deck, audio transfer, Back collapse, and source-level Automatic/1/2 control are implemented within the confirmed boundaries.
- Format, `flutter analyze --no-pub`, and `git diff --check` are clean. The serial suite passes 469/469; Windows Debug and Release builds pass.
- Eleven synthetic actual-Flutter render cases and the targeted corrected constrained Multi-view recapture pass and were inspected. Independent Impeccable review reports PASS; the generic Flutter native-source audit passes 16/16.
- The user accepted the packaged Strong/Windows checklist with `Ok pass` on 2026-08-19. Strong reports one concurrent stream, so the correct real-provider Multi-view evidence is the pre-open second-stream block; actual two-stream success was not exercised and remains conditionally unavailable without a genuinely permitted source. No provider titles, timings, CPU/memory values, decoder details, available-track result, or two-stream success were recorded or inferred.

## Packaged acceptance record

The packaged Phase 5 gate is complete by explicit user acceptance of the bounded Strong/Windows checklist. This does not convert synthetic/local two-session tests into provider proof, does not turn the unsupported lavfi attempt into a resource measurement, and does not claim that Strong permits two streams. The confirmed behavior remains admission-aware: a one-stream source must block the second open, while successful two-stream playback is available only when a source genuinely permits it.

## Composition translation boundary

The selected compositions are textual interaction and hierarchy contracts; no generated mock is required to authorize implementation. Existing approved Broadcast Deck and Quiet Broadcast visual language remains the north star. Runtime titles, tracks, progress, source limits, and media come only from truthful local/player/provider state. The shape does not authorize merged titles, synthetic provider capabilities, or demonstration media in the product.

## Confirmation record

The user selected **1A — Automatically resume, with Start over available**, **2A — Corner Signal**, and **3A — Add channel from the active Live player**. The user confirmed the complete Phase 5 shape on 2026-08-19.

## Phase 6 confirmed extension — not yet implemented

The user confirmed `docs/shapes/12-phase6-xtream-live-guide-startup.md` on 2026-08-19. That later Shape permits Corner Signal over Guide as a seventh content destination while retaining this Shape's fixed-corner controls, collision avoidance, session reuse, and stop-confirmation before Settings/management. Confirmation is not implementation or playback evidence.
