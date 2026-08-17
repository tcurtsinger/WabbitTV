# Shape Brief — Phase 0 Strong Playback Probe

**Status:** Verified  
**Phase:** 0 — Direction and Feasibility  
**Confirmed:** 2026-08-16  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast from `0-app-shell.md`  

## Job and outcome

Give the maintainer one temporary, local Windows probe for proving the exact media stack against their Strong account without turning the probe into product source setup or player UI. Success means a packaged debug and release target visibly renders one live stream, movie, and episode; records only sanitized evidence; and attempts two simultaneous streams only when the provider reports enough available connections and the maintainer explicitly starts it.

## Scope and boundary

- Separate Phase 0 Flutter entrypoint; no route or control is added to the ordinary Wabbit application.
- Local memory-only Strong endpoint, username, and obscured password entry.
- One bounded Xtream account-info request and deliberately small provider discovery/selection flow.
- Sequential live, movie, and episode render checks with one player/controller at a time.
- A real mounted video texture, nonzero dimensions, a nonempty in-memory screenshot check, and a short visible observation.
- Sanitized result summary: media kind, pass/fail class, startup time, dimensions, screenshot-present, reported connection limit/active count, and two-stream skipped/attempted result.
- Optional two-tile technical render only when known available connections are at least two and the user explicitly starts it.
- Excludes saved sources/credentials, catalog import, favorites/groups, player controls, playback history, production retry logic, DRM, PiP, multiview product UI, or reusable playback architecture.

## Proposed flow

1. **Credentials:** one compact Quiet Broadcast panel explains that values remain in memory and are never logged or saved. Password is obscured; Paste works; fields clear when the probe closes.
2. **Account check:** one explicit Continue action performs a 10-second, no-retry `player_api.php` request and shows only authentication status, reported maximum connections, and active connections.
3. **Representative selection:** the probe makes bounded provider discovery calls and presents a small local list for choosing one live channel, one movie, and one episode. It does not persist or import the catalog.
4. **Sequential proof:** each chosen item gets one visible 16:9 stage with no product controls. The probe allows 20 seconds to obtain nonzero video dimensions and a nonempty in-memory screenshot, then holds the moving image for five seconds before disposal and the next item.
5. **Two-stream admission:** only when reported available connections are at least two, show a separate explicit Run two-stream test action. It mounts two muted tiles for ten seconds; otherwise the summary records a skip.
6. **Results:** one quiet summary shows only sanitized facts and can be copied without URLs, IDs, titles, credentials, raw provider responses, or raw media-engine errors.

## Interaction and safety contract

- Full mouse/keyboard operation; predictable Tab order; Enter activates the focused primary action; Escape never silently starts or repeats a provider call.
- No automatic retries. Each probe action is explicit and bounded.
- Credentials, stream IDs/URLs, provider titles, raw JSON, and raw media errors stay in memory and never enter logs, screenshots, committed fixtures, or durable evidence.
- Players are muted and disposed in `finally`; sequential checks release one connection before the next begins.
- Missing/malformed connection data is treated as one connection and skips the two-stream test.

## Visual contract

- Inherit graphite, warm-white, signal-amber focus, 6–8 px corners, Segoe UI, and short functional motion from Quiet Broadcast.
- This is a diagnostic instrument, not a new Wabbit destination: one centered task column, one video stage, and a restrained facts panel.
- No promotional art, rabbit decoration, glass, gradients, hero treatment, or production player chrome.

## Confirmation questions

1. Confirm local memory-only credential entry in the standalone probe window rather than environment variables or a product source form.
2. Confirm bounded provider discovery with a small local picker rather than requiring manual Strong stream IDs.
3. Confirm the two-stream check is never automatic and appears only when the reported available allowance is at least two.

**Confirmed defaults:** all three were confirmed by the user on 2026-08-16.

## Approved composition

**B — Split Console** was approved by the user on 2026-08-16 for minimal implementation. The left task console keeps account/selection/run controls explicit while the right side proves the mounted video texture and sanitized evidence. Fidelity is bounded by the probe's temporary purpose: reproduce the hierarchy and operational clarity without turning the spike into production UI or a reusable design system.

- Approved comp: `.impeccable/mocks/quiet-broadcast-playback-probe-b-split-console.png`
- Approval record: `.impeccable/mocks/quiet-broadcast-playback-probe-b-split-console.json`

## Acceptance evidence

- Windows debug and release probe targets build with the documented media-kit package set.
- The maintainer enters credentials locally; no secret appears in repository files, shell command history, screenshots, or captured logs.
- Live, movie, and episode each visibly render or produce one sanitized bounded failure class.
- Connection limit/active count and two-stream skip/attempt result are recorded without provider identity or credentials.
- Independent review confirms the probe did not create product source setup, player controls, or future-phase architecture.

## Implementation checkpoint

The separate target, package bundle, bounded category-first provider client, mounted video stage, sanitized evidence model, connection admission, and keyboard-operable Split Console were implemented and passed static, widget, Windows debug/release build, real-window, and independent finish review on 2026-08-16. The maintainer-local Strong run then verified live, movie, and episode rendering with screenshot evidence. The account reported maximum connections 1 and active connections 0, so sequential checks ran and the two-stream test correctly remained skipped. Sanitized results are recorded in `docs/evidence/phase0-strong-playback-probe.md`.
