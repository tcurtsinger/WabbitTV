# Left sidebar polish render evidence

**Evidence status:** Automated, independent-review, synthetic-render, Windows-package, and packaged user-acceptance checkpoints pass.

## Decision and correction

The user authorized all five findings from the bounded left-sidebar critique, selected remote/accessibility correctness rather than a visual-only pass, and selected Settings bottom-anchored behind a restrained separator. The initial independent critique reported five priority gaps:

1. the documented remote Menu route was absent;
2. the collapsed resting selected state did not carry enough structural location truth;
3. high-text and television-distance behavior was incomplete;
4. expanded destinations could produce duplicate accessibility announcements; and
5. pointer hover/cursor and the content-versus-utility hierarchy were under-articulated.

All five were corrected without redesigning Quiet Broadcast. The shell-level remote Menu route opens navigation only when no contextual surface owns the key, preserving My Library Organize. A persistent 2 px non-amber marker distinguishes selected location from the amber focus boundary. Rows are 48 px minimum, wrap complete labels, scroll at constrained height, and reveal the focused destination at 1.5x/2x text. Destinations and Now Playing expose one authoritative semantic button/name. Quiet per-row hover and the click cursor provide pointer truth; Settings occupies the separated bottom utility seam, and the passive playmark uses quiet text rather than amber.

Final independent review reports **PASS** with no remaining P0/P1/P2 findings.

## Evidence boundary

These PNGs are deterministic Flutter widget renders of the production `WabbitShell` left sidebar. The ignored harness at `build/verification/sidebar_polish_render_test.dart` uses the populated in-memory Home fixture plus injected no-I/O source, catalog, search, library, Guide, credential, artwork, and playback seams.

The capture does not launch the packaged app, open a database, read a credential store, contact a provider, start playback, or make a network request. Fixture names and artwork are synthetic. This evidence confirms only the recorded Flutter composition and interaction states; it is not packaged-Windows, provider, performance, or remote-control hardware proof.

## Captures

| File | Dimensions | Bytes | State shown | SHA-256 |
| --- | ---: | ---: | --- | --- |
| `collapsed-1265x713.png` | 1265 x 713 | 74,373 | Collapsed 72 px sidebar with Home selected, the persistent location marker, icon destinations, and Settings at the bottom seam | `deca338eda0fb00f11395cc77b5c5ae434f49359f01cd65f7ee4eeb920ea0407` |
| `expanded-selected-home-focused-movies.png` | 1265 x 713 | 68,452 | Expanded sidebar with Home still selected while Movies holds the distinct amber keyboard/remote focus boundary | `bd6ca08731e8e64c83f3df8e0ab7d04912bfe8f0a28a8faf8696b8d324ab129a` |
| `pointer-hover-live-1265x713.png` | 1265 x 713 | 70,452 | Pointer-expanded sidebar with a quiet raised hover surface on Live and the selected Home marker retained | `48183e572e7b66b55a5bab18a13d48022c8157c63b1b589277e1b08a7d47e312` |
| `constrained-600x713-text-2x.png` | 600 x 713 | 46,778 | Constrained 600 px shell at 2x text with readable wrapped brand/library labels and a fully visible My Library focus target | `639c9f31e218370bd53e64414fb66cd6cc7d1f91db5564d246e795d710fdd80a` |

## Verification

- Harness: `build/verification/sidebar_polish_render_test.dart` (ignored build-only evidence code).
- Capture command: `flutter test build/verification/sidebar_polish_render_test.dart --update-goldens --reporter expanded` — **PASS, 4/4**.
- Determinism command: `flutter test build/verification/sidebar_polish_render_test.dart --reporter expanded` — **PASS, 4/4**.
- Repository checkpoint: formatting checked **100 files with 0 changes**; `flutter analyze --no-pub` is clean; the full serial suite passes **587/587 in 81.055 seconds**; scoped diff-check passes.
- Independent review: initial findings were corrected and final review reports **PASS** with no remaining P0/P1/P2 findings.
- Windows packages: Debug completed in **46.187 seconds** at `build/windows/x64/runner/Debug/wabbit_tv.exe` (1,140,736 bytes; 2026-08-20 10:36:58.778 -05:00; SHA-256 `41CA311CF6D1DE92A5FA16B45E1E1B5A817B09F80C3945071E0E2639AB529919`). Release completed in **47.954 seconds** at `build/windows/x64/runner/Release/wabbit_tv.exe` (183,296 bytes; 2026-08-20 10:38:04.592 -05:00; SHA-256 `411B7E51BEA6779EFF51A5E3C97356066B59B142D6FC2479986A7F25A2603E1B`). Both target `lib/main.dart` with no custom WABBIT defines.
- Capture path: Flutter's golden matcher against a keyed production-shell `RepaintBoundary`.
- Fonts/icons: Windows Segoe UI (`C:\Windows\Fonts\segoeui.ttf`) and Flutter Material Icons are loaded explicitly before capture.
- Dimensions: every generated PNG was decoded; the three reference captures are exactly 1265 x 713 and the constrained capture is exactly 600 x 713.
- Integrity: SHA-256 and byte-for-byte comparison match each tracked PNG to its generated golden.
- Visual inspection: the four states were inspected together and the pointer/high-text states were inspected at full size. No overflow, clipped focused target, missing selected marker, confused selected/focused state, broken label wrapping, raw locator, credential, or unintended provider content was found.
- Process hygiene: both Flutter test runs exited normally; no provider, network, credential, database, playback, packaged-app, or real-window process was started by the harness.

## What the evidence establishes

- Collapsed navigation remains compact while retaining selected-location truth.
- Expanded navigation distinguishes the current destination from a different focused destination.
- Pointer hover has a visible but restrained state independent of selection and focus.
- The sidebar remains scrollable and usable under constrained width and 2x Windows text scaling without changing its Quiet Broadcast hierarchy.

The Home content behind the expanded sidebar is intentionally occluded: the sidebar is an overlay so hover/focus expansion does not reflow the active content surface.

## Packaged acceptance

After the corrected Release and the evidence above were presented, the user replied exactly `Approved`. This closes the packaged left-sidebar polish checkpoint. The concise acceptance provides no additional timings, screenshots, or step-level interaction evidence beyond the verified artifacts already recorded here.

The synthetic captures and successful packages do not prove packaged pointer, keyboard, remote, or accessibility behavior on the user's workstation. That user acceptance remains the next open gate.
