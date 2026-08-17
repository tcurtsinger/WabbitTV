---
target: Phase 1 production player
total_score: 32
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 1
timestamp: 2026-08-17T15-27-27Z
slug: lib-src-features-playback-player-screen-dart
---
Method: dual-agent (A: /root/phase1_player_critique_a · B: /root/phase1_player_critique_b)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|------:|-----------|
| 1 | Visibility of System Status | 3 | Starting, buffering, media kind, play/pause, and failure are visible; recovery focus is not yet authored. |
| 2 | Match System / Real World | 4 | Familiar transport, volume, timeline, Back, and fullscreen behavior. |
| 3 | User Control and Freedom | 3 | Fullscreen-first Back and retry are clear; recovery does not initially focus its primary action. |
| 4 | Consistency and Standards | 3 | Main deck uses Quiet Broadcast focus; recovery falls back to stock Material focus treatment. |
| 5 | Error Prevention | 4 | Bounded startup, one quiet retry, single-session teardown, and sanitized diagnostics. |
| 6 | Recognition Rather Than Recall | 3 | Standard player icons work, though the reveal model has no lightweight cue. |
| 7 | Flexibility and Efficiency | 3 | Mouse, keyboard, and remote paths exist; ordinary action traversal relies on framework spatial order. |
| 8 | Aesthetic and Minimalist Design | 3 | Calm and sparse, but wide transport alignment and the framed status mark weaken composition A. |
| 9 | Error Recovery | 3 | Retry/Back/Settings and collapsed safe details are useful; visual/focus grammar needs closure. |
| 10 | Help and Documentation | 3 | Labels and diagnostics are semantic and plain; the hidden-chrome reveal model is learned by use. |
| **Total** | | **32/40** | **Good — one layout correction and a bounded state polish pass** |

## Design Specificity Verdict

**LLM assessment:** The player is recognizably Wabbit TV: full-client video, restrained graphite structure, warm-white hierarchy, amber-only focus, Live/VOD truth, and redacted recovery all belong to Quiet Broadcast. It is not a generic storefront. The largest specificity loss is geometric: at wide widths the source places the transport cluster at the far left and audio/fullscreen at the far right, while approved composition A deliberately centers the primary transport cluster and treats the right edge as a separate utility zone.

**Deterministic scan:** The installed detector returned `[]`: zero findings, zero rule hits, and no false positives for `lib/src/features/playback/player_screen.dart`.

**Visual overlays:** Not applicable. This is a native Flutter surface rather than browser markup, so no browser overlay or live server was started. The approved composition and source were inspected; a packaged Windows render remains a separate verification gate.

## Overall Impression

The viewing surface is calm, credible, and disciplined. Its biggest opportunity is not decoration: it is to make the Broadcast Deck's wide geometry match the approved composition, then make loading and recovery feel like the same authored system rather than generic Material fallbacks.

## What's Working

1. **The player yields to content.** Video owns the client area; the rail disappears; chrome is edge-attached and transient.
2. **State truth is strong.** Live never shows a fake timeline, VOD gets real position/duration, startup is bounded, retry is finite, and diagnostics never expose provider identifiers or credentials.
3. **The visual restraint is coherent.** Graphite, warm white, one amber focus signal, 44 px controls, 6 px corners, and thin seams avoid gradients, glass, glow, pills, and provider branding.

## Priority Issues

### [P1] Wide deck geometry drifts from approved composition A

**Why it matters:** On the primary 1265 px-and-larger Windows scene, the seek/play cluster begins at the left edge instead of acting as the centered visual anchor shown in the approved Broadcast Deck. The revealed controls read as a responsive toolbar rather than the chosen broadcast console.

**Fix:** Use an explicit three-zone wide layout: a balancing left zone, centered primary transport cluster, and right-aligned mute/volume/fullscreen utilities. Preserve the current compact single-row fallback at constrained width.

**Suggested command:** `$impeccable layout lib/src/features/playback/player_screen.dart`

### [P2] Recovery does not inherit the deck's exact focus grammar

**Why it matters:** Retry/Open Settings, Back, and Technical details are most important when confidence is lowest, but they rely on stock Material focus instead of the player's crisp 2 px amber edge and do not explicitly focus the primary recovery action.

**Fix:** Give recovery actions the same square 6 px, 44 px-class, amber-focus treatment and move focus to the primary action when terminal failure appears. Keep technical details subordinate and collapsed.

**Suggested command:** `$impeccable harden lib/src/features/playback/player_screen.dart`

### [P2] Starting and buffering use a floating framed box

**Why it matters:** `_StatusMark` reads as a small card floating over video, while the confirmed player brief explicitly chooses edge-attached broadcast signals and rejects cards.

**Fix:** Distill the status into an edge-free compact mark plus warm-white label over the graphite/video stage. Do not add a spinner framework or decorative animation.

**Suggested command:** `$impeccable distill lib/src/features/playback/player_screen.dart`

## Persona Red Flags

**Maintainer power user:** Wide transport placement breaks centered-control muscle memory and increases eye travel. Recovery focus is not deterministic enough for fast keyboard use.

**Couch remote household:** The happy-path deck has a strong amber focus edge, but terminal recovery does not visibly promise the same directional certainty. A centered transport cluster would make the immediate action easier to locate from a distance.

**First-timer:** The loading/failure language is plain and safe, but the framed status mark and stock recovery controls feel like separate systems rather than one dependable player.

## Minor Observations

- The 480 × 713 widget regression proves no framework overflow and the full control set remains present; no additional responsive breakpoint is justified without a measured smaller Windows requirement.
- The 12 px label role matches the recorded design system, so increasing type globally would contradict current authority without real-window evidence.
- The approved composition intentionally uses icon-only standard transport controls; tooltips may be useful for pointer users, but visible text labels are not required before runtime evidence shows confusion.
- The proposed paused-chrome exception is not part of the confirmed contract: the user explicitly chose four-second hiding whenever no control has focus.

## Questions to Consider

1. Does the primary transport cluster read instantly from eight feet away when it is centered as approved?
2. Can recovery feel like the same dependable Broadcast Deck without making failure visually loud?
3. Is the smallest possible loading signal enough to communicate progress without becoming another card?

Questions skipped: the approved composition and confirmed Shape make the three corrections deterministic; no new product decision is needed.
