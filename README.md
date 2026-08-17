# Wabbit TV

Wabbit TV is a Windows-first, local-first IPTV player for content users provide themselves. It supplies no playlists, channels, movies, or series. Xtream source setup, local catalog import, and basic Live/Movies/Series browsing are implemented; M3U URLs and local M3U files remain later work.

## Current status

Phase 0 feasibility and Phase 1 are complete. Phase 1 includes the **Quiet Broadcast** shell and Home, Xtream Source Setup, OS-backed credentials, background catalog import, bounded SQLite browsing, minimal Movie/Series continuations, and the single-session production player. A maintainer-local Strong production run imported the source, browsed all three catalogs/categories, played one Live item, Movie, and Episode, verified restart persistence without credential re-entry, and recorded no provider-identifying data or credentials.

## Run on Windows

Install Flutter 3.47.0 stable or a compatible Flutter SDK, then:

```powershell
flutter pub get
flutter run -d windows
```

### SQLite / FTS5 packaged probe

The default application path does not run a database probe. To run the
Phase 0 packaged SQLite + FTS5 proof without changing the visible Home:

```powershell
flutter run -d windows --dart-define=WABBIT_SQLITE_PROBE=true
```

Debug stdout reports one line beginning with `WABBIT_SQLITE_PROBE:`. A
successful result has `"status":"ok"`, a SQLite version, and the deterministic
FTS5 matches `Night Signal` and `Signal Path`.

### Synthetic 50k catalog scale packaged probe

The default application path does not run this baseline. It creates one
file-backed temporary SQLite/FTS5 database in a background isolate, generates
50,000 clearly synthetic Live/Movie/Series records, searches its deterministic
anchor token, then closes and deletes only its own temporary directory. It does
not use real provider data, credentials, playlists, or catalog dumps, and its
timings are recorded baselines rather than optimization targets.

```powershell
$env:TrackFileAccess = 'false'
flutter run -d windows --dart-define=WABBIT_CATALOG_SCALE_PROBE=true
flutter build windows --debug --dart-define=WABBIT_CATALOG_SCALE_PROBE=true
flutter build windows --release --dart-define=WABBIT_CATALOG_SCALE_PROBE=true
```

The packaged diagnostic writes exactly one sanitized line beginning with
`WABBIT_CATALOG_SCALE_PROBE:` containing record counts, import/search timings,
a tiny synthetic anchor sample, database bytes, and main-isolate heartbeat ticks.

### Strong playback packaged probe

The Phase 0 Strong playback probe is a separate diagnostic target; it never
adds a route or control to the ordinary Wabbit application. It asks for the
provider endpoint, username, and password in its local window, keeps them in
memory only, and does not save or log them. Do not pass real credentials through
shell arguments, `--dart-define`, or environment variables.

```powershell
$env:TrackFileAccess = 'false'
flutter pub get
flutter build windows --debug -t lib/src/spikes/phase0/playback_probe_main.dart
flutter build windows --release -t lib/src/spikes/phase0/playback_probe_main.dart
```

Launch the desired packaged executable manually from the matching Debug or
Release runner directory. The probe makes no provider call until **Check
account** is pressed. Its optional two-stream test remains unavailable unless
the provider reports both a known maximum and enough currently available
connections, and the maintainer explicitly starts it.

Normal startup resolves locally persisted runtime state. The Phase 0 Home proof also retains three explicit compile-time previews:

```powershell
# Populated personal shelves.
flutter run -d windows --dart-define=WABBIT_HOME_FIXTURE=populated

# No source is configured.
flutter run -d windows --dart-define=WABBIT_HOME_FIXTURE=no-sources

# Sources exist, but Favorites, groups, and history are empty.
flutter run -d windows --dart-define=WABBIT_HOME_FIXTURE=no-personalization
```

## Basic Browse review fixture

Phase 1 includes an explicit, synthetic, network-free catalog for packaged
visual review. It is not used by normal startup and contains no provider data.
Choose the destination with `live`, `movies`, or `series`:

```powershell
flutter run -d windows --dart-define=WABBIT_BROWSE_FIXTURE=live
flutter build windows --release --dart-define=WABBIT_BROWSE_FIXTURE=live
```

## Production Player review fixture

The Phase 1 player has a separate, synthetic, network-free fixture. It uses the
real player controls and Windows fullscreen port with an in-memory transport
that ignores the stream URI. It is not part of normal startup and does not use
provider data or credentials.

```powershell
flutter run -d windows -t lib/src/spikes/phase1/production_player_fixture_main.dart
flutter build windows --debug -t lib/src/spikes/phase1/production_player_fixture_main.dart
```

## Quality checks

```powershell
dart format lib test
flutter analyze
flutter test
flutter build windows --debug
flutter build windows --release
```

On this workstation, Visual Studio's file tracker stalls during CMake compiler detection. Use the process-scoped workaround below; it does not change the project or persist after the shell closes:

```powershell
$env:TrackFileAccess = 'false'
flutter build windows --debug
```

## Privacy

Wabbit TV has no telemetry or app-controlled network destination. Runtime network activity only contacts a source explicitly configured by the user.

## License

[GNU Affero General Public License v3.0](./LICENSE).
