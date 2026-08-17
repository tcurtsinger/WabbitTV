# Phase 0 Evidence — Packaged SQLite and FTS5

**Status:** PASS  
**Date:** 2026-08-16  
**Plan item:** Phase 0 work item 4

## Proof

- Package: `sqlite3` 3.5.1
- Packaged SQLite: 3.53.4
- Database: temporary, file-backed, and opened inside `Isolate.run`
- FTS feature: `CREATE VIRTUAL TABLE ... USING fts5` succeeded
- Deterministic query returned `Night Signal` / Live and `Signal Path` / Movie
- Probe is inert unless compiled with `WABBIT_SQLITE_PROBE=true`
- No provider credentials or network calls are involved

Packaged Windows output:

```text
WABBIT_SQLITE_PROBE: {"status":"ok","sqliteVersion":"3.53.4","matches":[{"title":"Night Signal","kind":"Live"},{"title":"Signal Path","kind":"Movie"}]}
```

## Packaging and checks

- `flutter analyze` — pass
- `flutter test` — 10 tests pass at the time of the spike
- Windows debug build — pass
- Windows release build — pass
- Both packaged outputs contain `sqlite3.dll` (1,710,592 bytes)
- This workstation requires process-scoped `TrackFileAccess=false` for CMake/MSBuild; the workaround does not persist or change project configuration
- Independent Terra review — **PASS**, no P1/P2/P3 findings

## Scope boundary

This proves the package, native Windows bundle, FTS5 availability, file-backed access, and background-isolate execution only. It does not introduce the production catalog schema, migrations, repositories, or an ORM; those remain owned by later plan phases.
