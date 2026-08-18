# Wabbit TV Master Plan

**Status:** Planning baseline complete; Phases 0–2 complete  
**Last updated:** 2026-08-18  
**Product authority:** [`PRODUCT.md`](./PRODUCT.md)  
**Process authority:** [`ORCHESTRATION.md`](./ORCHESTRATION.md)  
**License:** AGPL-3.0  

## 1. Mission

Build a Windows 11 daily-driver IPTV player that makes a real, very large Strong IPTV catalog feel organized, fast, and intentionally designed. Wabbit supplies no content. Its product value is user-controlled sources, unified or source-scoped browsing, favorites, ordered mixed custom groups, conservative duplicate handling, and a polished desk-and-couch viewing experience.

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
- Genuine duplicates may share one library identity while retaining each playable source variant. Ambiguous items remain separate.
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

1. Pinned custom groups in user-defined order
2. Favorites when nonempty
3. Continue Watching when nonempty
4. Recently Watched when nonempty

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
- Secondary click or a context/menu action exposes Favorite, Add to Group, and source-variant actions.
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
4. **Organization:** favorites, library identities, custom groups, Home pins, and merge/unmerge
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

### Duplicate rule

- Start one `library_item` per imported `catalog_item`.
- Auto-merge only on deterministic, high-confidence identifiers such as the same nonempty TVG/external identifier with compatible media type.
- Do not build fuzzy or ML matching.
- Keep every source member as a visible variant.
- Removing or disabling a source cannot destroy another source's variant or the user's custom group.

### Playback rule

- One `PlaybackManager` owns active sessions and the selected audible session.
- One quiet retry is allowed for a failed stream; then show redacted technical diagnostics and available source variants. Dispose the prior transport before retrying.
- Parse a provider-reported connection limit when available. Otherwise assume one until the user sets a local override.
- Every new transport, including a retry or source-variant switch, passes source-limit admission after the prior transport is disposed. Multiview admission is checked before opening another provider stream.
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

- Final visuals, multi-source unification, M3U, custom groups, automatic duplicate merging, or advanced playback

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

**Acceptance gate**

- Every primary screen is reachable and usable with keyboard/remote alone.
- Mouse-only hover is not required for any action.
- Back/Escape and focus restoration are intentional across menus, details, and playback.
- Large grids do not render the entire catalog at once or lock the UI during artwork loading.
- The rendered app matches the approved direction at the target Windows viewport and passes the bounded design review with no unresolved material navigation or hierarchy defect.

**Not in this phase**

- Visual experiments outside the approved direction or a generalized component library unrelated to current screens

---

### Phase 4 — Personal Organization and Unified Identities

**Objective:** deliver Wabbit's primary differentiator.

**Work**

1. Favorites backed by `library_items`.
2. Create, rename, delete, reorder, pin, and unpin mixed custom groups.
3. Add an item to a group from a card, detail view, or search result.
4. Pin groups to Home in explicit user order.
5. Introduce deterministic high-confidence auto-merge.
6. Show all source variants for a merged identity.
7. Keep ambiguous matches separate.

**Acceptance gate**

- Favorites and custom group order survive refresh and restart.
- One group can contain and display live, movie, and series items.
- Pin/unpin changes Home without deleting the group.
- Removing an item from a group never removes it from its source.
- A merge retains every playable variant.
- No fuzzy auto-merge combines merely similar titles.

**Not in this phase**

- Smart/rule-based groups, recommendations, metadata enrichment, or ML matching

---

### Phase 5 — Playback, PiP, and Multiview

**Objective:** complete the required advanced viewing experience within measured provider and hardware limits.

**Work**

1. Finalize player controls, audio/subtitle selection, fullscreen, and movie/episode resume state.
2. Add one quiet retry followed by a diagnostics surface with a redacted error and alternate source variants.
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
- Retry and source-variant attempts dispose their prior transport and pass the same connection-admission check.
- A stream failure never enters an unbounded reconnect loop.

**Not in this phase**

- Detached native-window PiP, 2x2 multiview, casting, transcoding, downloads, or DVR

---

### Phase 6 — Windows Daily-Driver Gate

**Objective:** prove Wabbit is ready for sustained personal use rather than expand the feature list.

**Work**

1. Add the user-selectable startup target.
2. Run real Strong regression passes for add, refresh, browse, search, organize, play, PiP, and multiview.
3. Test a representative M3U URL and local M3U file.
4. Run focused unit tests for parsing, migrations, deterministic merge rules, group ordering, and playback connection admission.
5. Run focused widget/integration tests for the primary remote navigation flows.
6. Run Flutter analysis, tests, a release build, and the bounded Impeccable finish workflow.
7. Fix material daily-driver defects; do not begin future-platform or deferred-feature work.

**Acceptance gate — Windows V1**

- A fresh install can add each supported source form and play supported content.
- The real large catalog stays responsive through refresh, search, and browsing.
- Unified/source scopes, favorites, mixed custom groups, Home pins, and deterministic merging persist correctly.
- PiP and two-view multiview meet the recorded behavior.
- All primary flows work from keyboard/remote with visible focus and predictable Back/Escape.
- No source username, password, or credential-bearing playlist URL appears in source control, ordinary logs, or committed fixtures. Provider-supplied M3U item URLs remain confined to the local catalog.
- Required checks pass and the lead has independently inspected the final diff and exercised the core flows.

---

### Phase 7 — Live Guide (Not Scheduled)

Begin only after Windows V1 is accepted and the user explicitly activates the phase.

1. Import provider EPG data where an active source exposes it.
2. Add an optional XMLTV URL for M3U sources only when needed by a real source.
3. Match programs to channels using provider identifiers before narrow name fallbacks.
4. Add Now/Next and a simple remote-friendly timeline guide.
5. Keep missing or malformed guide data independent from catalog refresh and channel playback.

This phase does not include recording, reminders, catch-up, archival behavior, or elaborate guide customization.

---

### Phase 8 — Future Platforms (Not Scheduled)

Begin only after Windows V1 is accepted and the user explicitly activates the phase.

1. Android TV and Fire TV platform setup, remote focus verification, Android Back behavior, and playback validation
2. macOS platform setup, window behavior, keychain configuration, and playback validation
3. Platform-specific visual adaptation where system conventions require it
4. Reuse the shared Dart catalog and source layers; add only the smallest platform adapters required

This phase does not automatically include mobile-phone layouts, store submission, cloud synchronization, or distribution automation.

## 8. Verification Strategy

### Automated checks with high value

- Xtream and M3U parser fixtures, including the few malformed forms observed in real use
- SQLite migration tests
- Refresh idempotence and last-good rollback
- Custom group order and persistence
- Deterministic merge/unmerge invariants
- Search against a generated large fixture
- Playback connection-limit admission
- Essential keyboard/remote focus flows

### Manual evidence

- Real Strong add/refresh/playback results
- Import, search, first-play, CPU, and memory observations on the actual Windows machine
- Screenshots for the Impeccable visual review
- PiP and multiview behavior on the target display and hardware

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
- Its catalog is per-source and does not model unified identities with retained variants.
- Its playback surface is single-player and does not supply Wabbit PiP or multiview.
- Its current credential storage and generated stream URLs are not behavior to inherit.

Default decision: implement fresh and link to Fred in project acknowledgements as design/protocol research. If future work copies Fred expression rather than protocol behavior, record the exact upstream commit and paths in third-party notices before merging it.

Reference: [Fred TV Next](https://github.com/Fredolx/fred-tv-mobile)

## 10. Deferred Work

Not part of Windows V1:

- Detached always-on-top native PiP window
- 2x2 or larger multiview
- Recording, timeshift, and catch-up
- Provider failover automation beyond user-visible variants
- Profiles, parental controls, and cloud sync
- Manual duplicate merge/unmerge controls
- Live EPG/guide until Phase 7 is explicitly activated
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
| 3 — App shell and browsing | Not started |
| 4 — Personal organization | Not started |
| 5 — Playback, PiP, and multiview | Not started |
| 6 — Windows daily-driver gate | Not started |
| 7 — Live guide | Not scheduled |
| 8 — Future platforms | Not scheduled |

## 12. Plan Change Log

| Date | Change | Reason |
|---|---|---|
| 2026-08-16 | Initial master plan recorded | Product discovery and lead reconciliation of three Terra planning reviews |
| 2026-08-16 | Corrected credential locator rules, preserved global mixed-group order, moved EPG after Windows V1, made Phase 1 scale-safe, tightened retry admission, and removed hidden V1 actions | Independent Terra verification findings |
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
