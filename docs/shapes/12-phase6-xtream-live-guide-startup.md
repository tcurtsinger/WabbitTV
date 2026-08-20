# Shape Brief — Phase 6 Xtream Live Guide and Startup

**Status:** Complete — implemented and bounded-verified; corrected packaged Strong Guide behavior, representative M3U URL/local-file readiness, final daily-driver acceptance, and Windows V1 passed
**Phase:** 6 — Windows Daily-Driver and Xtream Live Guide Gate  
**Confirmed:** 2026-08-19  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast  
**Selected Guide composition:** A — dedicated Guide rail destination with a classic channel-by-time matrix  
**Selected Guide scope:** A — one enabled Xtream source and one visible provider category at a time, including `All Live`  
**Selected Last channel behavior:** A — automatically play the exact last usable Live channel, with a truthful Home fallback  

## Job and outcome

A Windows desk or couch viewer needs to see what is on now, what comes next, and the immediate upcoming schedule without searching a very large provider catalog or leaving the existing playback flow. The same viewer also needs Wabbit to open predictably at Home, the previous stable screen, or the exact last successfully viewed Live channel.

Success means an enabled Xtream source can expose truthful Now/Next and a simple remote-friendly timeline without slowing or destabilizing catalog use. Guide absence, malformed provider data, or refresh failure never blocks Live browsing or playback. Startup honors the selected target without reopening a transient state, inventing a channel match, or hiding a failure.

## Scope and hard boundaries

### Included

- A dedicated `Guide` destination immediately after `Live` in the existing navigation rail.
- A classic channel-by-time matrix for one enabled Xtream source and one visible source-local Live category at a time; `All Live` remains an available category.
- Quiet Now/Next metadata on existing Live rows when exact locally cached program data exists.
- Lazy, bounded Xtream `get_short_epg` acquisition through the configured source, with a local last-good cache keyed to exact source and provider channel identity.
- Startup choices `Home`, `Previous screen`, and `Last channel` in one app-level `General` Settings entry.
- Corner Signal over Guide as another content destination, with the existing stop-confirmation still required before Settings and management.

### Excluded

- M3U XMLTV URL/file input, M3U guide matching, M3U guide claims, or any generic XMLTV configuration.
- Xtream full-guide/XMLTV bulk download when bounded `get_short_epg` can serve the confirmed surface.
- Fuzzy channel-name matching, title-derived matching, cross-source merging, automatic merging, or manual merging.
- Recording, DVR, timeshift, catch-up playback, reminders, notifications, archival behavior, recommendations, or program search.
- A program-details page, synopsis-led card surface, date picker, multi-day calendar, favorite-only guide mode, arbitrary guide customization, or a second guide composition.
- Detached PiP, additional multiview layouts, future-platform work, or a visual redesign.

## Selected hierarchy and composition

Quiet Broadcast remains fixed: graphite structure, warm-white hierarchy, quiet metadata, signal amber only for focus/selection/immediate action, Segoe UI, crisp 6–8 px geometry, and no promotional guide styling.

The Guide header carries the `Guide` title, truthful local date/time context, one Xtream source selector, one source-local category selector, and a quiet `Go to now` action only when the visible time window has moved away from the present. M3U sources do not appear in the Guide source selector. When no enabled Xtream source exists, the surface explains the Xtream-only boundary and offers direct paths to Live or Settings.

The dominant plane is a classic matrix:

- a fixed, compact, focusable channel column on the left;
- a horizontally scrollable time ruler and exact-duration program blocks on the right;
- bounded vertical channel virtualization and a bounded cached time range rather than eager construction of the source catalog;
- a restrained focus-context line that exposes the complete channel, program title, and local start/end time when a grid cell truncates.

The matrix is a tuning surface, not a future-program action surface. Enter/Select on a channel or any of its program blocks starts that exact Live channel through the existing playback handoff. It never attempts catch-up, scheduling, recording, or reminders.

Live browse retains its compact directory grammar. When exact cached schedule data exists, a row may add one quiet secondary line for the current and next programs and their local times. Channel title and artwork remain primary. Missing guide data does not create fake titles or turn the ledger into a taller card feed.

Settings adds one fixed `General` entry outside the source directory rows. Its startup control offers exactly `Home`, `Previous screen`, and `Last channel`; an application preference is never placed inside a selected-source ledger.

## Guide scope, visibility, and identity

- The Guide always addresses one enabled Xtream source at a time. Its category selector contains `All Live` plus that source's currently visible provider categories. Provider category trees are never fused.
- Hidden categories and individually hidden channels remain absent from both the matrix and Live-row Now/Next presentation. A source/category removal or visibility change falls back to the nearest valid source, `All Live`, and first viable channel without retaining detached focus.
- Programs are associated only by the exact configured source and provider channel identifier used by the Xtream request and local catalog identity. Equal channel or program titles do not imply identity.
- Guide source/category/time position and last viable focus are remembered independently from ordinary Live browse while the application is running. Returning from playback restores that exact practical Guide context.

## Lazy bounded `get_short_epg` contract

- Wabbit requests short EPG only for the bounded mounted/near-visible channel window needed by Live Now/Next or the selected Guide category. It does not request every channel in a Strong-scale catalog up front.
- One shared coordinator owns a small fixed concurrency cap, coalesces duplicate source/channel requests, cancels or declines obsolete queued work after rapid navigation, and prevents mounted rows from independently creating unbounded network work.
- Each request uses an exact Xtream stream identifier and a finite program limit sufficient for Now/Next plus the immediate upcoming timeline. This phase does not build a multi-day guide downloader.
- Credential-bearing request construction stays inside the existing credential/source boundary. Credentials, endpoints, raw request URLs, provider payloads, and program locators never enter ordinary logs, diagnostics, committed fixtures, screenshots, or UI errors.
- Parsed programs are committed source/channel-locally as last-good data. A failed or malformed request cannot erase usable cached programs for other channels or change catalog refresh state.
- Expired entries are pruned or ignored by bounded local queries. Cache refresh is driven by staleness and visible need; it does not use an unbounded polling loop.
- Live rows and the Guide render from local cache state. The UI may enqueue work through the shared coordinator, but it never waits synchronously on a provider request to remain navigable or playable.

## Time and truth contract

- Persist and compare program instants in UTC. Render dates and times in the current Windows local timezone.
- Prefer explicit provider epoch or offset-bearing time evidence. If a start/end time is invalid, reversed, unreasonably unbounded, or cannot be interpreted without guessing, skip that program rather than synthesizing a schedule.
- Local timezone and daylight-saving changes affect presentation, not stored identity or UTC instants. Reopening or rebuilding the visible guide recalculates local labels.
- `Now` is derived from the current instant falling within a valid start/end interval. `Next` is the next valid program for the same exact channel. A gap remains a truthful gap.
- The current-time marker is informational and restrained; the amber focus edge remains the dominant interaction signal.

## Interaction, focus, and Back/Escape

- First Guide entry focuses the current program of the first viable channel when available, otherwise the first viable channel. Later entry restores the last viable source, category, time window, channel, and program focus.
- In the fixed channel column, Up/Down changes channels, Right enters the closest current/upcoming program, Enter/Select tunes the channel, and Left reaches the rail.
- In the program grid, Left/Right moves to the previous/next program for the same channel; Up/Down moves to the nearest overlapping program or channel target in the adjacent row. Focus movement scrolls the bounded matrix only enough to keep the target visible.
- Up from the first visible channel/program row reaches the appropriate header controls; Down returns to the remembered matrix target. Mouse click and wheel/scroll access are equal conveniences, never the only route.
- Back/Escape dismisses the topmost source/category menu or transient Guide state first, then follows the established shell rule to open the rail. Leaving the rail restores the last viable Guide target.
- Returning from full playback restores the exact Guide context. Corner Signal may remain over Guide and follows existing collision avoidance, move, mute, restore, and close behavior.
- Every program and channel target has a complete semantic label including channel, program title when present, local time range, and whether it is current or upcoming. Long/Unicode labels clamp visually without losing their accessible names.

## Startup behavior

- `Home` opens Home.
- `Previous screen` restores only the last stable top-level destination, including Guide. It never restores a player, PiP, multiview, confirmation, menu, organizer, source editor, visibility ledger, or other transient continuation.
- `Last channel` is recorded only after an exact Live handoff produces usable video. Merely focusing, selecting, or unsuccessfully opening a channel never replaces it.
- When `Last channel` is selected, startup automatically opens that exact usable Live identity in the existing full player. No title search, fallback variant, or fuzzy replacement is permitted.
- If that exact local identity is missing, unavailable, disabled, or hidden, Wabbit opens Home and presents one quiet, nonblocking notice that the last channel is unavailable.
- If the exact identity resolves but transport startup fails, the existing redacted player recovery remains authoritative; Wabbit does not disguise a playback failure as a successful Home fallback.
- A missing/corrupt startup preference or local-settings read failure defaults safely to Home. Startup must not briefly expose and focus the wrong destination before redirecting.

## States and recovery

1. **Preparing first local Guide view:** preserve matrix geometry with bounded skeletons or a restrained preparing state; Live browsing and playback remain available.
2. **No enabled Xtream source:** explain that Guide supports configured Xtream sources and offer `Browse Live` and `Open Settings` without exposing M3U guide controls.
3. **Xtream source exposes no guide data:** keep visible channels tunable and state `No schedule available` without claiming a provider error.
4. **Partial or channel-specific gaps:** render valid cached blocks and truthful gaps independently; one missing channel does not replace the entire Guide.
5. **Refresh/request failure with relevant last-good data:** show saved schedule with a concise `Guide update failed · showing saved schedule` status and bounded Retry.
6. **Expired last-good data:** stop presenting it as current; show schedule unavailable while channel tuning, Live browse, and catalog refresh remain usable.
7. **Malformed program/title/time data:** skip or safely normalize only the invalid field/entry; never show raw provider payload, decode errors, credentials, or URLs.
8. **Local cache read failure:** show a redacted Guide-only retry state. Do not convert it into a catalog/source failure.
9. **Source/category/visibility change while open:** select the nearest valid scope and restore a viable channel target with a concise accessibility announcement.
10. **Startup target unavailable:** follow the exact Home/recovery rules above and retain a usable initial focus target.

## Responsive and performance rules

- The ordinary verification viewport remains 1265 × 713. Fullscreen/TV use, 600 × 713 constrained Windows width, high text scale, and long/Unicode provider labels are required evidence.
- Wide Guide keeps a compact fixed channel column beside the dominant time grid. Constrained Windows narrows that column and horizontally clips/scrolls the time window; header controls may reflow, but the matrix does not become cards, a phone layout, or a separate agenda composition.
- Program and channel targets retain 44 px-class minimum focus geometry. Short program durations may clip text, but they do not make the only tuning target unusably small; the channel target remains available.
- Strong-scale evidence is approximately 56.7K Live channels across hundreds of categories. Local queries must therefore be source/category/time-window bounded, grid rows virtualized, provider requests lazy and admitted, and response parsing/storage off the UI isolate.
- Now/Next time changes update from cached UTC data without reloading the catalog, rebuilding all Live rows, or polling every program cell.
- Guide work may not delay application startup, catalog refresh completion, channel admission, or playback transport creation.

## Evidence and acceptance

- Database/migration tests cover exact source/channel identity, UTC persistence, cache replacement, expiry/pruning, hidden category/item filtering, restart persistence, and isolation from catalog refresh state.
- Connector/parser tests cover bounded `get_short_epg` requests, finite limits, duplicate coalescing, concurrency admission, cancellation/obsolete work, valid provider time forms, daylight-saving/local rendering, invalid/reversed times, malformed/empty/partial responses, and credential/URL redaction.
- Widget and shell tests cover quiet Live-row Now/Next, source/category menus, `All Live`, matrix arrow traversal, Enter/Select tuning, mouse parity, `Go to now`, Back/Escape, playback return restoration, Corner Signal collision/focus, stale/expired/empty/failure states, and exact focus recovery after source/visibility changes.
- Startup tests cover all three preferences, stable previous-destination restoration, usable-video-only Last channel recording, exact auto-play, unavailable/disabled/hidden fallback, transport recovery, corrupt preference fallback, and no transient-state restoration.
- Actual Flutter evidence covers the ordinary Guide matrix, constrained/high-text matrix, Live Now/Next row, preparing/no-guide/partial/stale states, General startup controls, and last-channel fallback notice. All titles, schedules, sources, and times in committed fixtures are synthetic.
- Packaged Windows verification covers mouse, keyboard, and remote navigation; Live tuning and return; local-time correctness; PiP over Guide; restart behavior for each startup option; and continued catalog/playback usability when guide acquisition fails.
- Real Strong evidence is required only for provider behavior Strong actually exposes. If Strong exposes short EPG, verify truthful Now/Next/timeline and record sanitized timing/resource observations. If it does not, record that absence honestly; synthetic data cannot be relabeled as provider proof.
- The final Phase 6 daily-driver gate separately covered Strong add/refresh/browse/search/organize/play/PiP/admission and representative M3U URL/local-file source/import/browse/playback readiness. No M3U guide behavior is inferred from that acceptance.

## Confirmation record

The user selected the recommended **A/A/A** configuration and explicitly confirmed implementation start on 2026-08-19: dedicated Guide rail plus classic matrix; one Xtream source/category at a time with `All Live`; and automatic exact Last channel startup with truthful Home fallback. This Shape authorizes implementation only inside the boundaries above. It does not mark any Guide, startup, provider, packaged, performance, or Windows V1 evidence as verified.

## Implementation checkpoint — 2026-08-19

The confirmed surface is implemented: schema v12 and exact provider identifiers support a bounded local last-good EPG cache; Xtream `get_short_epg` acquisition is lazy and viewport-bounded; Live rows expose quiet cached Now/Next; Guide provides the source/category matrix and direct tuning; and General Settings provides Home, stable Previous screen, and exact usable-video Last channel with a truthful Home fallback. Missing, unsupported, malformed, stale, or failed guide data remains independent from catalog use and playback. No M3U XMLTV path, fuzzy matching, merging, bulk full-guide acquisition, or other excluded scope was added.

The user's first packaged Strong guide run settled 149 channel states: 148 `empty`, 1 `available`, 0 `error`, and 0 `refreshing`, with 4 cached programs overlapping the Guide window. This proves Strong short EPG works sparsely and the run left no stuck lease; it does not accept the original presentation. The run exposed a real repeated/stuck `Preparing` defect caused by viewport-map replacement and global status derivation, compounded by lifecycle/parser-truth gaps. The corrected tree derives status from only the active viewport, retains a bounded three-view by 40-row LRU (120 IDs), distinguishes malformed responses from valid empty schedules, promptly cancels obsolete generations and releases their leases before replacement claims, lets explicit manual Retry bypass only persisted errors without stealing active leases or bypassing successful/empty TTL, exposes typed local-persistence recovery, and corrects paging, category, and `Go to now` lifecycle behavior.

Formatting checked 100 files with 0 changes, analysis is clean, the full serial suite passes 581/581 in 80.125 seconds, and diff-check passes. Independent closure and the picker correction review report **PASS**. Seven credential-free actual-Flutter states pass 7/7; their evidence and boundaries remain in `docs/evidence/phase6-xtream-live-guide/`.

**Corrected packaged Strong Guide rerun — PASS (user-supplied, 2026-08-19):** After running the corrected Release, the user reported `Ok pass`. At the user-observed level, this closes the repeated/stuck `Preparing`, reverse-scroll, and rapid category/scope packaged behavior. No provider title, timing, screenshot, program-coverage result, resource measurement, or credential was recorded or inferred.

Windows packaging passes with the established process-scoped `$env:TrackFileAccess='false'` workstation workaround. The settled tree produced a cold/default Debug build in 42.132 seconds at `build/windows/x64/runner/Debug/wabbit_tv.exe` (1,140,736 bytes; 2026-08-19 14:22:29.022 -05:00; SHA-256 `77C8EF3FA4884EC9470828BC0D8347C12292D600818D73C1ADE51F1054AFF341`) and a normal/default Release build in 48.068 seconds at `build/windows/x64/runner/Release/wabbit_tv.exe` (183,296 bytes; 2026-08-19 14:23:51.199 -05:00; SHA-256 `D112C13F8FF39927C50A86A0E4CE96F890E99DF1811E120164A81A971BEB2B7F`). Both used `FLUTTER_TARGET=lib/main.dart`; decoded defines contained only standard Flutter metadata and no WABBIT fixture/probe defines. No Flutter, Dart, Wabbit, MSBuild, or compiler process remained.

**Packaged local M3U picker correction — PASS for selection only (2026-08-19):** The user reported that `Choose M3U file` froze the packaged app in Windows `Not Responding` and required Alt+F4. Wabbit performs no playlist read before selection: the picker returns a path, the form retains it, and local-file acquisition begins only after `Connect`. The correction keeps the native owned dialog and adds UI-only single-flight admission, an `endOfFrame` pending-state paint, blocked conflicting actions, redacted retryable error truth, and exact focus restoration. The adapter, plugin, runner, parser, and importer are unchanged; independent review reports **PASS**. In the rebuilt Release, the lead observed the owned dialog and pending state, canceled with Escape to a responsive exact `Choose M3U file` focus, reopened, selected the Downloads test playlist, and saw the field populate. The app closed without importing or adding a source, so this remained a bounded picker-only checkpoint until the later full-flow acceptance.

**Corrected packaged local-file chooser acceptance — PASS (user-supplied, 2026-08-19):** After being asked to retry the corrected local M3U file flow in the new packaged Release, the user replied exactly `Pass`. This narrowly accepted the picker defect correction and corrected chooser flow at that checkpoint; no steps, timing, screenshot, or import/browse/playback result was inferred from the one-word response.

**Final M3U and daily-driver acceptance — PASS (user-supplied, 2026-08-19):** The representative M3U URL was previously user-reported to have worked great. The required corrected local-file flow was then defined exactly as `Connect → import → browse → playback`, and the user replied exactly `Yes, full flow passed`. This closes the representative M3U readiness and final daily-driver user gates. Phase 6 and Windows V1 are complete. No timings, screenshots, titles, resource measurements, provider coverage, credentials, or M3U guide behavior are inferred beyond the supplied evidence. UI/UX polish continues as ongoing unnumbered maintenance, not Phase 7.
