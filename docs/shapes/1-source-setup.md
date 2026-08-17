# Shape Brief — Phase 1 Source Setup

**Status:** Implemented and verified — packaged, fixture, and real Strong source setup PASS  
**Phase:** 1 — Strong End-to-End Slice  
**Confirmed:** 2026-08-16  
**Implemented:** 2026-08-16  
**Mode:** Operate  
**Inherited direction:** Quiet Broadcast  
**Selected structure:** Source Ledger  

## Job and outcome

A Windows user with an Xtream account needs to connect their first source once, understand what the application is doing, and reach a usable local catalog without provider jargon or setup ceremony. Success is a persisted source whose password is absent from SQLite and ordinary logs, a visible three-stage import, and a clear Source ready handoff to Live, Movies, or Series.

## Scope and boundary

- Home's existing no-source **Add source** action and Settings → Sources enter the same in-shell setup surface.
- Phase 1 supports Xtream only: editable source name, server URL, username, and obscured password with paste and explicit show/hide.
- One **Connect and import** action validates the account and imports Live, Movies, and Series. There is no separate connection test or source-type picker.
- The initial import remains on this surface. It is not a background job and does not require scheduler, notification, or job-history machinery.
- A successful setup ends on **Source ready**, with imported counts and Browse Live / Browse Movies / Browse Series actions. Those actions hand off to their destinations; this Shape does not define the destination list design.
- Excludes M3U URL/file, source roster management, rename/edit/refresh/disable/remove, unified source scope, custom groups, duplicate merging, browse-card design, playback controls, and advanced playback.

## Selected direction and composition

The surface inherits the existing shell and Quiet Broadcast visual authority. **Source Ledger** uses one stable task field rather than a wizard or modal: a restrained header, a centered four-field form, and a full-width low stage dock. The form remains the focal task while the dock carries operational state without moving the layout.

The approved composition is **C — Focused Ledger with Three-Stage Dock**:

- `.impeccable/mocks/quiet-broadcast-source-ledger-c-stage-dock-approved.png`
- `.impeccable/mocks/quiet-broadcast-source-ledger-c-stage-dock-approved.json`

The dock contains exactly three equal cells—Live, Movies, and Series. It does not include a fourth content-neutrality message. Generated icons, placeholder field values, and title-bar details are compositional evidence rather than exact assets; the implementation keeps the real Wabbit shell and uses only synthetic example values in tests and fixtures.

## States and feedback

1. **Entry:** source name defaults to a neutral local label and remains editable; the other fields are empty. The password is obscured by default.
2. **Validation:** missing or malformed values are identified beside the relevant field without destroying other input.
3. **Import:** the three dock cells move through Waiting, Importing, Complete, or Error. Only the active stage uses signal amber. Duplicate submission is disabled.
4. **Cancel:** Cancel stops the initial import and returns to editable setup without creating a partial active source or leaving an orphaned credential.
5. **Failure:** authentication, unreachable-provider, and empty-response failures use concise redacted copy plus a clear retry/edit path. Non-secret values remain available in the current session; the password stays only in memory until a successful commit.
6. **Success:** the dock shows the three imported counts and the task field becomes Source ready with Browse Live, Browse Movies, and Browse Series.

Catalog fetching, parsing, and writes stay away from the UI isolate. The source record and OS-backed secret become durable only when the initial catalog commit succeeds. Later request or playback failures must not erase already imported usable data.

## Interaction and layout

- Full mouse, keyboard, and remote traversal; no hover-only action.
- Focus order follows the visible task: source name → server URL → username → password → password visibility → Connect and import → Cancel.
- Enter/Select activates the focused control. Signal amber identifies keyboard/remote focus and the one primary action.
- Back/Escape while idle returns to the activating Home or Settings control and restores its focus. During import, Back/Escape moves focus to Cancel rather than silently cancelling work.
- The desktop composition retains the persistent rail and stable bottom dock. At constrained Windows widths the form remains one readable column and the three dock cells may stack as one ordered list without changing their sequence or meaning.

## Component and fidelity inventory

| Commitment | Implementation medium |
|---|---|
| Existing title bar, rail, destinations, and focus-return contract | Reuse the implemented Flutter shell |
| Header and four-field form | Semantic Flutter text fields and controls using existing Quiet Broadcast tokens |
| Password visibility | Standard semantic icon control; obscured by default |
| Connect and import / Cancel | Flutter actions; amber primary/focus treatment and dark secondary treatment |
| Three equal desktop stage cells | Flutter layout with thin line dividers and text state; no raster UI |
| Source ready counts and browse handoff | Semantic Flutter text/actions; no provider artwork |
| Errors and progress | Text and state icons only; no raw provider response, URL, credentials, or invented percentages |

## Acceptance evidence

- Mouse, keyboard, and remote-equivalent widget coverage for entry, form traversal, Connect and import, Cancel, errors, Source ready actions, Back/Escape, and focus restoration.
- A real Strong clean-install add proves Live, Movies, and Series counts and preserves the source after restart.
- SQLite inspection proves the password is absent; ordinary captured logs and screenshots contain no credentials or credential-bearing URLs.
- Authentication, unreachable-provider, and empty-response fixtures render the confirmed redacted recovery states.
- Windows render evidence at the approved 1265×713 composition and one constrained width.
- Lead inspection plus an independent Impeccable finish review closes material hierarchy, focus, layout, and truthfulness findings.

## Confirmation record

The user confirmed the one-action connection model, foreground three-stage import with Cancel, Source ready completion state, Source Ledger structure, and composition C on 2026-08-16. The user explicitly removed the proposed fourth dock box so the three media stages share the full width.


## Implementation and verification checkpoint

The confirmed Source Ledger was implemented on 2026-08-16. Its packaged UI and fixture-backed behavior are verified. The ordinary Windows application now routes Home's no-source action and Settings to the same in-shell source surface; it retains Quiet Broadcast's graphite task field, centered form, and exactly three equal Live, Movies, and Series dock cells with no disclaimer cell. Cancel remains left of Connect and import, and keyboard focus/Back-Escape return behavior was exercised in the packaged application.

The implementation uses a cancellable worker-owned initial import, pending-to-ready activation, OS-backed credentials, local SQLite persistence, and sanitized failure states. Local HttpServer/SQLite tests cover 50k synthetic import heartbeat, category linkage, persistence, secret exclusion, credential ordering and cleanup, and bounded forced cancellation. The final ordinary production run on 2026-08-17 started from Wabbit's no-source state, successfully imported Strong, persisted the source, and exposed sanitized totals of 56,712 Live, 176,792 Movies, and 47,253 Series. After closing and reopening, the persisted catalog was immediately available without credential re-entry. No provider secret or provider-identifying data was recorded.

**Checkpoint evidence:** `docs/evidence/phase1-source-setup.md` records source/fixture, final format/analysis/98-test/build validation, and the real Strong source-add/restart closure evidence.
