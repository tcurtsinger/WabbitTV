import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/playback/playback_manager.dart';
import 'package:wabbit_tv/src/features/playback/playback_runtime_adapters.dart';
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
  testWidgets(
    'usable-video callback fires once after video and callback failure is isolated',
    (tester) async {
      final transport = _FakeTransport._(name: 'manual', order: <String>[]);
      var callbacks = 0;
      await tester.pumpWidget(
        _host(
          handoff: const MoviePlaybackHandoff(
            sourceId: 'source',
            title: 'Movie',
            providerItemId: '42',
            extension: 'mp4',
            libraryItemId: 'library-42',
          ),
          transportFactory: () => transport,
          onUsableVideo: (handoff) {
            callbacks += 1;
            expect(handoff.libraryItemId, 'library-42');
            throw StateError('local history write failed');
          },
        ),
      );
      await tester.pump();

      transport.emit(
        const PlaybackTransportState(isBuffering: true, hasVideo: false),
      );
      await tester.pump();
      expect(callbacks, 0);

      transport.emit(const PlaybackTransportState(hasVideo: true));
      transport.emit(
        const PlaybackTransportState(hasVideo: true, isPlaying: true),
      );
      await tester.pump();
      await tester.pump();
      expect(callbacks, 1);
      expect(find.byKey(const ValueKey('player-video-stage')), findsOneWidget);
      expect(find.byKey(const ValueKey('player-failure-deck')), findsNothing);
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
    expect(find.text('Retry'), findsOneWidget);
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
    expect(find.text('Retry'), findsOneWidget);
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
    expect(find.text('Retry'), findsOneWidget);
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
    expect(find.text('Open Settings'), findsOneWidget);
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
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Back'), findsOneWidget);
      expect(find.text('Technical details'), findsOneWidget);
      expect(find.textContaining('Try '), findsNothing);
      final recoverySemantics = tester.widget<Semantics>(
        find.descendant(
          of: find.byKey(const ValueKey('player-recovery-primary')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.label == 'Retry',
          ),
        ),
      );
      expect(recoverySemantics.properties.button, isTrue);
      expect(recoverySemantics.properties.label, 'Retry');
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

  testWidgets(
    'manager presentation rebuild never creates or disposes a transport',
    (tester) async {
      var created = 0;
      final transport = _FakeTransport.ready();
      final manager = PlaybackManager(
        targetResolver: const _ManagerResolver(),
        transportFactory: () {
          created += 1;
          return transport;
        },
      );
      addTearDown(manager.dispose);
      const handoff = LivePlaybackHandoff(
        sourceId: 'source',
        title: 'Managed live',
        providerItemId: '1',
        extension: 'ts',
      );
      final started = await manager.start(handoff) as PlaybackStarted;

      await tester.pumpWidget(
        _managedHost(manager, started.sessionId, handoff),
      );
      await tester.pump();
      await tester.pumpWidget(
        _managedHost(manager, started.sessionId, handoff),
      );
      await tester.pump();

      expect(created, 1);
      expect(transport.disposed, isFalse);
      expect(manager.sessions, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(transport.disposed, isFalse);
    },
  );

  testWidgets(
    'Tracks ledger selects real DTO tracks, Off, and reports failure',
    (tester) async {
      final transport = _TrackedTransport();
      final manager = PlaybackManager(
        targetResolver: const _ManagerResolver(),
        transportFactory: () => transport,
      );
      addTearDown(manager.dispose);
      const handoff = LivePlaybackHandoff(
        sourceId: 'source',
        title: 'Managed live',
        providerItemId: '1',
        extension: 'ts',
      );
      final started = await manager.start(handoff) as PlaybackStarted;
      await tester.pumpWidget(
        _managedHost(manager, started.sessionId, handoff),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Tracks'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('player-tracks-ledger')),
        findsOneWidget,
      );
      expect(find.text('Spanish · es'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      await tester.tap(find.text('Spanish · es'));
      await tester.pump();
      expect(transport.selectedAudio, 'audio-2');
      await tester.tap(find.text('Off'));
      await tester.pump();
      expect(transport.selectedSubtitle, 'no');

      transport.failSelections = true;
      await tester.tap(find.text('English · en').first);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('player-track-message')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('player-tracks-ledger')), findsNothing);
      expect(manager.sessions, hasLength(1));
    },
  );

  testWidgets('terminal recovery exposes only returned exact variants', (
    tester,
  ) async {
    final manager = PlaybackManager(
      targetResolver: const _ManagerResolver(),
      transportFactory: () => throw StateError('unavailable'),
    );
    addTearDown(manager.dispose);
    const handoff = MoviePlaybackHandoff(
      sourceId: 'source-a',
      title: 'Managed movie',
      providerItemId: '2',
      extension: 'mp4',
      libraryItemId: 'library-movie',
    );
    final failed = await manager.start(handoff) as PlaybackStartFailed;
    await tester.pumpWidget(
      _managedHost(
        manager,
        failed.sessionId,
        handoff,
        variantPort: const _VariantPort([
          PlaybackVariantCandidate(
            label: 'Source B',
            handoff: MoviePlaybackHandoff(
              sourceId: 'source-b',
              title: 'Managed movie',
              providerItemId: '20',
              extension: 'mkv',
              libraryItemId: 'library-movie',
            ),
          ),
        ]),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(find.text('Technical details'), findsOneWidget);
    expect(find.text('Try Source B'), findsOneWidget);
    expect(find.textContaining('source-b'), findsNothing);
  });

  testWidgets(
    'eligible resume is visible and Start over clears exact progress',
    (tester) async {
      final progress = _ManagerProgress(
        loaded: PlaybackCheckpoint(
          position: const Duration(seconds: 45),
          duration: const Duration(minutes: 2),
          watched: const Duration(seconds: 45),
          updatedAt: DateTime.utc(2026, 8, 19),
        ),
      );
      final transport = _FakeTransport.ready();
      final manager = PlaybackManager(
        targetResolver: const _ManagerResolver(),
        progressPort: progress,
        transportFactory: () => transport,
      );
      addTearDown(manager.dispose);
      const handoff = MoviePlaybackHandoff(
        sourceId: 'source',
        title: 'Managed movie',
        providerItemId: '2',
        extension: 'mp4',
        libraryItemId: 'library-movie',
      );
      final started = await manager.start(handoff) as PlaybackStarted;
      await tester.pumpWidget(
        _managedHost(manager, started.sessionId, handoff),
      );
      await tester.pump();

      expect(find.text('Resumed at 0:00:45.'), findsOneWidget);
      await tester.tap(find.byTooltip('Start over'));
      await tester.pump();
      expect(progress.clears, 1);
      expect(find.text('Started over.'), findsOneWidget);
    },
  );

  testWidgets('progress save failure is truthful without interrupting video', (
    tester,
  ) async {
    final progress = _ManagerProgress(saveResult: false);
    final transport = _FakeTransport.ready();
    final manager = PlaybackManager(
      targetResolver: const _ManagerResolver(),
      progressPort: progress,
      transportFactory: () => transport,
    );
    addTearDown(manager.dispose);
    const handoff = MoviePlaybackHandoff(
      sourceId: 'source',
      title: 'Managed movie',
      providerItemId: '2',
      extension: 'mp4',
      libraryItemId: 'library-movie',
    );
    final started = await manager.start(handoff) as PlaybackStarted;
    await tester.pumpWidget(_managedHost(manager, started.sessionId, handoff));
    transport.emit(
      const PlaybackTransportState(
        hasVideo: true,
        isPlaying: true,
        position: Duration(seconds: 40),
        duration: Duration(minutes: 2),
      ),
    );
    await manager.pause(started.sessionId);
    await tester.pump();

    expect(find.text('Progress could not be saved.'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-video-stage')), findsOneWidget);
  });
}

Widget _managedHost(
  PlaybackManager manager,
  PlaybackSessionId sessionId,
  PlaybackHandoff handoff, {
  PlaybackExactVariantPort? variantPort,
}) => MaterialApp(
  home: PlayerScreen(
    manager: manager,
    sessionId: sessionId,
    handoff: handoff,
    variantPort: variantPort,
    onExit: () {},
  ),
);

Widget _host({
  required PlaybackHandoff handoff,
  PlaybackTransportFactory? transportFactory,
  CredentialStore? credentials,
  PersistedSource? source,
  FutureOr<PersistedSource?> Function(String sourceId)? sourceResolver,
  FullscreenPort? fullscreen,
  VoidCallback? onExit,
  Duration startupDeadline = productionPlayerStartupDeadline,
  UsableVideoCallback? onUsableVideo,
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
    onUsableVideo: onUsableVideo,
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
  for (var steps = 0; steps < 24; steps++) {
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
      StreamController<PlaybackTransportState>.broadcast(sync: true);
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
  Future<void> dispose() {
    disposed = true;
    order.add('$name:dispose');
    return SynchronousFuture<void>(null);
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

class _ManagerResolver implements PlaybackTargetResolverPort {
  const _ManagerResolver();
  @override
  Future<PlaybackResolvedTarget> resolve(PlaybackHandoff handoff) async =>
      PlaybackResolvedTarget(uri: Uri.parse('https://stream.example/item'));
}

class _ManagerProgress implements PlaybackProgressPort {
  _ManagerProgress({this.loaded, this.saveResult = true});
  final PlaybackCheckpoint? loaded;
  final bool saveResult;
  int clears = 0;
  @override
  Future<bool> clear(PlaybackProgressIdentity identity) async {
    clears += 1;
    return true;
  }

  @override
  Future<PlaybackCheckpoint?> load(PlaybackProgressIdentity identity) async =>
      loaded;

  @override
  Future<bool> save(
    PlaybackProgressIdentity identity,
    PlaybackCheckpoint checkpoint,
  ) async => saveResult;
}

class _VariantPort implements PlaybackExactVariantPort {
  const _VariantPort(this.values);
  final List<PlaybackVariantCandidate> values;

  @override
  Future<List<PlaybackVariantCandidate>> loadExactVariants(
    PlaybackHandoff current,
  ) async => values;
}

class _TrackedTransport implements PlaybackTrackTransport {
  final controller = StreamController<PlaybackTransportState>.broadcast(
    sync: true,
  );
  String? selectedAudio, selectedSubtitle;
  bool failSelections = false;
  @override
  Stream<PlaybackTransportState> get states => controller.stream;
  @override
  Widget buildVideo() => const ColoredBox(color: Colors.black);
  @override
  Future<void> open(
    Uri uri, {
    Map<String, String> httpHeaders = const {},
  }) async {
    controller.add(
      const PlaybackTransportState(
        hasVideo: true,
        isPlaying: true,
        duration: Duration(minutes: 2),
        audioTracks: [
          PlaybackMediaTrack(id: 'audio-1', label: 'English', language: 'en'),
          PlaybackMediaTrack(id: 'audio-2', label: 'Spanish', language: 'es'),
        ],
        subtitleTracks: [
          PlaybackMediaTrack(id: 'sub-1', label: 'English', language: 'en'),
        ],
        selectedAudioTrackId: 'audio-1',
      ),
    );
  }

  @override
  Future<void> selectAudioTrack(String id) async {
    if (failSelections) throw StateError('selection failed');
    selectedAudio = id;
  }

  @override
  Future<void> selectSubtitleTrack(String id) async {
    if (failSelections) throw StateError('selection failed');
    selectedSubtitle = id;
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
  @override
  Future<void> dispose() => SynchronousFuture<void>(null);
}

class _FakeFullscreen implements FullscreenPort {
  bool fullscreen = false;
  @override
  Future<bool> get isFullscreen async => fullscreen;
  @override
  Future<void> setFullscreen(bool value) async => fullscreen = value;
}
