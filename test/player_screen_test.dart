import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/playback/playback_transport.dart';
import 'package:wabbit_tv/src/features/playback/player_screen.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  test(
    'resolves Xtream URI only from a typed handoff and saved credential',
    () {
      final uri = resolveXtreamPlaybackUri(
        handoff: const MoviePlaybackHandoff(
          sourceId: 'source',
          title: 'Visible title',
          providerItemId: '42',
          extension: 'mkv',
        ),
        credential: const StoredCredential(
          username: 'user',
          password: 'secret',
          serverUrl: 'https://provider.example:8080/player_api.php',
        ),
      );
      expect(uri.path, '/movie/user/secret/42.mkv');
      expect(uri.query, isEmpty);
    },
  );

  test('preserves an Xtream base path while removing only player_api.php', () {
    const handoff = MoviePlaybackHandoff(
      sourceId: 'source',
      title: 'Title',
      providerItemId: '42',
      extension: 'mp4',
    );
    for (final server in [
      'https://host/iptv',
      'https://host/iptv/player_api.php',
    ]) {
      expect(
        resolveXtreamPlaybackUri(
          handoff: handoff,
          credential: StoredCredential(
            username: 'user',
            password: 'secret',
            serverUrl: server,
          ),
        ).path,
        '/iptv/movie/user/secret/42.mp4',
      );
    }
    expect(
      resolveXtreamPlaybackUri(
        handoff: handoff,
        credential: const StoredCredential(
          username: 'user',
          password: 'secret',
          serverUrl: 'https://host',
        ),
      ).path,
      '/movie/user/secret/42.mp4',
    );
  });
  testWidgets(
    'M3U opens its imported URI and headers without reading credentials',
    (tester) async {
      final transport = _FakeTransport.ready();
      final credentials = _CountingCredential();
      await tester.pumpWidget(
        _host(
          handoff: _m3uHandoff(),
          credentials: credentials,
          transportFactory: () => transport,
        ),
      );
      await tester.pump();

      expect(credentials.reads, 0);
      expect(transport.openedUri, Uri.parse('https://stream.example/live'));
      expect(transport.openedHeaders, {
        'User-Agent': 'Fixture Player',
        'Referer': 'https://origin.example',
      });
      expect(find.byKey(const ValueKey('player-timeline')), findsNothing);
    },
  );
  testWidgets('M3U retry keeps the imported headers', (tester) async {
    final second = _FakeTransport.ready();
    var calls = 0;
    await tester.pumpWidget(
      _host(
        handoff: _m3uHandoff(),
        transportFactory: () {
          calls += 1;
          if (calls == 1) throw StateError('fixture factory failure');
          return second;
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(calls, 2);
    expect(second.openedHeaders, {
      'User-Agent': 'Fixture Player',
      'Referer': 'https://origin.example',
    });
  });
  testWidgets(
    'a resolver chooses the result source rather than a stale shell source',
    (tester) async {
      final transport = _FakeTransport.ready();
      final resolverCalls = <String>[];
      await tester.pumpWidget(
        _host(
          handoff: const MoviePlaybackHandoff(
            sourceId: 'source-b',
            title: 'Movie',
            providerItemId: '42',
            extension: 'mp4',
          ),
          source: const PersistedSource(
            id: 'source-a',
            name: 'Stale source',
            credentialKey: 'stale-key',
            counts: {},
          ),
          sourceResolver: (sourceId) {
            resolverCalls.add(sourceId);
            return const PersistedSource(
              id: 'source-b',
              name: 'Selected source',
              credentialKey: 'selected-key',
              counts: {},
            );
          },
          credentials: const _Credential(
            StoredCredential(
              username: 'user',
              password: 'secret',
              serverUrl: 'https://selected.example',
            ),
          ),
          transportFactory: () => transport,
        ),
      );
      await tester.pump();

      expect(resolverCalls, ['source-b']);
      expect(transport.openedUri?.host, 'selected.example');
      expect(transport.openedHeaders, isEmpty);
    },
  );
  testWidgets('a resolver-null M3U result does not open a stale source', (
    tester,
  ) async {
    var transportCalls = 0;
    final credentials = _CountingCredential();
    await tester.pumpWidget(
      _host(
        handoff: _m3uHandoff(),
        sourceResolver: (_) => null,
        credentials: credentials,
        transportFactory: () {
          transportCalls += 1;
          return _FakeTransport.ready();
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(transportCalls, 0);
    expect(credentials.reads, 0);
    expect(find.text('Try again'), findsOneWidget);
  });
  testWidgets('a resolver-null Xtream result does not open a stale source', (
    tester,
  ) async {
    var transportCalls = 0;
    await tester.pumpWidget(
      _host(
        handoff: const LivePlaybackHandoff(
          sourceId: 'missing',
          title: 'Live',
          providerItemId: '1',
          extension: 'ts',
        ),
        sourceResolver: (_) => null,
        transportFactory: () {
          transportCalls += 1;
          return _FakeTransport.ready();
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(transportCalls, 0);
    expect(find.text('Open Settings'), findsOneWidget);
  });
  testWidgets('a throwing source resolver stays in bounded recovery', (
    tester,
  ) async {
    var transportCalls = 0;
    await tester.pumpWidget(
      _host(
        handoff: _m3uHandoff(),
        sourceResolver: (_) => throw StateError('fixture resolver failure'),
        transportFactory: () {
          transportCalls += 1;
          return _FakeTransport.ready();
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(transportCalls, 0);
    expect(find.text('Try again'), findsOneWidget);
  });
  testWidgets('a throwing credential read stays in bounded recovery', (
    tester,
  ) async {
    var transportCalls = 0;
    await tester.pumpWidget(
      _host(
        handoff: const LivePlaybackHandoff(
          sourceId: 'source',
          title: 'Live',
          providerItemId: '1',
          extension: 'ts',
        ),
        credentials: const _ThrowingCredential(),
        transportFactory: () {
          transportCalls += 1;
          return _FakeTransport.ready();
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(transportCalls, 0);
    expect(find.text('Try again'), findsOneWidget);
  });
  test(
    'Windows fullscreen hides the native title bar until after exit',
    () async {
      const channel = MethodChannel('window_manager');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      const port = WindowFullscreenPort();
      await port.setFullscreen(true);
      expect(calls.map((call) => call.method), [
        'setTitleBarStyle',
        'setFullScreen',
      ]);
      expect(calls.first.arguments, containsPair('titleBarStyle', 'hidden'));
      expect(calls.last.arguments, containsPair('isFullScreen', true));

      calls.clear();
      await port.setFullscreen(false);
      expect(calls.map((call) => call.method), [
        'setFullScreen',
        'setTitleBarStyle',
      ]);
      expect(calls.first.arguments, containsPair('isFullScreen', false));
      expect(calls.last.arguments, containsPair('titleBarStyle', 'normal'));
    },
    skip: !Platform.isWindows,
  );
  testWidgets('Live has no timeline and chrome yields to the video stage', (
    tester,
  ) async {
    final transport = _FakeTransport.ready();
    await tester.pumpWidget(
      _host(
        handoff: const LivePlaybackHandoff(
          sourceId: 'source',
          title: 'Live title',
          providerItemId: '1',
          extension: 'ts',
        ),
        transportFactory: () => transport,
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('player-broadcast-deck')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-timeline')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const ValueKey('player-broadcast-deck')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(find.byKey(const ValueKey('player-broadcast-deck')), findsOneWidget);
  });

  testWidgets(
    'Down from chrome returns focus to the video stage and hides the deck',
    (tester) async {
      await tester.pumpWidget(
        _host(
          handoff: const MoviePlaybackHandoff(
            sourceId: 'source',
            title: 'Movie',
            providerItemId: '2',
            extension: 'mp4',
          ),
          transportFactory: _FakeTransport.ready,
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('player-broadcast-deck')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(find.byKey(const ValueKey('player-broadcast-deck')), findsNothing);
    },
  );
  testWidgets(
    'factory failure recovery starts focused and keeps remote traversal explicit',
    (tester) async {
      var calls = 0;
      var exited = false;
      final fullscreen = _FakeFullscreen();
      await tester.pumpWidget(
        _host(
          handoff: const MoviePlaybackHandoff(
            sourceId: 'source',
            title: 'Movie',
            providerItemId: '2',
            extension: 'mp4',
          ),
          transportFactory: () {
            calls += 1;
            throw StateError('test transport');
          },
          fullscreen: fullscreen,
          onExit: () => exited = true,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(calls, 2);
      expect(find.text('Try again'), findsOneWidget);
      final recoverySemantics = tester.widget<Semantics>(
        find.descendant(
          of: find.byKey(const ValueKey('player-recovery-primary')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.label == 'Try again',
          ),
        ),
      );
      expect(recoverySemantics.properties.button, isTrue);
      expect(recoverySemantics.properties.label, 'Try again');
      expect(recoverySemantics.excludeSemantics, isTrue);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'player recovery primary',
      );
      final primaryRing = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('player-recovery-primary-focus-ring')),
      );
      final primaryBorder =
          (primaryRing.decoration as BoxDecoration).border! as Border;
      expect(primaryBorder.top.color, const Color(0xFFFFB347));
      expect(primaryBorder.top.width, 2);
      for (final key in const [
        'player-recovery-primary',
        'player-recovery-back',
        'player-recovery-details',
      ]) {
        expect(tester.getSize(find.byKey(ValueKey(key))).height, 44);
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'player recovery back',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'player recovery technical details',
      );
      final detailsRing = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('player-recovery-details-focus-ring')),
      );
      final detailsBorder =
          (detailsRing.decoration as BoxDecoration).border! as Border;
      expect(detailsBorder.top.color, const Color(0xFFFFB347));
      expect(detailsBorder.top.width, 2);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'player video stage',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'player recovery primary',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(exited, isTrue);
    },
  );
  testWidgets(
    'VOD exposes truthful timeline and fullscreen Back exits fullscreen before playback',
    (tester) async {
      final fullscreen = _FakeFullscreen();

      await tester.pumpWidget(
        _host(
          handoff: const MoviePlaybackHandoff(
            sourceId: 'source',
            title: 'Movie title',
            providerItemId: '2',
            extension: 'mp4',
          ),
          transportFactory: _FakeTransport.ready,
          fullscreen: fullscreen,
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('player-timeline')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-fullscreen')));
      await tester.pump();
      expect(fullscreen.fullscreen, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(fullscreen.fullscreen, isFalse);
    },
  );
  testWidgets(
    'wide VOD deck centers transport and keeps right utilities on-screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          handoff: const MoviePlaybackHandoff(
            sourceId: 'source',
            title: 'Movie',
            providerItemId: '2',
            extension: 'mp4',
          ),
          transportFactory: _FakeTransport.ready,
        ),
      );
      await tester.pump();

      final primary = tester.getRect(
        find.byKey(const ValueKey('player-primary-controls')),
      );
      final utilities = tester.getRect(
        find.byKey(const ValueKey('player-utility-controls')),
      );
      expect((primary.center.dx - 1265 / 2).abs(), lessThanOrEqualTo(0.5));
      expect(utilities.left, greaterThan(primary.right));
      expect(utilities.right, lessThanOrEqualTo(1265));
      expect(utilities.top, greaterThanOrEqualTo(0));
      expect(utilities.bottom, lessThanOrEqualTo(713));
    },
  );
  testWidgets('wide Live deck centers its single primary transport action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        handoff: const LivePlaybackHandoff(
          sourceId: 'source',
          title: 'Live',
          providerItemId: '1',
          extension: 'ts',
        ),
        transportFactory: _FakeTransport.ready,
      ),
    );
    await tester.pump();

    final primary = tester.getRect(
      find.byKey(const ValueKey('player-primary-controls')),
    );
    final utilities = tester.getRect(
      find.byKey(const ValueKey('player-utility-controls')),
    );
    expect((primary.center.dx - 1265 / 2).abs(), lessThanOrEqualTo(0.5));
    expect(primary.width, 44);
    expect(utilities.right, lessThanOrEqualTo(1265));
    expect(utilities.bottom, lessThanOrEqualTo(713));
  });
  testWidgets(
    'compact VOD deck stays within a constrained 480 by 713 viewport',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          handoff: const MoviePlaybackHandoff(
            sourceId: 'source',
            title: 'A deliberately long movie title that remains contained',
            providerItemId: '2',
            extension: 'mp4',
          ),
          transportFactory: _FakeTransport.ready,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final deck = tester.getRect(
        find.byKey(const ValueKey('player-broadcast-deck')),
      );
      expect(deck.left, greaterThanOrEqualTo(0));
      expect(deck.right, lessThanOrEqualTo(480));
      expect(deck.bottom, lessThanOrEqualTo(713));
    },
  );
  testWidgets('starting status is edge-free and clamps a long title', (
    tester,
  ) async {
    final longTitle = List.filled(24, 'Long title').join(' ');
    var transportIndex = 0;
    await tester.pumpWidget(
      _host(
        handoff: MoviePlaybackHandoff(
          sourceId: 'source',
          title: longTitle,
          providerItemId: '2',
          extension: 'mp4',
        ),
        transportFactory: () => _FakeTransport._(
          name: 'waiting-${transportIndex++}',
          order: <String>[],
        ),
        startupDeadline: const Duration(milliseconds: 50),
      ),
    );
    await tester.pump();

    final mark = find.byKey(const ValueKey('player-status-mark'));
    expect(mark, findsOneWidget);
    expect(
      find.descendant(of: mark, matching: find.byType(DecoratedBox)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: mark,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    final label = tester.widget<Text>(find.text('Starting $longTitle'));
    expect(label.maxLines, 1);
    expect(label.overflow, TextOverflow.ellipsis);
    expect(tester.getSize(mark).width, lessThanOrEqualTo(520));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 51));
  });
  testWidgets(
    'missing credentials offers Settings without exposing transport details',
    (tester) async {
      await tester.pumpWidget(
        _host(
          handoff: const EpisodePlaybackHandoff(
            sourceId: 'source',
            title: 'Episode',
            providerItemId: 'private-id',
            extension: 'mp4',
          ),
          credentials: const _Credential(null),
        ),
      );
      await tester.pump();
      expect(find.text('Open Settings'), findsOneWidget);
      await tester.tap(find.text('Technical details'));
      await tester.pump();
      final details = tester.widget<Text>(find.textContaining('Category:'));
      expect(details.data, isNot(contains('private-id')));
      expect(details.data, isNot(contains('secret')));
    },
  );

  test('startup timeout resolves a never-completing outcome', () async {
    final outcome = Completer<PlaybackFailureKind?>();

    expect(
      await waitForPlaybackStartup(
        outcome.future,
        const Duration(milliseconds: 1),
      ),
      PlaybackFailureKind.timedOut,
    );
  });

  testWidgets(
    'chrome keeps every focused control visible and Down always returns to the stage',
    (tester) async {
      final transport = _FakeTransport.ready();
      await tester.pumpWidget(
        _host(
          handoff: const MoviePlaybackHandoff(
            sourceId: 'source',
            title: 'Movie',
            providerItemId: '2',
            extension: 'mp4',
          ),
          transportFactory: () => transport,
        ),
      );
      await tester.pump();

      for (final target in const [
        'player back',
        'player timeline',
        'player mute',
        'player volume',
        'player fullscreen',
      ]) {
        await _focusPlayerControl(tester, target);
        expect(FocusManager.instance.primaryFocus?.debugLabel, target);
        await tester.pump(const Duration(seconds: 5));
        expect(
          find.byKey(const ValueKey('player-broadcast-deck')),
          findsOneWidget,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'player video stage',
        );
        expect(
          find.byKey(const ValueKey('player-broadcast-deck')),
          findsNothing,
        );
      }
    },
  );

  testWidgets('buffering end rearms the bounded chrome hide from the stage', (
    tester,
  ) async {
    final transport = _FakeTransport.ready();
    await tester.pumpWidget(
      _host(
        handoff: const LivePlaybackHandoff(
          sourceId: 'source',
          title: 'Live',
          providerItemId: '1',
          extension: 'ts',
        ),
        transportFactory: () => transport,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'player video stage',
    );
    expect(find.byKey(const ValueKey('player-broadcast-deck')), findsNothing);

    await tester.sendEventToBinding(
      const PointerHoverEvent(position: Offset(4, 4)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('player-broadcast-deck')), findsOneWidget);
    transport.emit(
      const PlaybackTransportState(hasVideo: true, isBuffering: true),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const ValueKey('player-broadcast-deck')), findsOneWidget);

    transport.emit(const PlaybackTransportState(hasVideo: true));
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const ValueKey('player-broadcast-deck')), findsNothing);
  });
}

Widget _host({
  required PlaybackHandoff handoff,
  PlaybackTransportFactory? transportFactory,
  CredentialStore? credentials,
  PersistedSource? source,
  FutureOr<PersistedSource?> Function(String sourceId)? sourceResolver,
  FullscreenPort? fullscreen,
  VoidCallback? onExit,
  Duration startupDeadline = productionPlayerStartupDeadline,
}) => MaterialApp(
  home: PlayerScreen(
    handoff: handoff,
    source:
        source ??
        const PersistedSource(
          id: 'source',
          name: 'Source',
          credentialKey: 'key',
          counts: {},
        ),
    sourceResolver: sourceResolver,
    credentialStore:
        credentials ??
        const _Credential(
          StoredCredential(
            username: 'user',
            password: 'secret',
            serverUrl: 'https://provider.example',
          ),
        ),
    transportFactory: transportFactory,
    fullscreenPort: fullscreen,
    startupDeadline: startupDeadline,
    onExit: onExit ?? () {},
  ),
);

M3uLivePlaybackHandoff _m3uHandoff() {
  final handoff = playbackHandoffFor(
    BrowseCatalogItem(
      id: 'm3u-row',
      sourceId: 'source',
      kind: SourceMediaKind.live,
      title: 'M3U live',
      artworkLocator: null,
      playbackRef: '{"url":"https://stream.example/live","headers":{"User-Agent":"Fixture Player","Referer":"https://origin.example"}}',
    ),
  );
  return handoff as M3uLivePlaybackHandoff;
}

Future<void> _focusPlayerControl(WidgetTester tester, String target) async {
  if (FocusManager.instance.primaryFocus?.debugLabel != 'player back') {
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
  }
  for (var steps = 0; steps < 12; steps++) {
    if (FocusManager.instance.primaryFocus?.debugLabel == target) return;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  fail(
    'Could not traverse to $target; focus was '
    '${FocusManager.instance.primaryFocus?.debugLabel}.',
  );
}

class _Credential implements CredentialStore {
  const _Credential(this.value);
  final StoredCredential? value;
  @override
  Future<void> delete(String key) async {}
  @override
  Future<StoredCredential?> read(String key) async => value;
  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}

class _CountingCredential implements CredentialStore {
  int reads = 0;

  @override
  Future<void> delete(String key) async {}

  @override
  Future<StoredCredential?> read(String key) async {
    reads += 1;
    return null;
  }

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}

class _ThrowingCredential implements CredentialStore {
  const _ThrowingCredential();

  @override
  Future<void> delete(String key) async {}

  @override
  Future<StoredCredential?> read(String key) async {
    throw StateError('fixture credential read failure');
  }

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}

class _FakeTransport implements PlaybackTransport {
  _FakeTransport._({
    required this.name,
    required this.order,
    this.emitReadyWhenOpened = false,
  });

  factory _FakeTransport.ready() => _FakeTransport._(
    name: 'ready',
    order: <String>[],
    emitReadyWhenOpened: true,
  );

  static const _ready = PlaybackTransportState(
    hasVideo: true,
    isPlaying: true,
    duration: Duration(minutes: 2),
    position: Duration(seconds: 20),
    volume: 40,
  );
  final String name;
  final List<String> order;
  final bool emitReadyWhenOpened;
  final StreamController<PlaybackTransportState> _controller =
      StreamController<PlaybackTransportState>.broadcast();
  bool disposed = false;
  Uri? openedUri;
  Map<String, String>? openedHeaders;

  void emit(PlaybackTransportState state) {
    if (!disposed) _controller.add(state);
  }

  void emitReady() => emit(_ready);

  @override
  Stream<PlaybackTransportState> get states => _controller.stream;
  @override
  Widget buildVideo() => const ColoredBox(color: Colors.black);
  @override
  Future<void> dispose() async {
    disposed = true;
    order.add('$name:dispose');
    await _controller.close();
  }

  @override
  Future<void> open(
    Uri uri, {
    Map<String, String> httpHeaders = const {},
  }) async {
    order.add('$name:open');
    openedUri = uri;
    openedHeaders = Map<String, String>.from(httpHeaders);
    if (emitReadyWhenOpened) emitReady();
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setVolume(double volume) async {}
}

class _FakeFullscreen implements FullscreenPort {
  bool fullscreen = false;
  @override
  Future<bool> get isFullscreen async => fullscreen;
  @override
  Future<void> setFullscreen(bool value) async => fullscreen = value;
}
