import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/browse/playback_handoff.dart';
import '../../features/playback/playback_transport.dart';
import '../../features/playback/player_screen.dart';
import '../../features/sources/credential_store.dart';
import '../../features/sources/source_catalog_database.dart';
import '../../features/sources/source_models.dart';

/// A packaged visual check for the production player surface.
///
/// This is deliberately separate from the product entrypoint. It uses a local
/// transport that ignores its stream URI, so it cannot contact or reveal a
/// provider while exercising the real player controls and fullscreen port.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
  }
  runApp(const _ProductionPlayerFixtureApp());
}

class _ProductionPlayerFixtureApp extends StatelessWidget {
  const _ProductionPlayerFixtureApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Wabbit TV player fixture',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF111212),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFFFFB347),
        onPrimary: Color(0xFF17120A),
        surface: Color(0xFF191A1A),
        onSurface: Color(0xFFF4F0E7),
        secondary: Color(0xFFBEBAB1),
      ),
      fontFamily: 'Segoe UI',
    ),
    home: const _ProductionPlayerFixture(),
  );
}

class _ProductionPlayerFixture extends StatefulWidget {
  const _ProductionPlayerFixture();

  @override
  State<_ProductionPlayerFixture> createState() =>
      _ProductionPlayerFixtureState();
}

class _ProductionPlayerFixtureState extends State<_ProductionPlayerFixture> {
  bool _exited = false;

  @override
  Widget build(BuildContext context) {
    if (_exited) {
      return const Scaffold(
        body: Center(
          child: Text(
            'Player fixture exited',
            style: TextStyle(color: Color(0xFFF4F0E7), fontSize: 16),
          ),
        ),
      );
    }
    return PlayerScreen(
      handoff: const MoviePlaybackHandoff(
        sourceId: _FixtureValues.sourceId,
        title: 'Synthetic Feature Presentation',
        providerItemId: 'fixture-movie',
        extension: 'mp4',
      ),
      source: _FixtureValues.source,
      credentialStore: const _FixtureCredentialStore(),
      transportFactory: _FixturePlaybackTransport.new,
      fullscreenPort: const WindowFullscreenPort(),
      onExit: () => setState(() => _exited = true),
    );
  }
}

abstract final class _FixtureValues {
  static const sourceId = 'production-player-fixture';
  static const source = PersistedSource(
    id: sourceId,
    name: 'Local visual fixture',
    credentialKey: 'production-player-fixture',
    counts: {
      SourceMediaKind.live: 0,
      SourceMediaKind.movies: 1,
      SourceMediaKind.series: 0,
    },
  );
}

class _FixtureCredentialStore implements CredentialStore {
  const _FixtureCredentialStore();

  @override
  Future<void> delete(String key) async {}

  @override
  Future<StoredCredential?> read(String key) async => const StoredCredential(
    username: 'fixture-user',
    password: 'fixture-password',
    serverUrl: 'https://fixture.invalid',
  );

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}

class _FixturePlaybackTransport implements PlaybackTransport {
  final _states = StreamController<PlaybackTransportState>.broadcast();
  PlaybackTransportState _state = const PlaybackTransportState(
    isPlaying: true,
    hasVideo: true,
    position: Duration(minutes: 36, seconds: 42),
    duration: Duration(hours: 1, minutes: 43, seconds: 18),
    volume: 72,
  );

  void _emit() {
    if (!_states.isClosed) _states.add(_state);
  }

  @override
  Widget buildVideo() => const ColoredBox(
    color: Color(0xFF292A29),
    child: Center(
      child: Text(
        'Synthetic video fixture',
        style: TextStyle(
          color: Color(0xFFF4F0E7),
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );

  @override
  Future<void> dispose() => _states.close();

  @override
  Future<void> open(Uri uri) async {
    // Intentionally ignore the URI: this fixture must make no network call and
    // retain no provider-shaped string.
    _emit();
  }

  @override
  Future<void> pause() async {
    _state = PlaybackTransportState(
      isPlaying: false,
      hasVideo: _state.hasVideo,
      position: _state.position,
      duration: _state.duration,
      volume: _state.volume,
      muted: _state.muted,
    );
    _emit();
  }

  @override
  Future<void> play() async {
    _state = PlaybackTransportState(
      isPlaying: true,
      hasVideo: _state.hasVideo,
      position: _state.position,
      duration: _state.duration,
      volume: _state.volume,
      muted: _state.muted,
    );
    _emit();
  }

  @override
  Future<void> seek(Duration position) async {
    _state = PlaybackTransportState(
      isPlaying: _state.isPlaying,
      hasVideo: _state.hasVideo,
      position: position,
      duration: _state.duration,
      volume: _state.volume,
      muted: _state.muted,
    );
    _emit();
  }

  @override
  Future<void> setMuted(bool muted) async {
    _state = PlaybackTransportState(
      isPlaying: _state.isPlaying,
      hasVideo: _state.hasVideo,
      position: _state.position,
      duration: _state.duration,
      volume: muted ? 0 : 72,
      muted: muted,
    );
    _emit();
  }

  @override
  Future<void> setVolume(double volume) async {
    _state = PlaybackTransportState(
      isPlaying: _state.isPlaying,
      hasVideo: _state.hasVideo,
      position: _state.position,
      duration: _state.duration,
      volume: volume,
      muted: volume == 0,
    );
    _emit();
  }

  @override
  Stream<PlaybackTransportState> get states => _states.stream;
}
