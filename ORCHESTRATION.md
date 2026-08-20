# Wabbit TV Orchestration Authority

**Purpose:** preserve how this project is led, delegated, shaped, verified, and resumed after context compaction.  
**Process owner:** Primary Codex agent (lead/orchestrator)  
**Last updated:** 2026-08-19  

## 1. Recovery Rule

After compaction, handoff, or a new working session, do not rely on chat summaries. Reconstruct current truth in this order:

1. Read `E:\Wabbit TV\ORCHESTRATION.md`.
2. Read `E:\Wabbit TV\PRODUCT.md`.
3. Read `E:\Wabbit TV\PLAN.md`, including the phase status and change log.
4. Read the confirmed shape brief for the active visible feature, if one exists under `E:\Wabbit TV\docs\shapes\`.
5. Identify the active UI target and read its matching persisted Impeccable surface brief under `E:\Wabbit TV\.impeccable\surfaces\`, if present. This later surface-local strategy is separate from the pre-build Shape record.
6. Inspect the actual repository, working tree, current diff, and available verification evidence.
7. Run the installed Impeccable context script once with `--target <active-target>` if it has not already run in the current design-working session. Do not run it without a target when resuming target-specific UI work.
8. Resume only the next unchecked gate in the active phase.

No agent may infer current state from a stale handoff when the files or repository can answer it.

## 2. Authority Map

When instructions conflict, the lead applies this order:

1. The user's current explicit instruction
2. `PRODUCT.md` for product truth, users, constraints, and durable brand commitments
3. `PLAN.md` for active scope, phase order, technical boundaries, and acceptance gates
4. `ORCHESTRATION.md` for roles, delegation, Shape policy, review, and recovery
5. `DESIGN.md`, approved compositions, and persisted surface briefs for visual-system authority once they exist
6. The confirmed feature Shape brief for local purpose, behavior, states, and acceptance evidence
7. Coherent incumbent implementation and native platform conventions
8. Implementer judgment

A lower authority may resolve an unspecified detail. It may not silently change a higher authority. The lead returns to the user when a conflict would alter product truth, phase scope, or a locked visual decision.

## 3. Lead Role

The primary Codex agent is the manager, not merely another implementer.

The lead must:

- maintain the authority documents and active phase status;
- classify every request against the current phase before work begins;
- decide what should be delegated and define bounded Terra assignments;
- give each Terra agent one concrete outcome, file/subsystem boundary, relevant authority, and required evidence;
- prevent parallel ownership of the same files;
- inspect every substantive result directly rather than trusting an agent summary;
- run or witness the required checks and exercise the relevant user flow;
- reconcile conflicting recommendations and keep only what serves the product;
- stop scope drift, premature optimization, speculative hardening, and architecture for hypothetical needs;
- record durable product, plan, visual, and process changes before depending on them;
- declare a phase complete only after its recorded gate passes.

The lead may implement narrow integration glue or a focused correction directly. Substantive research, implementation, or independent review should be delegated to Terra when it can be bounded usefully. Delegation is not theater: trivial edits do not need an agent, and agent count does not substitute for verification.

## 4. Terra Agent Contract

Terra agents are workers and independent reviewers under the lead.

- They receive exact scope and acceptance evidence.
- They read `PRODUCT.md`, the active `PLAN.md` section, this document, the confirmed Shape brief, and relevant design authority before editing.
- They do not edit `PRODUCT.md`, `PLAN.md`, `ORCHESTRATION.md`, or `DESIGN.md` unless the lead explicitly assigns that document.
- They do not broaden the feature, introduce a framework, or harden hypothetical cases without returning a proposal to the lead.
- They do not overlap file ownership with another active agent.
- They report commands run, observed results, limitations, and exact files changed.
- A fresh Terra reviewer is preferred for material visual work so the implementer's framing does not become the review.

The lead remains accountable for anything an agent produces.

## 5. Mandatory Impeccable Shape Gate

**Every new visible feature must complete `$impeccable shape <feature>` before visible implementation begins.** There are no convenience exceptions for work that appears obvious.

Shape is planning only. It establishes the brief; it does not write feature code.

### What counts as a new visible feature

- a new screen, route, page, detail view, or top-level destination;
- a new user flow such as source setup or custom-group editing;
- a new modal, menu, drawer, overlay, player mode, PiP surface, or multiview surface;
- new navigation, remote focus, keyboard, pointer, or Back/Escape behavior;
- a reusable visible pattern introduced to the application;
- a material hierarchy or interaction change to an existing surface;
- a new user-facing loading, empty, error, diagnostics, recovery, or first-run experience;
- exposing an existing backend capability through a new interaction.

### What does not require a new Shape

- backend, database, parser, playback-engine, fixture, test, or build work with no new visible behavior;
- implementation already covered by a confirmed Shape brief;
- a defect fix that restores the confirmed brief without changing behavior;
- a narrow spacing, alignment, or copy correction that does not alter hierarchy, interaction, meaning, or state.

If classification is genuinely uncertain, treat the work as visible and Shape it. Closely coupled screens in one coherent user flow may share one Shape brief; individual buttons and widgets do not each require ceremonial briefs.

### Shape brief contract

The confirmed brief must capture only what the builder must not invent:

1. feature name, plan phase, audience/job, and primary outcome;
2. target surfaces and explicit in/out boundary;
3. real content/data ranges and material states;
4. interaction, remote/keyboard focus, Back/Escape, and feedback behavior;
5. hierarchy/direction, inherited visual authority, and what remains unchanged;
6. acceptance evidence;
7. user confirmation date and status.

After confirmation, the lead records the durable brief at:

`E:\Wabbit TV\docs\shapes\<phase>-<feature-slug>.md`

Suggested status values: `Draft`, `Confirmed`, `Implemented`, `Verified`.

No visible implementation task may be dispatched until the relevant brief is `Confirmed`.

## 6. Visible Feature Lifecycle

1. **Orient:** lead reads the authority files, verifies repository state, and confirms the active phase.
2. **Shape:** run the installed `$impeccable shape` flow; ask only questions that change the experience.
3. **Resolve direction inside Shape when needed:** for a new surface or visual world, follow Impeccable new-work direction and composition decision before finalizing the Shape brief. A local addition inherits the established world.
4. **Confirm and record:** Shape returns the complete brief, including the selected/inherited direction; the user confirms it, then the lead writes the durable Shape file.
5. **Prepare:** immediately before UI edits, load the installed `craft-floor.md` guidance and representative visual truth.
6. **Delegate:** lead assigns bounded Terra implementation packets with non-overlapping ownership.
7. **Integrate:** lead reads the diff and relevant flow, runs checks, and renders/exercises the feature.
8. **Review:** use a fresh Terra/Impeccable finish review for material screens and flows. Small extensions receive a detached brief/render review and roll their full review into the phase gate.
9. **Refine once:** batch material fixes, confirm once, and stop. Do not enter open-ended polish loops.
10. **Record:** update Shape status, phase evidence, the matching Impeccable surface brief, and visual authority required by Impeccable. Update `DESIGN.md` only from implemented visual truth.

## 7. Impeccable Tool Policy

The installed skill's command reference is execution authority. Online documentation is used to understand intent and current evolution, not to silently substitute behavior from an uninstalled version.

| Tool or flow | Use in Wabbit TV | Do not use for |
|---|---|---|
| `$impeccable` with no command | Present context-aware recommendations when the user asks what Impeccable should do next; recommendations require confirmation. | Silently choosing or running a command. |
| `init` | Durable product/platform truth. Completed in `PRODUCT.md`; revisit only when that truth changes. | Routine feature planning or visual details. |
| `shape` | **Mandatory before every new visible feature.** | Invisible work or faithful defect repairs. |
| New-work flow | After Shape when creating a new surface, visual world, or approved replacement. Obtain direction/composition approval before code. | A small local addition that inherits an established surface. |
| `craft` | Deprecated installed alias for ordinary new-work behavior; understand it only for compatibility. | New project procedure; use mandatory Shape plus the current new-work flow instead. |
| `document` | After the first coherent implemented visual world, or when coherent UI exists without accurate `DESIGN.md`. | Speculating a design system before implementation or silently overwriting truth. |
| `extract` | When a real repeated token/component/pattern should become shared and the active feature needs it. | Preemptive design-system or component-library construction. |
| `critique` | Functionally complete material screens/flows that need an honest design-quality diagnosis. | Replacing Shape or evaluating unfinished work. |
| `audit` (native) | Use only the generic Flutter-source checks relevant during Windows phases: accessibility/focus, performance, and theming. The lead separately verifies Windows mouse, keyboard, remote, windowing, scaling, and rendering. Do not score iOS/Android conformance or adaptivity until those platforms enter the active plan. Audit reports; it does not fix. | The web audit/detector assumptions or a claim that Impeccable certifies Windows conventions. |
| `polish` | Final bounded refinement after a feature is functional and audited/reviewed. | Mid-build work, redesign, or unfinished TODOs. |
| `harden` | Narrow, observed real-catalog problems: long titles, actual provider failures, overflow, empty/error/recovery states. | Generic threat modeling, exhaustive hypothetical edge cases, or security theater. |
| `onboard` | First source setup, no-source Home, setup guidance, and empty-state path to first playback. | Routine settings or unrelated screens. |
| `adapt` (native) | When a real additional device/window/platform context enters the active plan. | Premature Android TV, Fire TV, or macOS work. |
| `optimize` | Only after measurements show import, search, artwork, scrolling, render, or playback UI problems. | Premature performance architecture. |
| `clarify` | Confusing setup copy, source errors, diagnostics, labels, and recovery instructions. | Rewriting factual product claims without approval. |
| `layout`, `typeset`, `colorize` | A named hierarchy, spacing, type, or color defect found in a real render. | Unscoped "make it nicer" work. |
| `quieter`, `distill`, `bolder` | A specific user/critique finding calling for restraint, simplification, or deliberate amplification. | Changing Wabbit's established direction by implementer taste. |
| `animate`, `delight` | Purposeful state feedback or restrained personality in onboarding/loading/empty states. | Decorative routine-viewing motion or mascot saturation. |
| `overdrive` | Only an explicitly user-approved expressive surface that can justify it. | Default Wabbit product UI. |
| `live` | Not used for native Flutter UI. Reconsider only if Wabbit later owns a real web surface. | Windows Flutter screens. |
| Detector and design hooks | Not enabled for the Flutter codebase; the installed detector is HTML/CSS-oriented and does not cover Dart. | Pretending a web scan verified native UI. |
| `doctor` | Explicit maintenance when artifact/schema/config drift is reported or the user asks what is stale. | Incidental repair during design work. |
| Pin/unpin shortcuts | Only when the user explicitly wants a standalone shortcut for an Impeccable command. | Project behavior, phase automation, or an implicit configuration change. |

## 8. Bounded Verification

For each visible feature, verification is proportional but real:

- builder runs focused static checks/tests and provides a representative render or screenshot;
- lead inspects the actual diff and exercises the primary mouse/keyboard/remote flow;
- lead compares the render and behavior with the confirmed Shape brief and current design authority;
- an independent reviewer checks material new screens/flows;
- fixes are batched, rendered again once, and closed or reported honestly;
- phase-level generic Flutter-source audit, Windows-specific manual verification, and final polish cover smaller extensions together;
- iOS/Android platform-conformance and adaptivity scoring stays inactive until those platforms are activated in the plan.

Do not claim success from passing tests alone, from screenshots alone, or from an agent's statement.

## 9. Phase Discipline

- `PLAN.md` holds the only active phase status.
- A new idea outside the phase goes to Deferred Work; it is not built opportunistically.
- A phase gate requires the recorded automated and manual evidence.
- Failed gates produce focused corrective work inside the phase, not a redesign of the plan.
- Product/scope changes are recorded before implementation and require the user's decision.
- The no-overengineering rule remains binding throughout Impeccable work. Craft quality is not permission to add product scope or architectural machinery.

## 10. Impeccable Documentation Baseline

Official material reviewed on 2026-08-16:

- [Official docs index](https://impeccable.style/docs/)
- [Shape](https://impeccable.style/docs/shape/)
- [New work](https://impeccable.style/docs/new-work/)
- [Audit](https://impeccable.style/docs/audit/)
- [Critique](https://impeccable.style/docs/critique/)
- [Polish](https://impeccable.style/docs/polish/)
- [Designing with Impeccable](https://impeccable.style/designing/)
- [Official Impeccable source](https://github.com/pbakaus/impeccable)

### Version rule

- Installed skill: `4.0.4` at `C:\Users\txtra\.agents\skills\impeccable\SKILL.md`
- Official current skill observed online: `4.1.1`
- The installed skill and its local references govern execution until the user authorizes an update task.
- Do not update Impeccable as a side effect of Wabbit feature work.
- If an update is authorized, treat it as maintenance: check/update the tool, inspect the changed guidance, run Impeccable Doctor deliberately, and reconcile any artifact drift before resuming product work.

## 11. Current Handoff

- Product initialization: complete
- Master planning baseline: complete
- Current phase: Phase 6 — Windows Daily-Driver and Xtream Live Guide Gate — **Complete**; implementation, final automation, independent closure, synthetic renders, Windows Debug/Release packages, corrected packaged Strong Guide behavior, representative M3U URL/local-file readiness, and final daily-driver user acceptance passed. Windows V1 is complete
- App shell Shape: confirmed as **Quiet Broadcast** in `docs\shapes\0-app-shell.md`
- Home Shape: confirmed as **Personal Shelves** in `docs\shapes\0-home.md`
- Approved first viewport: composition **B — Focused Shelf** at `.impeccable\mocks\quiet-broadcast-home-b-focused-shelf.png`; its sidecar records user approval and `.impeccable\surfaces\lib-main-dart.md` carries the implementation inventory
- App shell/Home implementation: verified, with independent Impeccable **PASS**, eight widget tests, three-state render evidence, and a packaged Windows debug build
- Flutter SDK: `3.47.0` installed at `C:\Users\txtra\tools\flutter-sdk-3.47.0\flutter`; this workstation requires process-scoped `TrackFileAccess=false` for Windows CMake/MSBuild builds
- Packaged SQLite/FTS5 spike: verified **PASS** in `docs\evidence\phase0-sqlite-fts5.md`
- Strong playback/account-limit probe: verified **PASS** in `docs\evidence\phase0-strong-playback-probe.md`; Shape status is `Verified`
- Real Strong result: authentication active, max 1 / active 0; category-bounded live, movie, and episode playback passed with nonzero dimensions and screenshot evidence; two-stream correctly skipped
- Synthetic 50k catalog scale probe: verified **PASS** in `docs\evidence\phase0-catalog-scale.md`; packaged baseline imported in 172 ms, searched in 4 ms, and retained a positive main-isolate heartbeat
- Playback probe visual evidence: `build\verification\phase0-playback-probe-no-credentials.png`; approved direction remains B — Split Console
- Plugin build note: standard Flutter plugin builds need Windows Developer Mode; this non-elevated workstation build was proven with generated workspace-local junctions plus process-scoped `TrackFileAccess=false`, without changing system settings
- Source setup Shape: confirmed as **Source Ledger** in `docs\shapes\1-source-setup.md`; approved composition is **C — Focused Ledger with Three-Stage Dock** at `.impeccable\mocks\quiet-broadcast-source-ledger-c-stage-dock-approved.png`
- Phase 1: complete, including the real Strong import, browse, playback, and restart gate recorded in `PLAN.md` and `docs\evidence\phase1-*.md`
- Source Management Shape: confirmed as **A — Source Directory + Detail Ledger** in `docs\shapes\4-source-management.md`; the approved first viewport is `.impeccable\mocks\quiet-broadcast-source-management-a-directory-detail.png`, including the quiet outlined Add source action and Save-and-refresh edit behavior
- Source Management implementation: verified through the bounded controller seam, independent critique and generic Flutter native-source audit, synthetic Flutter render evidence, and a packaged Windows debug build; source lifecycle coverage is included in the current 228-test serial suite
- Catalog Scope Shape: confirmed as **A — Header scope menu** in `docs\shapes\5-catalog-scope.md`; approved composition is `.impeccable\mocks\quiet-broadcast-catalog-scope-a-header-menu.png`
- Local Search Shape: confirmed as **A — One mixed ledger** with **A — Minimal TV keyboard** in `docs\shapes\6-local-search.md`; approved compositions are `.impeccable\mocks\quiet-broadcast-local-search-a-mixed-ledger.png` and `.impeccable\mocks\quiet-broadcast-local-search-a-tv-keyboard.png`
- Catalog Scope and Local Search implementation: complete through bounded local-query seams, shared persistent scope, a local-only mixed ledger, and exact-source Xtream/M3U playback handoff with M3U headers. Format and `flutter analyze` are clean, the full serial suite passes 228/228, and the Windows debug build passed at `build\windows\x64\runner\Debug\wabbit_tv.exe`.
- Catalog Scope and Local Search visual/review evidence: five deterministic network-free actual-Flutter renders passed and were inspected in `docs\evidence\phase2-catalog-search`; independent Impeccable critique plus bounded polish passed. The generic Flutter source audit's three initial P1 browse races were fixed, and final closure reports no remaining P1/P2 findings.
- Real Strong refresh correction: the first packaged refresh exposed a quadratic per-item FTS delete and transient local-read failure behavior. The corrected path uses one stage-level FTS clear, bounded SQLite wait/WAL behavior, last-local-view preservation, and source-scoped abnormal-worker recovery. Analyze, the serial 228/228 suite, the Windows debug build, and an independent no-P0/P1 audit pass. The corrected build recovered the existing last-good Strong catalog without reimport, refreshed successfully in about 20 seconds, and retained good browse/navigation and final source state.
- Library Visibility Shape: user-confirmed **A — Source Category Directory + Item Visibility Ledger** in `docs\shapes\7-library-visibility.md`; the approved viewport is `.impeccable\mocks\quiet-broadcast-library-visibility-a-directory-ledger.png`.
- Library Visibility implementation: migration v6 keeps local `source_groups.hidden` and `catalog_items.hidden` choices across refresh; named Browse, All Sources, and Search share the effective category AND item rule. The Settings continuation restores its launcher focus and refreshes shared scope only on return. Format and `flutter analyze` pass; the serial suite passes 268 tests. Independent critique and generic Flutter native-source audit pass 16/16. Four inspected synthetic renders and sanitized copy-only Strong-scale timings are recorded in `docs\evidence\phase2-library-visibility\README.md`. Debug and Release packages passed at `build\windows\x64\runner\Debug\wabbit_tv.exe` and `build\windows\x64\runner\Release\wabbit_tv.exe`.
- Bulk Category Visibility Shape: user-confirmed directory-toolbar Hide all/Restore all extension in `docs\shapes\8-bulk-category-visibility.md`; approved composition is `.impeccable\mocks\quiet-broadcast-bulk-category-visibility-a-directory-toolbar.png`.
- Bulk Category Visibility implementation: one atomic category update is scoped to the selected source and kind; item flags and Uncategorized remain untouched, and new categories default Included. Hide all uses inline confirmation, Restore all is immediate, and the shell prevents exit while persistence is pending. Write failure reports no change; post-commit refresh failure reports the local save and retries only the view refresh. `flutter analyze` is clean, the full serial suite passes 283 tests, independent critique passes, and the generic Flutter native-source audit passes 16/16. Three inspected synthetic renders are recorded in `docs\evidence\phase2-bulk-category-visibility\README.md`. Debug and Release builds passed at `build\windows\x64\runner\Debug\wabbit_tv.exe` (2026-08-18 00:31:48 local) and `build\windows\x64\runner\Release\wabbit_tv.exe` (2026-08-18 00:32:32 local).
- Packaged Strong Library Visibility gate — **PASS (user-supplied, 2026-08-18):** the user ran the Release build, hid all categories for the active Live scope, restored the desired Live categories, confirmed Browse/Search propagation, refreshed, and reported `Perfect, pass`. No screenshot, timing, or provider title was recorded.
- Phase 2 gate: **Complete**. Connector/M3U lifecycle behavior remains automated coverage and is not relabeled as a real M3U-provider run.
- Phase 3 Shape: verified as Quiet Broadcast browsing finish with **A — Direct Directory + Ledger** for read-only My Library in `docs\shapes\9-phase3-browsing-experience.md`.
- Phase 3 implementation: runtime Home and Recently Watched, read-only Favorites/custom-group browsing, bounded visible-row artwork, truthful Browse/Search source state, compact Movie/Series continuations, and exact focus restoration are complete. `flutter analyze` is clean; the full serial suite passes 360/360; nine credential-free renders were inspected; independent Impeccable and native-source closure reviews report no P1/P2 findings; and the Windows Release build passed at `build\windows\x64\runner\Release\wabbit_tv.exe` (2026-08-18 16:05 local).
- Packaged Strong Phase 3 gate — **PASS (user-supplied, 2026-08-18):** the initial Release exercise exposed focus-only artwork loading. Mounted virtual rows now begin after a short dwell without a click, while the loader remains cache-bounded, cancellation-aware, and limited to two requests. The rebuilt Release was accepted with `Ok way better. Pass`; no provider title, locator, or credential was recorded.
- Phase 4 Shape: confirmed as **A — Direct Organizer Drawer** in `docs\shapes\10-phase4-personal-library-organization.md`. Favorites may be pinned to Home, one save may update Favorite plus multiple checked groups, and automatic/manual duplicate merging is explicitly excluded.
- Phase 4 implementation: schema v10 and bounded local organization APIs preserve Favorites, ordered mixed custom groups/items, and one explicit Favorites/group Home-shelf order against stable library identities. The shared organizer, My Library Create/Manage actions, group-management continuation, and pinned Home shelves are assembled without provider mutation or merging. Six credential-free actual-Flutter renders pass and were inspected at 1265×713 and 600×713; format and analyze are clean; the serial suite passes 400/400; Debug and Release Windows builds pass; and the final independent native-source re-audit reports no remaining P1/P2 findings. The synthetic boundary and render-discovered corrections are recorded in `docs\evidence\phase4-personal-library-organization\README.md`.
- Packaged Strong Phase 4 gate — **PASS (user-supplied, 2026-08-18):** the user ran the Release checklist covering one atomic Favorite/two-group Save, membership visibility, pinned Home order before Recently Watched, non-destructive unpin and membership removal, refresh/restart persistence, and mouse/keyboard/remote return behavior, then reported `Pass, confirmed`. No provider title, locator, credential, screenshot, or timing was recorded.
- Phase 5 Shape: confirmed on 2026-08-19 as automatic resume with Start over, Corner Signal in-app PiP with stop-confirm before Settings/management, and active Live → existing Live directory → equal two-up multiview. `docs\shapes\11-phase5-playback-pip-multiview.md` is the implementation contract; no fuzzy/title-derived source variants are permitted.
- Phase 5 implementation: schema v11 persists truthful Movie/Episode watch progress; eligible playback automatically resumes with Start over and near-finished restart behavior. One `PlaybackManager` owns session lifecycle, quiet retry, tracks, audible-session selection, and admission using local override → provider-reported limit → conservative one. Corner Signal remains a fixed-corner 16:9 in-app overlay on the six approved content destinations, Settings/management uses stop-confirmation, and admitted Live multiview is equal side-by-side with one shared deck and one audible tile. Source Settings exposes Automatic, 1, and 2 without claiming provider allowance.
- Phase 5 bounded evidence: format, analyze, and diff checks are clean; the serial suite passes 469/469; Windows Debug and Release builds pass; eleven synthetic actual-Flutter renders and the targeted corrected constrained recapture pass and were inspected. Independent Impeccable review reports **PASS**, and the generic Flutter native-source audit passes 16/16. Evidence and its synthetic/local boundary are in `docs\evidence\phase5-playback-pip-multiview\README.md`.
- Phase 5 packaged measurement attempt: a credential-free, network-free Release fixture tried generated local lavfi through real `media_kit`, but the native input produced no video. The ignored aggregate `build\verification\phase5-windows-packaged-measurement.json` records the attempt as unsupported, zero sessions after teardown, and no lingering measured process; no PiP, two-surface, CPU, memory, decoder, startup, transition, or stability claim is made from it. The normal production Release was rebuilt successfully afterward and replaced the temporary fixture entry point.
- Packaged Strong/Windows Phase 5 gate — **PASS (user-supplied, 2026-08-19):** the user ran the packaged checklist and reported `Ok pass`. Strong's reported one-stream allowance correctly produced the pre-open second-stream admission block; actual two-stream success was not exercised and is conditionally unavailable without a genuinely permitted source. No provider title, timing, CPU or memory value, decoder detail, available-track result, or two-stream success was recorded or inferred. The user accepted the bounded/conditional evidence boundary and Phase 5 is complete.
- Phase 6 Shape: confirmed on 2026-08-19 as a dedicated `Guide` rail destination after Live, a classic channel-by-time matrix scoped to one enabled Xtream source/category with `All Live`, quiet exact Now/Next, lazy bounded `get_short_epg`, UTC persistence/local display, and exact Last channel automatic startup with a truthful Home fallback. `docs\shapes\12-phase6-xtream-live-guide-startup.md` remains the implementation contract; provider and packaged claims require separate evidence.
- Phase 6 implementation: schema v12 persists exact source/provider-channel EPG state, bounded last-good programs, and app-level startup preferences. Xtream short-guide acquisition is lazy and viewport-bounded, stores UTC truth, preserves catalog/playback independence, applies source-wide credential/authentication retry truth, and never adds M3U XMLTV, fuzzy matching, merging, or bulk full-guide acquisition. Live rows read quiet cached Now/Next; the dedicated Guide implements the confirmed source/category matrix and tuning/return behavior; General Settings implements Home, stable Previous screen, and exact usable-video Last channel with a truthful Home fallback.
- Packaged Strong Phase 6 discovery/correction checkpoint — **DEFECT FOUND AND CORRECTED (user-discovered, 2026-08-19):** the packaged run settled 149 channel states: 148 `empty`, 1 `available`, 0 `error`, and 0 `refreshing`, with 4 cached programs overlapping the Guide window. This proves Strong short EPG works sparsely and that the run left no stuck lease; it does not accept the original presentation. The run exposed a real repeated/stuck `Preparing` defect from viewport-map replacement and global status derivation, compounded by lifecycle/parser-truth gaps. The corrected tree uses active-viewport status, a three-view by 40-row LRU capped at 120 IDs, malformed-versus-valid-empty separation, prompt generation-safe cancellation and lease release, explicit manual Retry that bypasses only persisted errors, typed local-persistence recovery, and corrected paging/category/`Go to now` lifecycle.
- Corrected packaged Strong Guide rerun — **PASS (user-supplied, 2026-08-19):** after running the corrected Release, the user reported `Ok pass`. At the user-observed level, this closes the repeated/stuck `Preparing`, reverse-scroll, and rapid category/scope packaged behavior. No provider title, timing, screenshot, program-coverage result, resource measurement, or credential was recorded or inferred.
- Phase 6 bounded evidence: formatting checked 100 files with 0 changes; analysis is clean; the full serial suite passes 581/581 in 80.125 seconds; and diff-check passes. Independent closure and the picker correction review report **PASS**. The seven-state credential-free actual-Flutter harness passes 7/7; evidence and boundaries are in `docs\evidence\phase6-xtream-live-guide\README.md`.
- Phase 6 Windows package checkpoint — **PASS:** the established process-scoped `$env:TrackFileAccess='false'` workstation workaround enabled a cold/default Debug build in 42.132 seconds at `build\windows\x64\runner\Debug\wabbit_tv.exe` (1,140,736 bytes; 2026-08-19 14:22:29.022 -05:00; SHA-256 `77C8EF3FA4884EC9470828BC0D8347C12292D600818D73C1ADE51F1054AFF341`) and a normal/default Release build in 48.068 seconds at `build\windows\x64\runner\Release\wabbit_tv.exe` (183,296 bytes; 2026-08-19 14:23:51.199 -05:00; SHA-256 `D112C13F8FF39927C50A86A0E4CE96F890E99DF1811E120164A81A971BEB2B7F`). Both used `FLUTTER_TARGET=lib/main.dart`; decoded defines contained only standard Flutter metadata and no WABBIT fixture/probe defines. No Flutter, Dart, Wabbit, MSBuild, or compiler process remained.
- Packaged local M3U picker correction — **PASS for selection only (2026-08-19):** the user reported that `Choose M3U file` froze the packaged app in Windows `Not Responding` and required Alt+F4. Source tracing proved Wabbit performs no playlist read before selection; the path is acquired first and local-file acquisition starts only after `Connect`. The UI-only correction adds single-flight admission, an `endOfFrame` pending-state paint before the owned Windows modal, blocked conflicting actions, redacted retryable failure truth, and exact focus restoration; it does not modify the adapter, plugin, runner, parser, or import path. Independent review reports **PASS**. In the rebuilt Release, the lead saw the owned dialog and pending state, canceled with Escape back to a responsive exact `Choose M3U file` focus, reopened, selected the Downloads test playlist, and saw the field populate. The app closed without importing or adding a source, so that bounded exercise did not prove source/import/browse/playback; the full flow was accepted separately afterward.
- Corrected packaged local-file chooser acceptance — **PASS (user-supplied, 2026-08-19):** after being asked to retry the corrected local M3U file flow in the new packaged Release, the user replied exactly `Pass`. This accepts the picker defect correction and corrected chooser flow only. No steps, timing, screenshot, or import/browse/playback result was supplied or inferred.
- Final M3U and daily-driver acceptance — **PASS (user-supplied, 2026-08-19):** the representative M3U URL was previously user-reported to have worked great. After the required corrected local-file flow was defined exactly as `Connect → import → browse → playback`, the user replied exactly `Yes, full flow passed`. This closes representative M3U readiness and the final daily-driver user gate. No timings, screenshots, titles, resource measurements, provider coverage, or credential-bearing evidence are inferred beyond those supplied statements.
- Post-V1 left-sidebar polish decision — **CONFIRMED (2026-08-20):** the user authorized all five bounded critique findings, chose remote/accessibility correctness rather than visual-only refinement, and chose Settings bottom-anchored behind a restrained separator. The agreed packet covers the shell-level remote Menu route without stealing contextual Menu actions, a persistent non-amber selected-location marker, complete high-text/short-height labels with scroll/reveal, single authoritative semantic announcements, and quiet pointer hover/click affordance plus utility separation.
- Post-V1 left-sidebar polish implementation — **COMPLETE; USER APPROVED:** the initial independent critique found the missing Menu route, weak collapsed selected orientation, incomplete high-text/TV-distance behavior, duplicate semantics, and flat pointer/utility hierarchy. All five were corrected. Final independent review reports **PASS** with no remaining P0/P1/P2 findings; formatting checked 100 files with 0 changes, analysis is clean, the full serial suite passes 587/587 in 81.055 seconds, and diff-check passes. The credential-free actual-Flutter sidebar harness passes 4/4 with inspected evidence in `docs\evidence\sidebar-polish\README.md`.
- Post-V1 left-sidebar package checkpoint — **BUILD PASS; USER GATE CLOSED:** Debug completed in 46.187 seconds at `build\windows\x64\runner\Debug\wabbit_tv.exe` (1,140,736 bytes; 2026-08-20 10:36:58.778 -05:00; SHA-256 `41CA311CF6D1DE92A5FA16B45E1E1B5A817B09F80C3945071E0E2639AB529919`) and Release completed in 47.954 seconds at `build\windows\x64\runner\Release\wabbit_tv.exe` (183,296 bytes; 2026-08-20 10:38:04.592 -05:00; SHA-256 `411B7E51BEA6779EFF51A5E3C97356066B59B142D6FC2479986A7F25A2603E1B`). Both target `lib/main.dart` with no custom WABBIT defines. After presentation of the corrected Release and evidence, the user replied exactly `Approved`; no extra interaction details are inferred from that concise acceptance.
- Final roadmap: Phase 6 combined the Windows daily-driver gate with an Xtream-only provider EPG Live Guide and is **Complete**. Windows V1 is complete. No M3U XMLTV URL/file guide input or guide path is allowed. Recording, reminders, catch-up, DVR, archival behavior, and elaborate guide customization remain excluded.
- After Phase 6, UI/UX polish continues as ongoing unnumbered post-V1 maintenance, not Phase 7. Android TV, Fire TV, macOS, and platform-specific adaptations remain an unscheduled deferred backlog, not additional numbered phases.
- Shared foundation: transactional last-good refresh, durable source lifecycle, M3U connectors, and bounded multi-source/search query APIs remain implemented without scheduling or a connector framework
- Application scaffold/code: active
