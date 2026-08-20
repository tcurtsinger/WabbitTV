# Wabbit TV Master Plan

**Status:** Planning baseline and Phases 0–6 complete; Windows V1 accepted. UI/UX polish continues as ongoing unnumbered maintenance, not Phase 7
**Last updated:** 2026-08-19  
**Product authority:** [`PRODUCT.md`](./PRODUCT.md)  
**Process authority:** [`ORCHESTRATION.md`](./ORCHESTRATION.md)  
**License:** AGPL-3.0  

## 1. Mission

Build a Windows 11 daily-driver IPTV player that makes a real, very large Strong IPTV catalog feel organized, fast, and intentionally designed. Wabbit supplies no content. Its product value is user-controlled sources, unified or source-scoped browsing, favorites, ordered mixed custom groups, and a polished desk-and-couch viewing experience.

The Windows daily driver is the only active delivery target. Android TV, Fire TV, and macOS are architectural considerations, not current implementation work.

## 2. Delivery Rules

These rules govern every phase.

1. **Stay inside the active phase.** Finish its acceptance gate before starting later features.
2. **Prefer the direct solution.** Do not add a framework, abstraction, service, or fallback until a current requirement needs it.
3. **Measure before optimizing.** The real Strong catalog and focused fixtures decide whether performance work or Rust is necessary.
4. **Handle realistic failure, not every imaginable failure.** Preserve the last usable catalog, return a useful error, and avoid unbounded retry loops. Do not build security theater or speculative defensive branches.
5. **Use proportional credential hygiene.** Keep source usernames, passwords, and credential-bearing playlist URLs out of source control, screenshots, and logs. Use an OS-backed storage package for account secrets rather than custom cryptography or database encryption. Arbitrary M3U item URLs may be stored only in the local catalog because moving tens of thousands of provider-supplied locators into secure key/value storage would add machinery without protecting against a meaningful project requirement; never log or export them.
6. **No hidden scope.** Cloud services, accounts, telemetry, payments, DRM, a plugin system, transcoding, recording, catch-up, and distribution infrastructure remain out of scope unless this plan is explicitly changed.
7. **Fred TV Next is reference material only.** Implement Wabbit code and assets fresh. Do not copy Fred source unless the lead records a concrete time-saving reason and the required attribution before the copy lands.
8. **Shape before visible work.** Every new visible feature must complete a confirmed `$impeccable shape` brief before visible implementation begins. Follow `ORCHESTRATION.md` for classification, persistence, delegation, and review.

## 3. Orchestration Contract

The primary Codex agent is the lead and manager.

- `ORCHESTRATION.md` is the durable authority for the lead role, Terra delegation, mandatory Shape gate, Impeccable tool routing, verification, and compaction recovery.
- The lead owns `PRODUCT.md`, this plan, architectural reconciliation, phase gates, and final verification.
- Implementation and bounded research tasks are delegated to Terra agents with explicit file or subsystem ownership.
- Parallel agents must not edit the same files. The lead assigns non-overlapping scopes and integrates work.
- Agent summaries are not proof. The lead reads the resulting diff, traces the relevant flow, and runs the required checks.
- Each phase starts with current repository verification and ends with evidence recorded against its acceptance gate.
- Bugs inside the active phase are fixed before the gate. Ideas outside it go to **Deferred Work** and are not implemented opportunistically.
- A product or scope change requires an explicit edit to `PRODUCT.md` or this plan before implementation. Minor implementation corrections that preserve the phase do not require plan churn.
- The lead may write integration glue or a focused correction directly, but remains responsible for delegation, review, and keeping all work on-plan.

## 4. Locked Product Decisions

- Public, noncommercial, open-source AGPL-3.0 project.
- Windows 11 first; preserve a future Flutter path to Android TV, Fire TV, and macOS.
- Flutter/Dart first. No Rust core unless measured evidence requires it.
- Supported source types: Xtream credentials, M3U URL, and local M3U file.
- Live, Movies, and Series are all part of the Windows daily-driver release.
- Multiple sources can be viewed separately or in one unified library.
- Favorites and ordered custom groups are first-class. One group may mix live channels, movies, and series and may be pinned to Home.
- Imported source items remain separate library identities. Automatic and manual duplicate merging are not product features.
- Required advanced viewing features: picture-in-picture and multiview.
- First multiview release is two simultaneous live streams. A 2x2 layout is deferred until measurements justify it.
- First PiP release is an in-app overlay that allows continued browsing. A detached always-on-top native window is deferred.
- Startup target is user-selectable: Home, previous screen, or last channel.
- No telemetry or application-controlled network destinations. Runtime network calls go only to user-configured sources.
- Rabbit personality is limited to the icon, onboarding, loading, and empty states. Routine viewing remains premium and restrained.

## 5. Experience Map

### Primary navigation

1. Home
2. Live
3. Movies
4. Series
5. Search
6. My Library
7. Settings

Sources are managed in Settings. Provider categories do not become top-level navigation.

### Catalog scope

Live, Movies, Series, and Search share one clear scope control:

- **All Sources**
- One named source

The selected scope persists locally and never changes the imported data.

### Home

Home is the user's launch board, not a provider feed.

1. Pinned Favorites and custom groups in one user-defined order
2. Continue Watching when nonempty
3. Recently Watched when nonempty

No recommendation engine, promotional hero, or automatic flood of provider category rows belongs on Home. A no-source Home teaches the single next action: add a source. If sources exist but personalized rows are still empty, Home offers direct Live, Movies, and Series entry points and teaches Favorite/Create Group without pretending to recommend content.

### My Library

- Favorites
- Custom groups
- Create, rename, reorder, pin/unpin, and delete a group
- Add or remove mixed-media items without changing provider data
- A mixed group page is one globally ordered list. Media-type labels may identify Live, Movies, and Series items without regrouping or changing their manual order.

### Input contract

- D-pad/arrow keys move to the nearest logical visible item.
- Enter/Select activates the focused item.
- Back/Escape dismisses the topmost transient surface, then returns through navigation.
- Closing a menu or dialog restores focus to its launcher.
- A card is one focus target; decorative badges and artwork are not separate stops.
- Secondary click or a context/menu action exposes Favorite and Add to Group actions.
- Mouse hover may add context but must never reveal the only path to an action.
- Returning from details or playback restores prior scope, scroll position, and focus when practical.

## 6. Minimal Technical Shape

### Runtime

- Flutter/Dart Windows application
- One local SQLite database using the direct `sqlite3` package
- Database and import work off the UI isolate
- `media_kit` as the first playback candidate
- `flutter_secure_storage` behind a tiny credential-store interface
- Direct controllers/view models using Flutter primitives; no event bus, CQRS, dependency-injection framework, or generalized repository/unit-of-work layer
- A small HTTP client boundary with `XtreamConnector` and `M3uConnector`; no provider plugin framework

The `sqlite3` package currently bundles SQLite for Windows, Android, and macOS and recommends background-isolate use for application workloads. `media_kit` documents Windows, Android, and macOS video support with libmpv-backed Windows rendering. These remain implementation candidates until Phase 0 proves them in the packaged Windows app.

References:

- [sqlite3 package](https://pub.dev/packages/sqlite3)
- [flutter_secure_storage package](https://pub.dev/packages/flutter_secure_storage)
- [media_kit](https://github.com/media-kit/media-kit)

### Code boundaries

1. **UI:** screens, focus, navigation, presentation state
2. **Sources:** Xtream and M3U fetch/parse behavior
3. **Catalog:** SQLite migrations, refresh, browse, search, and source scope
4. **Organization:** favorites, library identities, custom groups, and Home pins
5. **Playback:** player adapter, active sessions, stream admission, progress, PiP, and multiview
6. **Credentials:** read/write/delete secrets by source key

These are folders and small interfaces, not independently deployed services.

### Initial data model

```text
sources
  id, kind, name, display_endpoint, credential_key, enabled,
  refresh_generation, refresh_state, last_refresh_at, last_error,
  reported_connection_limit, connection_limit_override, settings_json

source_groups
  id, source_id, provider_key, content_kind, name, sort_key

catalog_items
  id, source_id, provider_key, kind, parent_id, source_group_id,
  title, normalized_title, playback_ref, artwork_locator,
  year, external_id, metadata_json, generation, available, updated_at

library_items
  id, kind, display_title, normalized_title, artwork_locator

library_members
  library_item_id, catalog_item_id, preferred

favorites
  library_item_id, created_at

custom_groups
  id, name, home_ordinal, created_at, updated_at

custom_group_items
  custom_group_id, library_item_id, ordinal

watch_state
  library_item_id, position_ms, duration_ms, completed, last_played_at

app_settings
  key, value

library_fts                  # FTS5, keyed to library_items
  title, supporting searchable text
```

Constraints and indexes are added only for actual queries: source/provider identity, kind, parent, source group, availability, group order, last played, and FTS lookup.

`playback_ref` is deliberately not one universal URL shape:

- Xtream records store the provider stream identifier, media kind, and extension; the final URL is assembled at play time using the source secret.
- M3U records store the provider-supplied direct item URL and required headers in the local catalog. These values are never logged, exported, or committed.

### Refresh rule

1. Fetch and parse away from the UI isolate.
2. Begin one SQLite transaction.
3. Upsert the new generation in bounded batches.
4. On success, mark older source records unavailable and commit.
5. On failure, roll back and keep the last usable catalog.

No job scheduler, outbox, refresh history service, or recovery daemon is needed.

### Library identity rule

- Start one `library_item` per imported `catalog_item`.
- Keep imported source items as separate library identities even when titles or external identifiers match.
- Do not build automatic, manual, fuzzy, or ML duplicate merging.
- Removing or disabling a source cannot destroy another source's identity or the user's custom group membership.

### Playback rule

- One `PlaybackManager` owns active sessions and the selected audible session.
- One quiet retry is allowed for a failed stream; then show redacted technical diagnostics and a recovery action. Dispose the prior transport before retrying.
- Parse a provider-reported connection limit when available. Otherwise assume one until the user sets a local override.
- Every new transport, including a retry, passes source-limit admission after the prior transport is disposed. Multiview admission is checked before opening another provider stream.
- V1 PiP is an in-app movable overlay. V1 multiview is a fixed two-stream layout with one audible tile.

## 7. Phase Plan

Every visible work item below begins with the confirmed Shape gate in `ORCHESTRATION.md`. Closely coupled screens in one coherent flow may share one brief; invisible implementation does not require ceremonial Shape work.

### Planning Baseline — Complete

**Delivered**

- Impeccable product initialization in `PRODUCT.md`
- Three independent Terra planning passes: UX, architecture, and Fred reuse
- Lead reconciliation into this master plan

**Gate**

- Product, scope, stack direction, orchestration model, and phased acceptance criteria are recorded before implementation.

---

### Phase 0 — Direction and Feasibility

**Status:** Complete

**Objective:** prove the few technical and visual decisions capable of invalidating the plan before building production features.

**Work**

1. Shape the Windows app shell through Impeccable direction selection and user confirmation, using the confirmed Hulu Live TV, YouTube TV, and Netflix craft bar without copied trade dress.
2. Shape Home separately, inheriting the approved app-shell direction; confirm its feature brief and required composition before production UI work. Do not write a speculative design system first.
3. Scaffold the Flutter Windows project, AGPL license, README, and minimal test layout.
4. Prove packaged Windows SQLite and FTS5.
5. Prove `media_kit` can play representative live, movie, and episode streams from the locally entered Strong account.
6. Record the provider account information returned by Xtream, including any connection limit, without recording credentials.
7. Probe two simultaneous local/test streams only if it does not violate the provider allowance.
8. Create a sanitized generated fixture large enough to exercise a catalog on the order of 50,000 records. It contains no real credentials or copyrighted catalog dump.

**Final checkpoint — 2026-08-16:** Phase 0 work items 1–8 and every acceptance criterion passed. The app shell and Home passed their confirmed Shapes, approved composition, independent Impeccable finish review, keyboard/layout tests, and Windows packages. Packaged SQLite 3.53.4 and FTS5 passed. The category-bounded Strong release probe passed live, movie, and episode playback with nonzero dimensions and screenshot evidence; maximum connections 1 / active 0 correctly allowed sequential playback and skipped two-stream. The generated 50k catalog imported in 172 ms and searched in 4 ms in a background isolate during the packaged baseline, with a positive main-isolate heartbeat. Evidence is recorded in `docs\evidence\phase0-sqlite-fts5.md`, `docs\evidence\phase0-strong-playback-probe.md`, and `docs\evidence\phase0-catalog-scale.md`. No invalidating stack decision remains; Phase 1 is next but has not started.

**Acceptance gate**

- Approved UX/design brief exists for the app shell and Home.
- Flutter Windows debug and release builds run.
- Packaged SQLite confirms FTS5.
- Representative live, movie, and episode playback works or the player candidate is explicitly rejected with evidence.
- Large fixture import/search can run without freezing the UI; timings are recorded as a baseline, not prematurely optimized targets.
- No secret appears in source control, fixtures, screenshots, or logs.

**Not in this phase**

- Final UI, custom groups, deduplication, full EPG, PiP, or multiview product controls

---

### Phase 1 — Strong End-to-End Slice

**Status:** Complete — source setup, Basic Browse, and production player passed source/fixture/package verification and the real Strong production flow

**Objective:** connect the real primary account to basic browse-and-play flows with the fewest moving parts.

**Work**

1. Xtream source form: source name, server URL, username, and password.
2. OS-backed credential storage and redacted logging.
3. Implement the minimal numbered migrations and catalog tables needed by this slice; do not build an in-memory catalog that Phase 2 must replace.
4. Run provider fetch, parsing, and catalog writes away from the UI isolate.
5. Fetch Live, Movie, and Series categories and items.
6. Fetch series details lazily when a series opens.
7. Present functional, deliberately plain lists for each media type.
8. Play one live channel, one movie, and one episode.
9. Display actionable authentication, unreachable-provider, empty-response, and playback errors.

**Source-setup checkpoint — 2026-08-17:** Work items 1–5 are verified for the Source Ledger boundary and real Strong source-add/restart path: Xtream form, OS-backed credential lifecycle, numbered SQLite migration/catalog persistence, worker-owned category/item import, and sanitized source-import failure/cancellation behavior. The final ordinary production run imported Strong with sanitized totals of 56,712 Live, 176,792 Movies, and 47,253 Series; closing and reopening immediately retained the persisted catalog without credential re-entry. Evidence: `docs/evidence/phase1-source-setup.md`.

**Basic Browse checkpoint — 2026-08-17:** Work items 6–7 are verified for the single-source Xtream slice: Live, Movies, and Series share bounded SQLite category/cursor paging; Movie has a minimal Play continuation; Series fetches detail lazily and parses it off the UI isolate; Live/Movie/Episode emit typed credential-free player handoffs. The approved C-artwork-forward/B-dense composition, virtual focus visibility, deep restoration, neutral network-free placeholders, constrained Categories overlay, 50k traversal/query plans, and generic Flutter native-source audit passed. The final real Strong production run rendered all three catalogs and categories and confirmed the browse/player return path. Evidence: `docs/evidence/phase1-basic-browse.md`.

**Production Player checkpoint — 2026-08-17:** Work item 8 is verified in source, synthetic package, and real Strong production flow. Typed Live/Movie/Episode handoffs resolve credentials only at opening, one transport is admitted at a time, first usable frame is bounded to 20 seconds, one quiet retry precedes redacted recovery, and exiting awaits coalesced teardown before restoring browse. The approved Broadcast Deck passed dual-agent Impeccable critique, one bounded polish pass, generic Flutter native-source audit (16/16), final format/analyze, 98 tests, debug/release production builds, and packaged Windows interaction at reference, large/fullscreen, and constrained sizes. One real Live item, Movie, and Episode each rendered visible video; VOD controls/timeline were truthful; Escape restored confirmed browse context. Evidence: `docs/evidence/phase1-production-player.md`.

**Acceptance gate — PASS (2026-08-17)**

- The packaged production app started from its no-source local state, added Strong, and browsed all three media types and categories.
- Closing and reopening preserved the source and immediately exposed the persisted catalog without credential re-entry; prior SQLite/log coverage verifies secret exclusion.
- One real Live item, Movie, and Episode played from the account.
- Existing synthetic source/player failure coverage gives useful redacted recovery and preserves the prior catalog; no failure was induced against the provider during the successful real run.

**Not in this phase**

- Final visuals, multi-source unification, M3U, personal library organization, or advanced playback

---

### Phase 2 — Catalog and Source Management

**Status:** Complete — source management, catalog scope, local Search, refresh, and individual/bulk Library Visibility passed automated/package checks; the user confirmed the sole remaining packaged Strong visibility gate

**Objective:** create the durable local library and make sources fully manageable.

**Work**

1. Complete the recorded SQLite schema and explicit numbered migrations.
2. Move catalog import and database work off the UI isolate.
3. Add M3U URL and local M3U file connectors.
4. Add source rename, refresh, disable/enable, edit, and remove.
5. Add All Sources and named-source scope to Live, Movies, Series, and Search.
6. Add FTS5 search across library titles and available metadata.
7. Preserve the last usable catalog on refresh failure.
8. Mark missing provider items unavailable rather than immediately destroying user references.
9. Record real Strong import, refresh, search, and browse measurements.
10. Let the user locally hide and restore provider categories or individual items without deleting imported data.

**Catalog Scope and Local Search checkpoint — 2026-08-17:** Work items 5–6 are implemented through a shared locally persisted All Sources / named-source scope, bounded local-only mixed Live/Movie/Series Search, and exact-source playback handoff for Xtream and M3U entries, including retained M3U headers. Format is clean, `flutter analyze` is clean, and the full serial suite passes 228/228. The Windows debug build passed and produced `build/windows/x64/runner/Debug/wabbit_tv.exe`. Five deterministic, network-free actual-Flutter renders passed and were visually inspected; evidence and its synthetic boundary are recorded in `docs/evidence/phase2-catalog-search/README.md`. Independent Impeccable critique plus bounded polish passed. The generic Flutter source audit initially found three P1 browse races; all three were fixed, and final closure reports no remaining P1/P2 findings.

**Real Strong refresh correction checkpoint — 2026-08-17:** The first packaged refresh exposed a real-scale defect: refresh rebuilt FTS with one equality delete per item against an unindexed identifier, making the write path quadratic, while transient catalog reads could replace usable views with unavailable states. The correction performs one stage-level FTS clear, uses bounded SQLite wait/WAL behavior, preserves the last local roster and catalog on noninitial read failure, and recovers a refresh worker that exits without a terminal event. `flutter analyze`, the full serial 228/228 suite, and the Windows debug build pass; an independent correction audit reports no P0/P1 findings. In the corrected debug build, the existing last-good Strong catalog recovered without reimport, refresh completed successfully in about 20 seconds, and the user confirmed browsing/navigation and the final source state remained good. Sanitized evidence is recorded in `docs/evidence/phase2-source-management/README.md`.

**Library Visibility checkpoint — 2026-08-17:** The explicitly confirmed **A — Source Category Directory + Item Visibility Ledger** is implemented as a local Settings continuation. Schema migration v6 adds durable `hidden` flags to `source_groups` and `catalog_items`; active named-source Browse, All Sources, and local Search each require both the item and its provider category to be included. Refresh upserts retain both preference levels, so restoring a category does not restore individually hidden items. The shell opens the ledger from the selected source and returns focus to its launcher after one shared catalog-scope refresh. Format and `flutter analyze` are clean; the full serial suite passes 268 tests. Independent critique and the generic Flutter native-source audit pass 16/16. Four inspected, synthetic Flutter renders cover desktop mixed state, Hidden only recovery, Uncategorized, and constrained directory. Debug and Release packages built at 2026-08-17 22:30:45 and 22:31:49 respectively: `build/windows/x64/runner/Debug/wabbit_tv.exe` and `build/windows/x64/runner/Release/wabbit_tv.exe`. A sanitized local-copy Strong measurement migrated v5→v6 in 1,629 ms and read category and 100-item pages in 2–98 ms across Live, Movies, and Series; existing local Search measured Spider 14/8/13 ms (first/count/next) and Fox 11/9/11 ms, with the original catalog hash unchanged. Evidence: `docs/evidence/phase2-library-visibility/README.md`.

**Bulk Category Visibility checkpoint — 2026-08-18:** The confirmed directory-toolbar extension is implemented with explicit Hide all and Restore all actions for the selected source and media kind. Each operation is one atomic category update; individual item flags and Uncategorized are untouched, while categories first imported by a future refresh default to Included. Hide all uses an inline confirmation with Cancel initially focused; Restore all is immediate. The shell blocks navigation away while persistence is pending. Failure states distinguish an uncommitted write from a committed save whose local view could not refresh, and refresh retry never repeats the write. `flutter analyze` is clean and the full serial suite passes 283 tests. Independent Impeccable critique passes and the generic Flutter native-source audit passes 16/16. Three synthetic Flutter renders were inspected. Debug and Release builds passed at `build/windows/x64/runner/Debug/wabbit_tv.exe` (2026-08-18 00:31:48 local) and `build/windows/x64/runner/Release/wabbit_tv.exe` (2026-08-18 00:32:32 local). Evidence: `docs/evidence/phase2-bulk-category-visibility/README.md`.

**Acceptance gate**

- All three supported source forms import and refresh.
- Two consecutive successful refreshes create no duplicate provider identities.
- A failed refresh leaves the prior catalog usable and shows source status.
- Disabling one source removes it from active unified results without deleting other source data.
- Removing a source removes its credentials and active catalog contribution without damaging unrelated sources.
- Search and scrolling remain responsive with the large fixture and real Strong catalog.
- A user can hide and restore a provider category or item locally; named Browse, All Sources, and Search reflect the category AND item rule.

**Gate status — PASS (2026-08-18):** Automated evidence covers all three connector forms, consecutive-refresh identity stability, failed-refresh preservation/status, disable, remove, the 50k local search/browse paths, and individual plus bulk Library Visibility rules. The corrected packaged real Strong Search pass was user-confirmed earlier. For the sole remaining gate, the user ran the packaged Release build against Strong and reported `Perfect, pass` after Hide all, restoring the desired Live categories, confirming Browse/Search propagation, and refreshing to confirm retention. This is user-supplied runtime evidence; no screenshot, timing, or provider title was recorded.

**Not in this phase**

- Smart collections, fuzzy matching, cloud sync, or background scheduling

---

### Phase 3 — App Shell and Browsing Experience

**Status:** Complete — the finished shell, runtime Home, read-only My Library, bounded artwork, catalog states, continuations, and return behavior passed automated, review, render, Windows build, and packaged Strong verification

**Objective:** replace the functional spike UI with the approved premium, restrained Windows viewing experience.

**Work**

1. Build the persistent navigation shell and the seven recorded destinations.
2. Implement Live, Movies, Series, Search, My Library, and Settings browse surfaces.
3. Implement Home empty, loading, and locally backed continuity rows.
4. Add virtualized/lazy grids and artwork loading appropriate to the real catalog.
5. Implement keyboard, mouse, and remote focus rules.
6. Preserve focus, scroll position, and catalog scope across details and playback.
7. Add missing-artwork, no-result, stale-source, importing, and source-error presentation.
8. Run the bounded Impeccable visual inspection required for the implemented surfaces.

**Implementation checkpoint — 2026-08-18:** The persistent seven-destination shell now routes runtime Home, Live, Movies, Series, Search, read-only My Library, and Settings without replacing the verified Phase 1/2 source and player boundaries. Home records a credential-free Recently Watched occurrence only after usable video and restores practical focus on return; progress seeking remains Phase 5. My Library reads Favorites and custom groups through bounded membership-first keyset pages, keeps unavailable memberships truthful, and opens the existing Live/Movie/Series continuations without adding Phase 4 mutation actions. Browse and Search show last-good source state, bounded fixed artwork, and actionable continuation failures. Artwork requests are sourced only from imported HTTP(S) locators, use a bounded disk cache and two-request maximum, and are cancelled when virtual rows leave the mounted window.

**Verification checkpoint — 2026-08-18:** `flutter analyze` is clean and the full serial suite passes **360/360**. The Release build passed at `build/windows/x64/runner/Release/wabbit_tv.exe` (2026-08-18 16:05 local). Nine credential-free Flutter renders cover Home, My Library, Browse, Search, and Movie/Series continuations at reference and constrained sizes. Independent Impeccable and generic Flutter native-source closure reviews report no remaining P1/P2 findings. Evidence and its synthetic boundary are recorded in `docs/evidence/phase3-browsing-experience/README.md`.

**Acceptance gate**

- Every primary screen is reachable and usable with keyboard/remote alone.
- Mouse-only hover is not required for any action.
- Back/Escape and focus restoration are intentional across menus, details, and playback.
- Large grids do not render the entire catalog at once or lock the UI during artwork loading.
- The rendered app matches the approved direction at the target Windows viewport and passes the bounded design review with no unresolved material navigation or hierarchy defect.

**Gate status — PASS (2026-08-18):** In the packaged Strong Release exercise, the user found that only the initially focused artwork loaded automatically. The correction lets only the mounted virtual-row window begin artwork after a short dwell, without click/focus, while preserving two-request concurrency, cache bounds, and cancellation during fast scrolling. After rebuilding Release, the user reported `Ok way better. Pass`. This is user-supplied runtime acceptance; no provider title, locator, or credential was recorded.

**Not in this phase**

- Visual experiments outside the approved direction or a generalized component library unrelated to current screens

---

### Phase 4 — Personal Library Organization

**Objective:** deliver Wabbit's primary differentiator.

**Work**

1. Favorites backed by `library_items`.
2. Create, rename, delete, reorder, pin, and unpin mixed custom groups.
3. Add an item to Favorites and multiple custom groups in one save from Browse, Search, Home, My Library, or a detail continuation.
4. Pin Favorites and custom groups to Home in one explicit user order.
5. Preserve one separate library identity per imported source item; do not add automatic or manual merging.

**Acceptance gate**

- Favorites, custom group order, group item order, and Home shelf order survive refresh and restart.
- One group can contain and display live, movie, and series items.
- Pin/unpin changes Home without deleting Favorites, the group, or its memberships.
- Removing an item from a group never removes it from its source.
- One organizer save can update Favorite plus several custom-group memberships atomically.
- No automatic or manual duplicate merging is present.

**Not in this phase**

- Smart/rule-based groups, recommendations, metadata enrichment, or ML matching

**Shape checkpoint — 2026-08-18:** The user confirmed Favorites as a pinnable Home shelf, rejected automatic and manual merging, approved multi-group selection in one save, and selected **A — Direct Organizer Drawer**. The implementation contract is `docs/shapes/10-phase4-personal-library-organization.md`.

**Implementation checkpoint — 2026-08-18:** Schema v10 and the organization port now keep Favorites, ordered mixed custom groups, explicit group-item order, and one shared Favorites/group Home-shelf order against stable `library_items`. The shared Direct Organizer Drawer is reachable from Home, Browse, Search, My Library, and Movie/Series continuations and applies Favorite plus the complete checked-group set in one local transaction. My Library adds quiet Create/Manage continuations; group administration covers naming, pinning, directory/Home/item movement, membership removal, and truthful deletion without changing source data. Home loads only bounded pinned shelves/pages. Six credential-free actual-Flutter renders, including the 360 px drawer, 460 px manager, pinned Home, confirmation, and 600 px constrained state, pass and are recorded in `docs/evidence/phase4-personal-library-organization/README.md`. Final repository verification is clean: format is stable, `flutter analyze --no-pub` reports no issues, the serial suite passes 400/400, both Windows Debug and Release builds pass, and the independent native-source re-audit reports no remaining P1/P2 findings.

**Gate status — PASS (2026-08-18):** Implementation, bounded automated/render verification, independent review, and Windows builds are complete. The user then ran the packaged Strong Release checklist and confirmed Favorites plus two custom groups in one Save, membership visibility, pinned Home order before Recently Watched, non-destructive unpin and membership removal, refresh/restart persistence, and mouse/keyboard/remote return behavior with `Pass, confirmed`. This is user-supplied runtime acceptance; no provider title, locator, credential, screenshot, or timing was recorded.

---

### Phase 5 — Playback, PiP, and Multiview

**Status:** Complete — bounded evidence and user-supplied packaged Strong/Windows acceptance pass

**Objective:** complete the required advanced viewing experience within measured provider and hardware limits.

**Work**

1. Finalize player controls, audio/subtitle selection, fullscreen, and movie/episode resume state.
2. Keep one quiet retry followed by redacted diagnostics and recovery; offer only an exact pre-existing source variant when one genuinely exists.
3. Add in-app PiP overlay while browsing.
4. Add fixed two-stream live multiview.
5. Keep one tile audible; selecting another tile moves audio focus.
6. Enforce reported or locally overridden connection allowance before opening another stream.
7. Measure start time, CPU, memory, decoder behavior, and stability on the actual Windows hardware.

**Acceptance gate**

- Playback entry/exit restores the correct browse context.
- Movie and episode progress resumes after restart.
- PiP continues while the user navigates supported browse surfaces and returns cleanly to full player.
- Two-view multiview is stable when the provider and hardware allow it.
- Attempts beyond the configured source limit are blocked before creating a new connection and explain the next action.
- Retry and exact pre-existing source-variant attempts dispose their prior transport and pass the same connection-admission check.
- A stream failure never enters an unbounded reconnect loop.

**Not in this phase**

- Detached native-window PiP, 2x2 multiview, casting, transcoding, downloads, or DVR

**Shape checkpoint — 2026-08-19:** The user selected automatic resume with Start over, Corner Signal in-app PiP across content destinations with stop-confirm before Settings/management, and active Live → Add channel → existing Live directory → equal two-up multiview. The confirmed implementation contract is `docs/shapes/11-phase5-playback-pip-multiview.md`. The permanent no-merge rule excludes fuzzy/title-derived alternate variants.

**Implementation checkpoint — 2026-08-19:** Schema v11 and the production playback boundary now persist truthful Movie/Episode progress against stable library identities, automatically resume eligible items, retain Start over, and restart near-finished items. One `PlaybackManager` owns sessions, retry, selected audio, and source-limit admission using local override → provider-reported limit → conservative one. The Broadcast Deck exposes real available audio/subtitle tracks, redacted bounded recovery, PiP, and Live-only Add channel without creating fuzzy/title-derived variants. Corner Signal is a movable fixed-corner 16:9 in-app overlay across Home, Live, Movies, Series, Search, and My Library; Settings and management require the stop-playback confirmation. Admitted multiview is an equal side-by-side Live pair with one shared deck and exactly one audible tile. Source Settings exposes Automatic, 1, and 2 without claiming provider permission.

**Bounded verification checkpoint — 2026-08-19:** Format, `flutter analyze --no-pub`, and `git diff --check` are clean; the serial suite passes 469/469; Windows Debug and Release builds pass. Eleven deterministic credential-free actual-Flutter renders plus the targeted corrected constrained multiview recapture pass and were inspected. Independent Impeccable review reports PASS, and the generic Flutter native-source audit passes 16/16. The synthetic/local evidence boundary is recorded in `docs/evidence/phase5-playback-pip-multiview/README.md`.

**Credential-free packaged measurement attempt — 2026-08-19:** A temporary Release fixture attempted local, network-free `media_kit` playback from a generated lavfi input. The native input produced no video, so the run is recorded as unsupported and makes no playback, PiP, two-surface, CPU, memory, decoder, startup, transition, or stability claim. The aggregate ignored evidence is `build/verification/phase5-windows-packaged-measurement.json`; teardown reported zero active sessions and no lingering measured process. The normal production Release was rebuilt successfully afterward, replacing the fixture entry point. Real Strong playback and target-hardware measurements remain pending.

**Gate status — PASS (user-supplied, 2026-08-19):** The user ran the packaged Phase 5 Strong/Windows checklist and reported `Ok pass`. Strong's reported one-stream allowance made the correct pre-open second-stream block the real-provider multiview admission evidence; actual two-stream success was not exercised and remains conditionally unavailable without a genuinely permitted source. This acceptance does not invent or record provider titles, timings, CPU or memory values, decoder details, available tracks, or two-stream success. The unsupported lavfi attempt remains non-evidence. The user accepted this bounded/conditional evidence boundary and Phase 5 is complete.

---

### Phase 6 — Windows Daily-Driver and Xtream Live Guide Gate

**Status:** Complete — implementation, audits, synthetic renders, final automation, Windows Debug/Release packages, corrected packaged Strong Guide behavior, representative M3U URL and local-file readiness, and final daily-driver user acceptance passed

**Objective:** finish the Xtream-only Live Guide and prove Wabbit is ready for sustained Windows personal use. This is the final numbered implementation phase.

**Work**

1. Complete and obtain user confirmation for the mandatory Impeccable Shape brief before implementing visible Live Guide UI.
2. Import provider EPG data only when an active Xtream source exposes it.
3. Match programs to channels with provider identifiers; do not add fuzzy or title-derived cross-source merging.
4. Add truthful Now/Next and one simple remote-friendly timeline guide.
5. Keep missing or malformed guide data independent from catalog refresh and channel playback.
6. Add the user-selectable startup target.
7. Run real Strong regression passes for add, refresh, browse, search, organize, play, PiP, connection admission, and the available Xtream guide path.
8. Test a representative M3U URL and local M3U file for source/import/browse/playback readiness only. M3U is not an EPG input in Windows V1.
9. Run focused unit tests for Xtream guide parsing/matching, migrations, favorite/group ordering, and playback connection admission.
10. Run focused widget/integration tests for the primary guide and daily-driver remote-navigation flows.
11. Run Flutter analysis, tests, a release build, and the bounded Impeccable finish workflow.
12. Fix material daily-driver defects; do not begin future-platform or deferred-feature work.

**Shape checkpoint — 2026-08-19:** The user selected and confirmed a dedicated `Guide` rail destination after Live, a classic channel-by-time matrix scoped to one enabled Xtream source and one visible provider category at a time with `All Live`, quiet exact Now/Next in Live rows, and exact Last channel automatic startup with a truthful Home fallback. UTC persistence/local-time display, lazy bounded `get_short_epg`, focus/Back, responsive, failure, and evidence contracts are recorded in `docs/shapes/12-phase6-xtream-live-guide-startup.md`. Confirmation starts Phase 6 but does not verify implementation or provider behavior.

**Implementation checkpoint — 2026-08-19:** Schema v12, exact source/provider-channel EPG state and last-good programs, lazy viewport-bounded Xtream `get_short_epg`, UTC persistence/local display, source-wide credential/authentication retry truth, cached Live Now/Next, the classic Guide matrix, and Home/Previous screen/exact Last channel startup are implemented. Guide absence or failure remains independent from catalog use and playback; M3U XMLTV input, fuzzy matching, merging, and bulk full-guide acquisition were not added. Independent UI, native-source, and security audits report **PASS** with no remaining P0/P1/P2 findings. Seven credential-free actual-Flutter states pass deterministically and retain identical recorded hashes in `docs/evidence/phase6-xtream-live-guide/`.

**Packaged Strong discovery/correction checkpoint — 2026-08-19:** The user's packaged run settled 149 channel states: 148 `empty`, 1 `available`, 0 `error`, and 0 `refreshing`, with 4 cached programs overlapping the Guide window. This proves Strong's short EPG works sparsely and that the run left no stuck lease; it does not accept the original presentation. The run exposed a real repeated/stuck `Preparing` defect caused by replacing the viewport map and deriving status globally, compounded by lifecycle and parser-truth gaps. The corrected tree derives status from only the active viewport, retains a bounded three-view by 40-row LRU (120 channel IDs), distinguishes malformed responses from valid empty schedules, releases obsolete work through prompt generation-safe cancellation and lease cleanup, lets explicit manual Retry bypass only persisted errors without stealing an active lease or bypassing successful/empty TTL, exposes typed local-persistence recovery, and corrects paging, category, and `Go to now` lifecycle behavior.

**Final automated/package checkpoint — 2026-08-19:** formatting checked 100 files with 0 changes; `flutter analyze` reports no issues; the full serial suite passes 581/581 in 80.125 seconds; and `git diff --check` passes. Independent closure and the picker correction review report **PASS**. The workstation MSBuild C++ FileTracker workaround remains process-scoped: `$env:TrackFileAccess='false'`. It enabled a cold/default Debug build in 42.132 seconds at `build/windows/x64/runner/Debug/wabbit_tv.exe` (1,140,736 bytes; 2026-08-19 14:22:29.022 -05:00; SHA-256 `77C8EF3FA4884EC9470828BC0D8347C12292D600818D73C1ADE51F1054AFF341`) and a normal/default Release build in 48.068 seconds at `build/windows/x64/runner/Release/wabbit_tv.exe` (183,296 bytes; 2026-08-19 14:23:51.199 -05:00; SHA-256 `D112C13F8FF39927C50A86A0E4CE96F890E99DF1811E120164A81A971BEB2B7F`). Both used `FLUTTER_TARGET=lib/main.dart`; decoded defines contained only standard Flutter metadata and no WABBIT fixture/probe defines. No Flutter, Dart, Wabbit, MSBuild, or compiler process remained.

**Corrected packaged Strong Guide rerun — PASS (user-supplied, 2026-08-19):** After running the corrected Release, the user reported `Ok pass`. At the user-observed level, this closes the repeated/stuck `Preparing`, reverse-scroll, and rapid category/scope packaged behavior. No provider title, timing, screenshot, program-coverage result, resource measurement, or credential was recorded or inferred.

**Packaged local M3U picker correction — PASS for selection only (2026-08-19):** The user reported that choosing `Choose M3U file` froze the packaged app in a Windows `Not Responding` state and required Alt+F4. Wabbit does not read a playlist before selection: the runtime picker returns only a path, the form stores that path, and local-file acquisition begins only after `Connect`. The correction is deliberately UI-only: one in-flight picker request, an `endOfFrame` barrier so pending truth paints before the owned Windows modal opens, disabled conflicting actions while pending, redacted retryable error truth, and exact focus restoration after cancel, failure, or selection. No file-selector adapter, plugin, runner, parser, or import behavior changed. Independent review reports **PASS**. In the rebuilt Release, the lead observed the owned Windows dialog, saw the pending state paint, pressed Escape and returned to a responsive form with exact `Choose M3U file` focus, reopened the dialog, selected the Downloads test playlist, and saw the field populate. The app was then closed without importing or adding a source, so this checkpoint proves only the corrected picker lifecycle—not local-file source/import/browse/playback readiness.

**Corrected packaged local-file chooser acceptance — PASS (user-supplied, 2026-08-19):** After being asked to retry the corrected local M3U file flow in the new packaged Release, the user replied exactly `Pass`. This narrowly accepts the picker defect correction and corrected packaged chooser flow. The one-word result supplied no steps, timings, screenshots, or import/browse/playback evidence, so no broader M3U readiness claim is inferred.

**Final M3U and daily-driver acceptance — PASS (user-supplied, 2026-08-19):** The representative M3U URL was previously user-reported to have worked great. For the corrected local-file path, the required full flow was then stated exactly as `Connect → import → browse → playback`, and the user replied exactly `Yes, full flow passed`. This closes the representative M3U readiness and final daily-driver user gates without adding timings, screenshots, titles, resource measurements, provider coverage, or credential-bearing evidence beyond what the user supplied.

**Gate status — PASS:** Phase 6 and Windows V1 are complete. UI/UX polish continues as ongoing unnumbered maintenance rather than Phase 7.

**Acceptance gate — Windows V1**

- A fresh install can add each supported source form and play supported content.
- The real large catalog stays responsive through refresh, search, and browsing.
- An Xtream source with provider EPG data exposes truthful Now/Next and the shaped simple timeline; absent or malformed guide data never blocks catalog use or playback.
- M3U URL and local-file sources remain verified for source/import/browse/playback readiness without exposing XMLTV URL/file guide configuration or claiming guide support.
- Unified/source scopes, favorites, mixed custom groups, and Home pins persist correctly.
- PiP and two-view multiview meet the recorded behavior.
- All primary flows, including the Guide, work from keyboard/remote with visible focus and predictable Back/Escape.
- No source username, password, or credential-bearing playlist URL appears in source control, ordinary logs, or committed fixtures. Provider-supplied M3U item URLs remain confined to the local catalog.
- Required checks pass and the lead has independently inspected the final diff and exercised the core flows.

**Not in this phase or Windows V1**

- M3U XMLTV URL or file input and any M3U guide path
- Recording, reminders, catch-up, DVR, archival behavior, or elaborate guide customization
- Detached native-window PiP, 2x2 multiview, casting, transcoding, or downloads

### Post-V1 UI/UX polish (ongoing, unnumbered)

After Phase 6 closes Windows V1, UI/UX refinement continues as ongoing maintenance: fix real usability defects, improve clarity, and preserve the confirmed product/design contracts. It is not another numbered feature phase and does not authorize hidden product scope.

**Left-sidebar polish checkpoint — complete and user-approved (2026-08-20):** The user authorized all five findings from the bounded left-rail critique, explicitly chose remote/accessibility correctness rather than a visual-only pass, and chose bottom-anchored Settings behind a restrained separator. The implemented correction (1) adds the documented shell-level remote Menu route while preserving contextual Menu ownership such as My Library Organize, (2) adds a persistent 2 px resting selected-location marker without spending signal amber, (3) makes destination rows 48 px minimum with complete wrapping, scrolling, and focused-row reveal at 1.5x/2x text and short heights, (4) exposes each destination and Now Playing once through authoritative button/selected semantics, and (5) adds quiet per-row pointer hover plus the click cursor while separating Settings at the bottom utility seam. The passive playmark now uses quiet text so amber remains an interaction signal.

The initial independent critique reported exactly those five priority gaps: missing remote Menu entry, weak collapsed selected orientation, incomplete high-text/television-distance behavior, duplicate expanded announcements, and under-articulated pointer/utility hierarchy. The corrections received a final independent **PASS** with no remaining P0/P1/P2 findings. Formatting checked 100 files with 0 changes, `flutter analyze --no-pub` is clean, the full serial suite passes 587/587 in 81.055 seconds, and scoped diff-check passes. Four deterministic credential-free actual-Flutter sidebar renders pass 4/4 and are recorded in `docs/evidence/sidebar-polish/README.md`.

Fresh production packages also pass: Debug completed in 46.187 seconds at `build/windows/x64/runner/Debug/wabbit_tv.exe` (1,140,736 bytes; 2026-08-20 10:36:58.778 -05:00; SHA-256 `41CA311CF6D1DE92A5FA16B45E1E1B5A817B09F80C3945071E0E2639AB529919`) and Release completed in 47.954 seconds at `build/windows/x64/runner/Release/wabbit_tv.exe` (183,296 bytes; 2026-08-20 10:38:04.592 -05:00; SHA-256 `411B7E51BEA6779EFF51A5E3C97356066B59B142D6FC2479986A7F25A2603E1B`). Both target `lib/main.dart` with no custom WABBIT defines. After this corrected Release and its evidence were presented, the user replied exactly `Approved`; this closes the packaged sidebar-polish gate without inferring any additional timings, screenshots, or interaction details.

### Deferred platform backlog (not scheduled; not a phase)

Future platform work may be reconsidered only through an explicit later product decision; it is not a numbered next phase:

- Android TV and Fire TV platform setup, remote focus verification, Android Back behavior, and playback validation
- macOS platform setup, window behavior, keychain configuration, and playback validation
- Platform-specific visual adaptation where system conventions require it
- Reuse of the shared Dart catalog and source layers with only the smallest necessary platform adapters

This backlog does not automatically include mobile-phone layouts, store submission, cloud synchronization, distribution automation, or a commitment to implement any platform.

## 8. Verification Strategy

### Automated checks with high value

- Xtream and M3U parser fixtures, including the few malformed forms observed in real use
- Xtream provider EPG parsing, provider-identifier channel matching, and absent/malformed guide isolation
- SQLite migration tests
- Refresh idempotence and last-good rollback
- Custom group order and persistence
- Favorite, mixed-group, item-order, and Home-pin invariants
- Search against a generated large fixture
- Playback connection-limit admission
- Essential keyboard/remote focus flows

### Manual evidence

- Real Strong add/refresh/playback results
- Import, search, first-play, CPU, and memory observations on the actual Windows machine
- Screenshots for the Impeccable visual review
- PiP and multiview behavior on the target display and hardware
- Xtream Now/Next and timeline behavior when the real provider exposes EPG data

### Explicitly unnecessary

- Exhaustive fuzzing of every provider payload
- Penetration-test infrastructure
- Custom cryptography
- Encrypted SQLite
- Certificate pinning, VPN/proxy detection, or anti-tamper code
- A full browser/device matrix before those platforms are active
- Tests that only restate framework behavior

## 9. Fred TV Next Boundary

The reviewed Fred TV Next code is useful as a checklist for Xtream actions, tolerant provider field parsing, M3U header behavior, and `media_kit` feasibility. It is not Wabbit's foundation:

- Its Rust/FFI core conflicts with the Dart-first decision.
- Its groups are source-bound provider categories rather than ordered mixed user collections.
- Its catalog is per-source and does not model Wabbit's local personal-library organization.
- Its playback surface is single-player and does not supply Wabbit PiP or multiview.
- Its current credential storage and generated stream URLs are not behavior to inherit.

Default decision: implement fresh and link to Fred in project acknowledgements as design/protocol research. If future work copies Fred expression rather than protocol behavior, record the exact upstream commit and paths in third-party notices before merging it.

Reference: [Fred TV Next](https://github.com/Fredolx/fred-tv-mobile)

## 10. Deferred Work

Not part of Windows V1:

- Detached always-on-top native PiP window
- 2x2 or larger multiview
- Recording, timeshift, and catch-up
- Provider failover automation
- Profiles, parental controls, and cloud sync
- M3U XMLTV URL/file guide input or guide support
- Guide recording, reminders, catch-up, DVR, archival behavior, or elaborate customization
- Smart groups and recommendations
- Metadata enrichment services
- Plugin/provider marketplace
- Casting and external-device control
- Local media library
- Store packaging, installer engineering, automatic updates, and release infrastructure
- Rust core or native catalog service without a measured performance reason

## 11. Phase Status

| Phase | State |
|---|---|
| Planning baseline | Complete |
| 0 — Direction and feasibility | Complete |
| 1 — Strong end-to-end slice | Complete |
| 2 — Catalog and source management | Complete |
| 3 — App shell and browsing | Complete |
| 4 — Personal organization | Complete |
| 5 — Playback, PiP, and multiview | Complete — user-supplied packaged Strong/Windows acceptance |
| 6 — Windows daily-driver and Xtream Live Guide gate | Complete — implementation, audits, renders, 581/581 automation, Windows Debug/Release packages, corrected packaged Strong Guide behavior, representative M3U URL/local-file readiness, and final daily-driver user acceptance passed; Windows V1 is complete |

## 12. Plan Change Log

| Date | Change | Reason |
|---|---|---|
| 2026-08-16 | Initial master plan recorded | Product discovery and lead reconciliation of three Terra planning reviews |
| 2026-08-16 | Corrected credential locator rules, preserved global mixed-group order, initially deferred EPG work, made Phase 1 scale-safe, tightened retry admission, and removed hidden V1 actions | Independent Terra verification findings; the later Phase 6 consolidation supersedes the original guide timing |
| 2026-08-16 | Added durable orchestration authority and mandatory Impeccable Shape gate for every new visible feature | User locked the lead/delegation process and Impeccable lifecycle |
| 2026-08-16 | Corrected Shape direction/confirmation order, target-specific compaction recovery, and Windows-versus-mobile native audit boundaries | Independent Terra verification of orchestration policy |
| 2026-08-16 | Started Phase 0 with the mandatory Windows app-shell Shape gate | User authorized implementation to begin |
| 2026-08-16 | Confirmed Quiet Broadcast, Personal Shelves, and composition B — Focused Shelf; recorded the approval and surface fidelity inventory | User approved the Phase 0 app-shell and Home direction before visible implementation |
| 2026-08-16 | Completed and verified the Flutter Windows scaffold, app shell, and Home proof; recorded the independent Impeccable PASS and three-state render evidence | Phase 0 work items 1–3 met their visible and technical gates |
| 2026-08-16 | Proved packaged Windows SQLite 3.53.4 and FTS5 with a file-backed background-isolate probe; debug/release packaging and independent review passed | Phase 0 work item 4 met its acceptance evidence without introducing production catalog architecture |
| 2026-08-16 | Implemented and pre-credential verified the separate Strong playback/account-limit probe; debug/release builds, 22 tests, real-window inspection, and independent reviews passed | Phase 0 work items 5–7 were ready for the maintainer-local Strong run without adding product source/player UI |
| 2026-08-16 | Verified category-bounded Strong live, movie, and episode playback; recorded sanitized startup, dimensions, screenshots, and the provider-reported one-connection admission result | Phase 0 work items 5–7 passed after real catalog size drove a bounded category-first correction |
| 2026-08-16 | Generated, imported, and searched a synthetic 50k SQLite/FTS5 catalog off the UI isolate; packaged baseline and independent review passed | Phase 0 work item 8 and the final technical acceptance criterion passed without premature optimization |
| 2026-08-16 | Closed the Phase 0 gate | Every recorded visual, packaging, database, playback, provider-admission, privacy, and scale criterion passed |
| 2026-08-17 | Implemented and synthetic-package verified the shaped Phase 1 production player; closed critique, audit, focus, lifecycle, sizing, and Windows fullscreen findings | Phase 1 work item 8 is ready for the remaining real Strong browse-and-play gate without adding advanced playback scope |
| 2026-08-17 | Closed Phase 1 after the maintainer-local Strong production run imported, browsed, played Live/Movie/Episode, restored focused context, and persisted across restart | All recorded Phase 1 acceptance items now have real-run or bounded synthetic evidence; no advanced playback scope was added |
| 2026-08-17 | Implemented and bounded-verified Phase 2 Catalog Scope and Local Search, including exact-source Xtream/M3U playback handoff | Automated, render, audit, and Windows build evidence passed; packaged interaction and real Strong measurements remain before the Phase 2 gate can close |
| 2026-08-17 | Corrected the real-scale Strong refresh path and reran the packaged Windows gate | The prior catalog recovered without reimport; refresh completed in about 20 seconds and browse/navigation remained good. One real Strong Search responsiveness check remains before Phase 2 closes |
| 2026-08-17 | Implemented Library Visibility after its explicitly confirmed viewport | Schema v6 preserves local category/item choices; synthetic, audit, package, and copy-only Strong-scale evidence pass. Packaged real Strong hide/restore and Browse/Search propagation remain before Phase 2 closes |
| 2026-08-18 | Implemented the confirmed bulk-category visibility toolbar | Atomic source/kind updates, failure truth, busy-shell containment, 283 tests, audit, renders, and both Windows builds pass. Packaged Strong propagation and refresh retention remain before Phase 2 closes |
| 2026-08-18 | Closed the Phase 2 gate after the packaged Strong visibility exercise | User reported `Perfect, pass` after Hide all, desired Live-category restoration, Browse/Search propagation, and refresh retention; no screenshots, timings, or provider titles were recorded |
| 2026-08-18 | Started Phase 3 with the mandatory app-shell and browsing Shape gate | User authorized the lead to begin Phase 3 after Phases 0–2 and the post-merge review fixes were merged |
| 2026-08-18 | Confirmed the Phase 3 browsing boundary and My Library composition A | User approved read-only My Library, Recently Watched after usable video, Phase 5 resume, bounded source-supplied artwork, and the direct directory-plus-ledger viewport |
| 2026-08-18 | Closed the Phase 3 gate after the packaged Strong artwork correction | Automated, render, build, Impeccable, and native audit evidence passed; mounted virtual rows now fill artwork without clicks while fast-scroll cancellation and two-request admission remain bounded, and the user reported `Ok way better. Pass` |
| 2026-08-18 | Completed Phase 4 personal library organization | Transactional Favorite/multi-group changes, ordered mixed groups, pinned personal Home shelves, group management, 400 passing tests, inspected renders, independent review, Windows builds, and the user-confirmed packaged Strong checklist close the phase |
| 2026-08-19 | Implemented and bounded-verified the confirmed Phase 5 playback extension | Schema v11 progress, resume/Start over, tracks, admission, Corner Signal, source-limit controls, and equal two-up Live multiview pass 469 tests, inspected renders, independent reviews, and Windows builds; packaged Strong/resource measurements and genuinely permitted real two-stream proof remain |
| 2026-08-19 | Closed the Phase 5 gate after the packaged Strong/Windows checklist | User reported `Ok pass`; Strong's reported one-stream allowance correctly blocked stream two before open, so real two-stream success was not exercised and no provider titles, timings, resource values, track availability, or two-stream success were recorded |
| 2026-08-19 | Combined the Windows daily-driver gate and Xtream Live Guide into the final Phase 6 | User made the next phase the last numbered phase, excluded every M3U XMLTV guide path, retained M3U source/playback regression, moved future platforms to an unscheduled backlog, and made post-V1 UI/UX polish ongoing unnumbered work |
| 2026-08-19 | Confirmed the Phase 6 Xtream Live Guide and startup Shape | User selected the dedicated Guide rail and classic source-local matrix, one Xtream source/category with All Live, quiet Now/Next, and exact Last channel automatic startup; implementation and verification were still pending at that checkpoint and completed later |
| 2026-08-19 | Corrected and bounded-verified the confirmed Phase 6 surface and data foundation after the first packaged Strong guide run | The run proved sparse short-EPG availability (149 settled: 148 empty, 1 available, 0 error, 0 refreshing, 4 programs) and no stuck lease while exposing a real repeated `Preparing` defect. Active-viewport truth, the bounded 120-ID LRU, parser/lifecycle/retry/persistence corrections, automation, independent closure, renders, and Windows packages pass. The corrected packaged Strong rerun passed later; the M3U and final acceptance gates were closed separately afterward |
| 2026-08-19 | Passed the corrected packaged Strong Guide rerun | User reported `Ok pass`; repeated/stuck `Preparing`, reverse-scroll, and rapid category/scope packaged behavior close at the user-observed level. No title, timing, screenshot, program-coverage, resource, or credential claim was added. M3U readiness and final daily-driver acceptance were verified separately afterward |
| 2026-08-19 | Corrected and packaged-verified the local M3U picker lifecycle | The user-reported `Choose M3U file` freeze/`Not Responding` state required Alt+F4. A UI-only single-flight, pending-frame, error, and focus correction passed independent review, 581/581 automation, fresh Windows packages, and the lead's owned-dialog cancel/reopen/select exercise. The Downloads test playlist populated the field, but that bounded lead exercise ended before `Connect`; the full local-file flow was accepted separately afterward |
| 2026-08-19 | User accepted the corrected packaged local-file chooser | When asked to retry the corrected local M3U file flow in the new packaged Release, the user replied exactly `Pass`. That one-word checkpoint closed only the picker defect and chooser-flow correction; the full local-file readiness gate was explicitly closed later |
| 2026-08-19 | Closed Phase 6 and Windows V1 | The representative M3U URL was user-reported to have worked great. After the required local-file flow was defined as `Connect → import → browse → playback`, the user replied exactly `Yes, full flow passed`. This closes representative M3U readiness and final daily-driver acceptance without inventing timings, screenshots, titles, resource data, provider coverage, or credentials. UI/UX polish continues as ongoing unnumbered maintenance, not Phase 7 |
| 2026-08-20 | Completed and received packaged user approval for the left-sidebar polish | All five critique findings were corrected with remote/accessibility correctness and bottom-anchored separated Settings. Independent final review, 587/587 automation, four inspected Flutter renders, and fresh Debug/Release packages pass; the user then replied exactly `Approved`, closing this bounded polish gate |
