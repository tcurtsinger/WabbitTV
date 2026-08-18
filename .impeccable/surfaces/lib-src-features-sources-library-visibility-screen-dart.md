---
version: 1
slug: "lib-src-features-sources-library-visibility-screen-dart"
primary_target: "lib/src/features/sources/library_visibility_screen.dart"
related_targets: ["lib/src/features/sources/library_visibility_service.dart","lib/src/features/sources/source_management_screen.dart","lib/src/app_shell.dart"]
---

# Library Visibility

**Scope and mode:** Operate surface for Phase 2 local source-library visibility. It owns category and item inclusion preferences for one selected source; it does not alter provider data, credentials, Favorites, custom groups, source scope, playback, or network behavior.

**Audience and job:** A Windows desk or couch user with a large, noisy catalog needs to remove unwanted provider categories or specific items from daily Browse and Search without losing the ability to restore them.

**Direction and memorable moment:** Inherit Quiet Broadcast. The user-confirmed first viewport is **A — Source Category Directory + Item Visibility Ledger** at `.impeccable/mocks/quiet-broadcast-library-visibility-a-directory-ledger.png`; the behavioral authority is `docs/shapes/7-library-visibility.md`.

**Implemented truth:** Settings → Sources exposes Manage visibility for the selected source. It opens a source-local, bounded category directory beside a dense 100-item cursor-paged ledger. A compact media-kind selector and Hidden only recovery filter do not alter provider data. Selecting a category is non-destructive; category and item actions independently hide or restore local inclusion. The directory toolbar adds explicit Hide all and Restore all actions for the selected source and media kind. Each is one atomic category-only update: item flags and Uncategorized remain untouched, and genuinely new provider categories begin Included on refresh. Hide all uses an inline confirmation; Restore all is immediate. The active catalog requires category included **and** item included, so named Browse, All Sources, and Search share the same rule.

**Input and focus:** Mouse, keyboard, and TV remote have equal access. One item row is one focus target; focused controls use the fixed 2 px amber edge without geometry shift. Hide-all confirmation initially focuses Cancel, successful bulk actions return focus to their opposite recovery action, and the shell blocks exit while the local write is pending. Back/Escape otherwise returns through the continuation and restores the Manage visibility launcher focus while refreshing shared catalog scope once on exit.

**Responsive behavior:** Desktop retains the category directory and item ledger. At constrained Windows widths, the directory uses the established in-shell overlay/launcher pattern while the item ledger remains primary; it never becomes a phone layout.

**Verification:** The full serial suite passes 283 tests and `flutter analyze` is clean. Independent Impeccable critique passes and the generic Flutter native-source audit passes 16/16. Three inspected bulk-action renders are recorded in `docs/evidence/phase2-bulk-category-visibility/`, alongside the existing four Library Visibility renders in `docs/evidence/phase2-library-visibility/`. Debug and Release Windows packages pass at `build/windows/x64/runner/Debug/wabbit_tv.exe` (2026-08-18 00:31:48 local) and `build/windows/x64/runner/Release/wabbit_tv.exe` (2026-08-18 00:32:32 local). A write failure leaves visibility unchanged; a post-commit view-refresh failure reports that the local save succeeded and Retry does not repeat the write. On 2026-08-18, the user ran the packaged Release build against Strong, used Hide all for the active Live scope, restored the desired Live categories, confirmed Browse/Search propagation, refreshed, and reported `Perfect, pass`. This is user-supplied runtime evidence; no screenshot, timing, or provider title was recorded. The surface is runtime verified.
