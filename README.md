<div align="center">

<img src="assets/branding/wabbit-tv-icon.png" alt="Wabbit TV icon" width="112">

# Wabbit TV

**A calm, fast IPTV player for Windows and Android TV that brings your own sources together in one library.**

[![CI](https://github.com/tcurtsinger/WabbitTV/actions/workflows/ci.yml/badge.svg)](https://github.com/tcurtsinger/WabbitTV/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
![Platforms: Windows and Android TV](https://img.shields.io/badge/platform-Windows%20%7C%20Android%20TV-0078D4)
![Flutter 3.47](https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter)

</div>

Wabbit TV turns large Xtream and M3U catalogs into one quiet library built for a TV remote or a keyboard. Live TV, movies and series from all your sources sit side by side, search is instant, and everything stays on your device.

> [!NOTE]
> Wabbit TV supplies **no content**: no channels, playlists, movies or series. Use it only with sources you are entitled to access.

<table>
  <tr>
    <td><img src=".github/readme/home.png" alt="Home with a continue-watching hero, recently watched and a pinned group"></td>
    <td><img src=".github/readme/browse.png" alt="Movies as a poster wall with categories"></td>
  </tr>
  <tr>
    <td><img src=".github/readme/guide.png" alt="TV guide with an on-now panel and a program grid"></td>
    <td><img src=".github/readme/player.png" alt="Live player showing the current program and what's up next"></td>
  </tr>
</table>
<p align="center"><sub>Screenshots use made-up sample channels, titles and artwork.</sub></p>

## Features

**Sources**
- Xtream Codes accounts, M3U playlist URLs, and local M3U files
- Up to 100 sources, each refreshable, renamable and switchable on or off
- Background import that copes with catalogs of 250,000+ items

**Library**
- One unified Live / Movies / Series library across every source, or narrow it to a single source
- Search as you type, backed by a local full-text index
- Favorites and your own custom groups (mixing live, movies and series), pinned to Home in the order you choose
- Hide whole categories or single items you never want to see

**Watching**
- Full-screen player with audio and subtitle tracks, resume, and watch history
- Now and next from the guide right in the player, and a star to add the channel to Favorites
- Corner picture-in-picture while you keep browsing, and two-channel side-by-side multiview
- Automatic recovery from network drops, and a fallback to the same channel on another source
- Respects your provider's connection limit
- TV guide for Xtream live channels, with a "With schedule" filter that hides channels without guide data
- Start up on Home, any section, or straight into your last channel

**Built for the couch and the desk**
- Runs on Windows and on Android TV, Google TV and Fire TV
- Every screen works with a TV remote or arrow keys, with a clear amber focus ring
- On-screen TV keyboard for remote-style text entry

## Privacy and security

- **Local-first.** Your catalog, favorites, groups and history live in a SQLite database on your device. No accounts, no telemetry, no Wabbit servers.
- **Network use.** Wabbit TV only connects to the sources you add, and to the stream, artwork and guide addresses those sources hand it.
- **Logins.** Xtream passwords are encrypted with your Windows account (DPAPI) or the Android Keystore, and never stored in the catalog database.
- **Secure streams.** HTTPS streams are verified against a bundled Mozilla root certificate list.

## Getting started

There are no prebuilt releases yet, so you build it from source.

### Windows

**Requirements**

- Windows 10 or 11 (64-bit)
- [Flutter](https://docs.flutter.dev/get-started/install/windows/desktop) 3.47 (stable)
- Visual Studio 2022 (Build Tools are enough) with the **Desktop development with C++** workload and the **C++ ATL** component

**Build and run**

```powershell
git clone https://github.com/tcurtsinger/WabbitTV.git
cd WabbitTV
flutter pub get
flutter run -d windows
```

For an optimized build:

```powershell
flutter build windows --release
```

The app ends up at `build\windows\x64\runner\Release\wabbit_tv.exe`. Open it, choose **Add source**, and enter your Xtream account or M3U playlist.

> [!TIP]
> If the build hangs while CMake detects the compiler, run `$env:TrackFileAccess = 'false'` in that PowerShell window and build again.

### Android TV, Google TV and Fire TV

**Requirements:** Flutter 3.47, the Android SDK (from Android Studio or the command-line tools) and JDK 17.

1. Turn on **Developer options** and **ADB debugging** on the TV. On Fire TV this is under *Settings → My Fire TV*.
2. Build the APK and install it over the network:

```powershell
flutter build apk --release
adb connect <tv-ip-address>:5555
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

Wabbit TV then appears with your other apps. The release APK is signed with a debug key, which is fine for sideloading but not for a store.

## Keyboard shortcuts

| Where | Keys | Action |
|---|---|---|
| Everywhere | Arrow keys, Enter (TV: D-pad, Select) | Move focus, select |
| Everywhere | Esc (TV: Back) | Back / open the navigation rail |
| Player | Space, K, media Play/Pause | Play / pause |
| Player | ← / → | Seek back / forward 10 s (movies and episodes; hold to keep seeking) |
| Player | F, or double-click the video | Fullscreen on / off |
| Player | M | Mute on / off |

## Development

```powershell
dart format lib test   # formatting
flutter analyze        # static analysis
flutter test           # 640+ unit and widget tests
```

GitHub Actions runs all of these, plus Windows and Android release builds, on every pull request.

<details>
<summary><b>Synthetic preview fixtures and probes</b></summary>

These run the real UI against built-in synthetic data. They never touch a real provider.

| Command | Shows |
|---|---|
| `flutter run -d windows --dart-define=WABBIT_HOME_FIXTURE=populated` | Home with shelves (also `no-sources`, `no-personalization`) |
| `flutter run -d windows --dart-define=WABBIT_BROWSE_FIXTURE=live` | Browse with a sample catalog (also `movies`, `series`) |
| `flutter run -d windows -t lib/src/spikes/phase1/production_player_fixture_main.dart` | The player with an in-memory transport |
| `flutter run -d windows --dart-define=WABBIT_SQLITE_PROBE=true` | SQLite + FTS5 self-check, printed to stdout |
| `flutter run -d windows --dart-define=WABBIT_CATALOG_SCALE_PROBE=true` | 50k-item import and search timings |

</details>

### Project layout

```text
lib/
├── main.dart
└── src/
    ├── app_shell.dart        # navigation rail, routing, playback surfaces
    ├── cinema.dart           # design tokens, focus glow, pill buttons, the Wabbit mark
    └── features/
        ├── sources/          # Xtream + M3U import, SQLite catalog, credentials
        ├── browse/           # Live / Movies / Series lists
        ├── search/           # full-text search
        ├── library/          # favorites and custom groups
        ├── guide/            # TV guide
        ├── playback/         # player, picture-in-picture, multiview (media_kit)
        ├── home/             # Home shelves
        ├── artwork/          # artwork loading and cache
        └── settings/         # general settings
```

## Roadmap

- Prebuilt releases for Windows and Android TV
- A full XMLTV guide download for providers that block per-channel guide requests

## Built with

[Flutter](https://flutter.dev) · [media_kit](https://github.com/media-kit/media-kit) (libmpv) · [SQLite](https://sqlite.org) with FTS5 via [sqlite3](https://pub.dev/packages/sqlite3) · [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage)

## License

[GNU Affero General Public License v3.0](LICENSE)
