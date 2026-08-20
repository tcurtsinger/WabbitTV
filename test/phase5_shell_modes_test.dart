import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wabbit_tv/src/app_shell.dart';
import 'package:wabbit_tv/src/features/browse/basic_browse_screen.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/home/home_screen.dart';
import 'package:wabbit_tv/src/features/playback/multiview_screen.dart';
import 'package:wabbit_tv/src/features/playback/pip_overlay.dart';
import 'package:wabbit_tv/src/features/playback/playback_manager.dart';
import 'package:wabbit_tv/src/features/playback/playback_transport.dart';
import 'package:wabbit_tv/src/features/playback/player_screen.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_controller.dart';
import 'package:wabbit_tv/src/home_fixture_mode.dart';

void main() {
  test('600px Corner Signal placement skips a focused target collision', () {
    const bounds = Rect.fromLTWH(72, 0, 528, 713);
    const surfaceSize = Size(256, 200);
    const focusedTarget = Rect.fromLTWH(420, 540, 140, 80);

    final resolved = pipCornerAvoidingTarget(
      requested: PipCorner.bottomRight,
      bounds: bounds,
      surfaceSize: surfaceSize,
      target: focusedTarget.inflate(8),
    );

    expect(resolved, PipCorner.bottomLeft);
    expect(
      pipCornerRect(
        corner: resolved,
        bounds: bounds,
        surfaceSize: surfaceSize,
      ).overlaps(focusedTarget.inflate(8)),
      isFalse,
    );
  });

  test('fixture manager stops a ready session', () async {
    final transports = _TransportFactory(failAfterFirst: false);
    final manager = PlaybackManager(
      targetResolver: const _Resolver(),
      admissionPort: const _Admission(2),
      transportFactory: transports.create,
    );
    final result = await manager.start(
      const LivePlaybackHandoff(
        sourceId: 'source',
        title: 'One',
        providerItemId: 'one',
        extension: 'ts',
      ),
    );
    expect(result, isA<PlaybackStarted>());
    await manager.stopAll().timeout(const Duration(seconds: 1));
    expect(manager.sessions, isEmpty);
    manager.dispose();
  });

  testWidgets('multiview keeps equal side-by-side tiles at 600px and 2x text', (
    tester,
  ) async {
    final transports = _TransportFactory(failAfterFirst: false);
    final manager = PlaybackManager(
      targetResolver: const _Resolver(),
      admissionPort: const _Admission(2),
      transportFactory: transports.create,
    );
    addTearDown(manager.dispose);
    final first = await manager.start(
      const LivePlaybackHandoff(
        sourceId: 'source',
        title: 'Channel One',
        providerItemId: 'one',
        extension: 'ts',
      ),
    );
    final second = await manager.start(
      const LivePlaybackHandoff(
        sourceId: 'source',
        title: 'Channel Two',
        providerItemId: 'two',
        extension: 'ts',
      ),
      requestAudioFocus: false,
    );
    final firstId = (first as PlaybackStarted).sessionId;
    final secondId = (second as PlaybackStarted).sessionId;
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: MultiviewScreen(
          manager: manager,
          originalSessionId: firstId,
          secondSessionId: secondId,
          onOpenFullPlayer: (_) {},
          onCloseSession: (_) {},
          onCollapse: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final firstRect = tester.getRect(
      find.byKey(const ValueKey('multiview-original-tile')),
    );
    final secondRect = tester.getRect(
      find.byKey(const ValueKey('multiview-second-tile')),
    );
    expect(secondRect.left, greaterThan(firstRect.left));
    expect(secondRect.top, firstRect.top);
    expect(secondRect.width, firstRect.width);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Corner Signal reuses one session, moves, navigates, and confirms Settings stop',
    (tester) async {
      final fixture = _ShellFixture(limit: 2);
      final accessibilityMessages = <Object?>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, (
            message,
          ) async {
            accessibilityMessages.add(message);
            return null;
          });
      addTearDown(fixture.dispose);
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<Object?>(
              SystemChannels.accessibility,
              null,
            ),
      );
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      var player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
      player.onEnterPip!();
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.byType(PipOverlay), findsOneWidget);
      expect(fixture.manager.sessions, hasLength(1));
      expect(find.byKey(const ValueKey('fake-video-1')), findsOneWidget);

      var previous = tester.widget<PipOverlay>(find.byType(PipOverlay)).corner;
      final visited = <PipCorner>{previous};
      for (var index = 0; index < 4; index++) {
        await tester.tap(find.byKey(const ValueKey('corner-signal-move')));
        await tester.pump();
        final current = tester
            .widget<PipOverlay>(find.byType(PipOverlay))
            .corner;
        expect(current, isNot(previous));
        visited.add(current);
        previous = current;
      }
      expect(visited.length, greaterThanOrEqualTo(3));
      expect(
        accessibilityMessages.whereType<Map<Object?, Object?>>().any((event) {
          final data = event['data'];
          return data is Map<Object?, Object?> &&
              (data['message'] as String?)?.startsWith(
                    'Corner Signal moved to ',
                  ) ==
                  true;
        }),
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('corner-signal-mute')));
      await tester.pumpAndSettle();
      expect(fixture.manager.sessions.single.isAudible, isFalse);
      await tester.tap(find.byKey(const ValueKey('corner-signal-mute')));
      await tester.pumpAndSettle();
      expect(fixture.manager.sessions.single.isAudible, isTrue);

      await tester.tap(find.byKey(const ValueKey('corner-signal-return')));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-video-1')), findsOneWidget);
      expect(fixture.transports.created, hasLength(1));
      player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
      player.onEnterPip!();
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.movie_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsAtLeastNWidgets(1));
      expect(find.byType(PipOverlay), findsOneWidget);

      await tester.tap(find.byIcon(Icons.picture_in_picture_alt_outlined));
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'picture in picture return',
      );

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();
      expect(find.byType(PipStopConfirmation), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'cancel stopping picture in picture',
      );
      for (var index = 0; index < 6; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          isNot(contains('navigation')),
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(PipStopConfirmation), findsNothing);
      expect(find.byType(PipOverlay), findsOneWidget);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();
      expect(find.byType(PipStopConfirmation), findsOneWidget);
      tester
          .widget<PipStopConfirmation>(find.byType(PipStopConfirmation))
          .onStop();
      await _pumpUntil(
        tester,
        () => find.byType(PipOverlay).evaluate().isEmpty,
      );
      expect(find.byType(PipOverlay), findsNothing);
      expect(fixture.manager.sessions, isEmpty);
      expect(find.text('Sources'), findsOneWidget);
    },
  );

  testWidgets(
    'modal shell layers hide background semantics but Corner Signal keeps them',
    (tester) async {
      final fixture = _ShellFixture(limit: 2);
      final semantics = tester.ensureSemantics();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      expect(_semanticsTreeHasLabel(tester, 'Home'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(_semanticsTreeHasLabel(tester, 'Home'), isFalse);

      tester.widget<PlayerScreen>(find.byType(PlayerScreen)).onEnterPip!();
      await tester.pumpAndSettle();
      expect(find.byType(PipOverlay), findsOneWidget);
      expect(_semanticsTreeHasLabel(tester, 'Home'), isTrue);

      await _activateRailDestinationWithRemote(tester, 'Settings');
      expect(find.byType(PipStopConfirmation), findsOneWidget);
      expect(_semanticsTreeHasLabel(tester, 'Home'), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(find.byType(PipStopConfirmation), findsNothing);
      expect(_semanticsTreeHasLabel(tester, 'Home'), isTrue);
      semantics.dispose();
    },
  );

  testWidgets('PiP remote Enter and Select activate Return, Move, and Close', (
    tester,
  ) async {
    final fixture = _ShellFixture(limit: 2);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    var player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    player.onEnterPip!();
    await tester.pumpAndSettle();

    await _focusKeyedAction(tester, 'corner-signal-return');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(fixture.manager.sessions, hasLength(1));

    player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    player.onEnterPip!();
    await tester.pumpAndSettle();
    final beforeMove = tester
        .widget<PipOverlay>(find.byType(PipOverlay))
        .corner;
    await _focusKeyedAction(tester, 'corner-signal-move');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(
      tester.widget<PipOverlay>(find.byType(PipOverlay)).corner,
      isNot(beforeMove),
    );

    await _focusKeyedAction(tester, 'corner-signal-close');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pumpUntil(tester, () => fixture.manager.sessions.isEmpty);
    expect(find.byType(PipOverlay), findsNothing);
    expect(find.byType(PlayerScreen), findsNothing);
  });

  testWidgets('stop confirmation remote Select cancels and Enter stops', (
    tester,
  ) async {
    final fixture = _ShellFixture(limit: 2);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    tester.widget<PlayerScreen>(find.byType(PlayerScreen)).onEnterPip!();
    await tester.pumpAndSettle();

    await _activateRailDestinationWithRemote(tester, 'Settings');
    expect(find.byType(PipStopConfirmation), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(find.byType(PipStopConfirmation), findsNothing);
    expect(find.byType(PipOverlay), findsOneWidget);

    await _activateRailDestinationWithRemote(tester, 'Settings');
    await _focusByDebugLabel(tester, 'confirm stopping picture in picture');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pumpUntil(tester, () => fixture.manager.sessions.isEmpty);
    expect(find.byType(PipStopConfirmation), findsNothing);
    expect(find.byType(PipOverlay), findsNothing);
    expect(find.text('Sources'), findsOneWidget);
  });

  testWidgets(
    'expanded Now Playing rail and hover move left PiP to the right',
    (tester) async {
      final fixture = _ShellFixture(limit: 2);
      final semantics = tester.ensureSemantics();
      final accessibilityMessages = <Object?>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, (
            message,
          ) async {
            accessibilityMessages.add(message);
            return null;
          });
      addTearDown(fixture.dispose);
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<Object?>(
              SystemChannels.accessibility,
              null,
            ),
      );
      await tester.binding.setSurfaceSize(const Size(600, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      tester.widget<PlayerScreen>(find.byType(PlayerScreen)).onEnterPip!();
      await tester.pumpAndSettle();
      await _movePipToLeft(tester);

      final nowPlaying = tester.widget<FocusableActionDetector>(
        find.byKey(const ValueKey('shell-now-playing')),
      );
      expect(nowPlaying.mouseCursor, SystemMouseCursors.click);
      final nowPlayingNode = tester.getSemantics(
        find.byKey(const ValueKey('shell-now-playing')),
      );
      final nowPlayingSemantics = nowPlayingNode.getSemanticsData();
      expect(nowPlayingSemantics.label, 'Now Playing');
      expect(nowPlayingSemantics.flagsCollection.isButton, isTrue);
      expect(nowPlayingSemantics.hasAction(SemanticsAction.tap), isTrue);
      tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
        nowPlayingNode.id,
        SemanticsAction.tap,
      );
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'picture in picture return',
      );

      nowPlaying.focusNode!.requestFocus();
      await tester.pump(const Duration(milliseconds: 200));
      expect(nowPlaying.focusNode!.hasFocus, isTrue);
      expect(
        tester.getRect(find.byKey(const ValueKey('corner-signal-pip'))).left,
        greaterThanOrEqualTo(224),
      );
      expect(
        tester.widget<PipOverlay>(find.byType(PipOverlay)).corner,
        isIn([PipCorner.topRight, PipCorner.bottomRight]),
      );

      await _focusKeyedAction(tester, 'corner-signal-move');
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<PipOverlay>(find.byType(PipOverlay)).corner,
        isIn([PipCorner.topRight, PipCorner.bottomRight]),
      );
      await _movePipToLeft(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(580, 700));
      await mouse.moveTo(const Offset(20, 100));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<PipOverlay>(find.byType(PipOverlay)).corner,
        isIn([PipCorner.topRight, PipCorner.bottomRight]),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('corner-signal-pip'))).left,
        greaterThanOrEqualTo(224),
      );
      await mouse.moveTo(const Offset(580, 700));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<PipOverlay>(find.byType(PipOverlay)).corner,
        isIn([PipCorner.topRight, PipCorner.bottomRight]),
      );
      expect(
        accessibilityMessages.whereType<Map<Object?, Object?>>().where((event) {
          final data = event['data'];
          return data is Map<Object?, Object?> &&
              (data['message'] as String?)?.startsWith(
                    'Corner Signal moved to ',
                  ) ==
                  true;
        }).length,
        greaterThanOrEqualTo(2),
      );
      await mouse.removePointer();
      semantics.dispose();
    },
  );

  testWidgets(
    'remote activation carries Corner Signal across six destinations',
    (tester) async {
      final fixture = _ShellFixture(limit: 2);
      addTearDown(fixture.dispose);
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      tester.widget<PlayerScreen>(find.byType(PlayerScreen)).onEnterPip!();
      await tester.pumpAndSettle();

      for (final destination in const [
        'Home',
        'Live',
        'Movies',
        'Series',
        'Search',
        'My Library',
      ]) {
        await _activateRailDestinationWithRemote(tester, destination);
        final destinationMarker = destination == 'My Library'
            ? 'My Library could not be loaded'
            : destination;
        await _pumpUntil(
          tester,
          () => find.text(destinationMarker).evaluate().isNotEmpty,
        );
        expect(find.byType(PipOverlay), findsOneWidget);
        expect(find.text(destinationMarker), findsAtLeastNWidgets(1));
      }
      expect(fixture.manager.sessions, hasLength(1));
      expect(fixture.transports.created, hasLength(1));
    },
  );

  testWidgets('organizing from Home requires the PiP stop confirmation', (
    tester,
  ) async {
    final fixture = _ShellFixture(limit: 2);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    tester.widget<PlayerScreen>(find.byType(PlayerScreen)).onEnterPip!();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.bookmark_add_outlined).first);
    await tester.pump();
    expect(find.byType(PipStopConfirmation), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'cancel stopping picture in picture',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(PipStopConfirmation), findsNothing);
    expect(find.byType(PipOverlay), findsOneWidget);

    await tester.tap(find.byIcon(Icons.bookmark_add_outlined).first);
    await tester.pump();
    tester
        .widget<PipStopConfirmation>(find.byType(PipStopConfirmation))
        .onStop();
    await _pumpUntil(tester, () => fixture.manager.sessions.isEmpty);
    expect(find.byType(PipOverlay), findsNothing);
    expect(find.byType(PipStopConfirmation), findsNothing);
  });

  testWidgets(
    'Add channel uses Live directory, rejects same identity, transfers audio, and collapses',
    (tester) async {
      final fixture = _ShellFixture(limit: 2);
      addTearDown(fixture.dispose);
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      var player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
      player.onAddChannel!();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('browse-second-channel-banner')),
        findsOneWidget,
      );
      expect(find.byType(PipOverlay), findsOneWidget);
      expect(fixture.manager.sessions, hasLength(1));

      await tester.tap(find.byKey(const ValueKey('browse-row-live-one')));
      await tester.pump();
      expect(
        find.text('Already playing. Choose another channel.'),
        findsOneWidget,
      );
      expect(fixture.transports.created, hasLength(1));

      await tester.tap(find.byKey(const ValueKey('browse-row-live-two')));
      await tester.pumpAndSettle();
      expect(find.byType(MultiviewScreen), findsOneWidget);
      expect(find.byType(PipOverlay), findsNothing);
      expect(fixture.manager.sessions, hasLength(2));
      expect(find.byKey(const ValueKey('fake-video-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-video-2')), findsOneWidget);
      expect(
        fixture.manager.sessions.where((item) => item.isAudible),
        hasLength(1),
      );

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'multiview original stream',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'multiview second stream',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(fixture.manager.sessions.last.isAudible, isTrue);
      expect(fixture.manager.sessions.first.isAudible, isFalse);

      await tester.tap(find.byKey(const ValueKey('multiview-full-player')));
      await _pumpUntil(tester, () => fixture.manager.sessions.length == 1);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-video-1')), findsNothing);
      expect(find.byKey(const ValueKey('fake-video-2')), findsOneWidget);
      expect(fixture.transports.created.first.disposed, isTrue);
      player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
      await tester.runAsync(() async => player.onExit());
      await _pumpUntil(tester, () => fixture.manager.sessions.isEmpty);
      expect(find.byType(MultiviewScreen), findsNothing);
      expect(find.byType(PlayerScreen), findsNothing);
    },
  );

  testWidgets('remote Back collapses multiview to the original channel', (
    tester,
  ) async {
    final fixture = _ShellFixture(limit: 2);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    tester.widget<PlayerScreen>(find.byType(PlayerScreen)).onAddChannel!();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browse-row-live-two')));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _pumpUntil(tester, () => fixture.manager.sessions.length == 1);

    expect(find.byType(MultiviewScreen), findsNothing);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(fixture.manager.sessions.single.title, 'Channel One');
    expect(fixture.manager.sessions.single.isAudible, isTrue);
    expect(fixture.transports.created.last.disposed, isTrue);
  });

  testWidgets('failed audio transfer retains the selected tile and focus', (
    tester,
  ) async {
    final transports = _TransportFactory(
      failAfterFirst: false,
      failSecondAudioTransfer: true,
    );
    final manager = PlaybackManager(
      targetResolver: const _Resolver(),
      admissionPort: const _Admission(2),
      transportFactory: transports.create,
    );
    addTearDown(manager.dispose);
    final first = await manager.start(
      const LivePlaybackHandoff(
        sourceId: 'source',
        title: 'Channel One',
        providerItemId: 'one',
        extension: 'ts',
      ),
    );
    final second = await manager.start(
      const LivePlaybackHandoff(
        sourceId: 'source',
        title: 'Channel Two',
        providerItemId: 'two',
        extension: 'ts',
      ),
      requestAudioFocus: false,
    );
    final firstId = (first as PlaybackStarted).sessionId;
    final secondId = (second as PlaybackStarted).sessionId;

    await tester.pumpWidget(
      MaterialApp(
        home: MultiviewScreen(
          manager: manager,
          originalSessionId: firstId,
          secondSessionId: secondId,
          onOpenFullPlayer: (_) {},
          onCloseSession: (_) {},
          onCollapse: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('multiview-second-tile')));
    await tester.pumpAndSettle();

    expect(
      find.text('Audio stayed with the current channel. Try again.'),
      findsOneWidget,
    );
    expect(manager.sessions.first.isAudible, isTrue);
    expect(manager.sessions.last.isAudible, isFalse);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'multiview original stream',
    );
  });

  testWidgets('terminal owner failure selects and focuses replacement owner', (
    tester,
  ) async {
    final transports = _TransportFactory(
      failAfterFirst: false,
      failOpenFrom: 2,
    );
    final manager = PlaybackManager(
      targetResolver: const _Resolver(),
      admissionPort: const _Admission(2),
      transportFactory: transports.create,
    );
    addTearDown(manager.dispose);
    final first = await manager.start(
      const LivePlaybackHandoff(
        sourceId: 'source',
        title: 'Channel One',
        providerItemId: 'one',
        extension: 'ts',
      ),
    );
    final second = await manager.start(
      const LivePlaybackHandoff(
        sourceId: 'source',
        title: 'Channel Two',
        providerItemId: 'two',
        extension: 'ts',
      ),
      requestAudioFocus: false,
    );
    final firstId = (first as PlaybackStarted).sessionId;
    final secondId = (second as PlaybackStarted).sessionId;
    await tester.pumpWidget(
      MaterialApp(
        home: MultiviewScreen(
          manager: manager,
          originalSessionId: firstId,
          secondSessionId: secondId,
          onOpenFullPlayer: (_) {},
          onCloseSession: (_) {},
          onCollapse: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    transports.created.first.emit(const PlaybackTransportState(hasError: true));
    await _pumpUntil(
      tester,
      () =>
          manager.session(firstId)?.phase == PlaybackSessionPhase.failed &&
          (manager.session(secondId)?.isAudible ?? false),
    );

    expect(manager.session(firstId)?.isAudible, isFalse);
    expect(manager.session(secondId)?.isAudible, isTrue);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'multiview second stream',
    );
    expect(find.text('MULTIVIEW · SELECTED'), findsOneWidget);
    expect(
      find.text('No channel is audible. Select a channel to restore audio.'),
      findsNothing,
    );
  });

  testWidgets(
    'failed transfer and failed rollback shows truthful no-audio UI',
    (tester) async {
      final transports = _TransportFactory(
        failAfterFirst: false,
        failSecondAudioTransfer: true,
        failOriginalRollbackUnmute: true,
      );
      final manager = PlaybackManager(
        targetResolver: const _Resolver(),
        admissionPort: const _Admission(2),
        transportFactory: transports.create,
      );
      addTearDown(manager.dispose);
      final first = await manager.start(
        const LivePlaybackHandoff(
          sourceId: 'source',
          title: 'Channel One',
          providerItemId: 'one',
          extension: 'ts',
        ),
      );
      final second = await manager.start(
        const LivePlaybackHandoff(
          sourceId: 'source',
          title: 'Channel Two',
          providerItemId: 'two',
          extension: 'ts',
        ),
        requestAudioFocus: false,
      );
      final firstId = (first as PlaybackStarted).sessionId;
      final secondId = (second as PlaybackStarted).sessionId;
      await tester.pumpWidget(
        MaterialApp(
          home: MultiviewScreen(
            manager: manager,
            originalSessionId: firstId,
            secondSessionId: secondId,
            onOpenFullPlayer: (_) {},
            onCloseSession: (_) {},
            onCollapse: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('multiview-second-tile')));
      await tester.pumpAndSettle();

      expect(manager.sessions.where((session) => session.isAudible), isEmpty);
      expect(find.text('MULTIVIEW · AUDIO OFF'), findsOneWidget);
      expect(
        find.text('No channel is audible. Select a channel to restore audio.'),
        findsOneWidget,
      );
      expect(
        find.text('Audio stayed with the current channel. Try again.'),
        findsNothing,
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'multiview original stream',
      );
    },
  );

  testWidgets('closing the original tile promotes the second session', (
    tester,
  ) async {
    final fixture = _ShellFixture(limit: 2);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    tester.widget<PlayerScreen>(find.byType(PlayerScreen)).onAddChannel!();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browse-row-live-two')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('multiview-close-selected')));
    await _pumpUntil(tester, () => fixture.manager.sessions.length == 1);

    expect(find.byType(MultiviewScreen), findsNothing);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(fixture.manager.sessions.single.title, 'Channel Two');
    expect(fixture.manager.sessions.single.isAudible, isTrue);
    expect(find.byKey(const ValueKey('fake-video-1')), findsNothing);
    expect(find.byKey(const ValueKey('fake-video-2')), findsOneWidget);
    expect(fixture.transports.created.first.disposed, isTrue);
  });

  testWidgets('one-stream admission blocks before a second transport exists', (
    tester,
  ) async {
    final fixture = _ShellFixture(limit: 1);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    player.onAddChannel!();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browse-row-live-two')));
    await _pumpUntil(
      tester,
      () => find
          .text(
            'This source currently allows 1 stream. Cancel adding a second channel, then open Settings to change the local limit.',
          )
          .evaluate()
          .isNotEmpty,
    );

    expect(find.byType(MultiviewScreen), findsNothing);
    expect(find.byType(PipOverlay), findsOneWidget);
    expect(
      find.text(
        'This source currently allows 1 stream. Cancel adding a second channel, then open Settings to change the local limit.',
      ),
      findsOneWidget,
    );
    expect(fixture.manager.sessions, hasLength(1));
    expect(fixture.transports.created, hasLength(1));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(PipOverlay), findsNothing);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-video-1')), findsOneWidget);
    expect(fixture.manager.sessions, hasLength(1));
  });

  testWidgets('failed second opening preserves original usable and audible', (
    tester,
  ) async {
    final fixture = _ShellFixture(limit: 2, failAfterFirst: true);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    player.onAddChannel!();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browse-row-live-two')));
    await _pumpUntil(
      tester,
      () => find
          .text(
            'The second channel could not start. The current channel is still playing.',
          )
          .evaluate()
          .isNotEmpty,
    );

    expect(find.byType(MultiviewScreen), findsNothing);
    expect(find.byType(PipOverlay), findsOneWidget);
    expect(
      find.text(
        'The second channel could not start. The current channel is still playing.',
      ),
      findsOneWidget,
    );
    expect(fixture.manager.sessions, hasLength(1));
    expect(fixture.manager.sessions.single.title, 'Channel One');
    expect(fixture.manager.sessions.single.isAudible, isTrue);
    expect(fixture.transports.created, hasLength(3));
    expect(
      fixture.transports.created.skip(1).every((item) => item.disposed),
      isTrue,
    );
  });

  testWidgets(
    'credential recovery Open Settings exits playback and navigates',
    (tester) async {
      final transports = _TransportFactory(failAfterFirst: false);
      final fixture = _ShellFixture._(
        transports,
        PlaybackManager(
          targetResolver: const _CredentialsMissingResolver(),
          admissionPort: const _Admission(2),
          transportFactory: transports.create,
        ),
      );
      addTearDown(fixture.dispose);
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pumpUntil(
        tester,
        () => find.text('Open Settings').evaluate().isNotEmpty,
      );
      expect(transports.created, isEmpty);

      await tester.tap(find.text('Open Settings'));
      await _pumpUntil(
        tester,
        () => find.text('Sources').evaluate().isNotEmpty,
      );

      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.text('Sources'), findsOneWidget);
      expect(fixture.manager.sessions, isEmpty);
    },
  );
}

bool _semanticsTreeHasLabel(WidgetTester tester, String label) {
  final root = tester
      .binding
      .renderViews
      .single
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  var found = root.label == label;

  void search(SemanticsNode node) {
    node.visitChildren((child) {
      if (child.label == label) found = true;
      if (!found) search(child);
      return !found;
    });
  }

  if (!found) search(root);
  return found;
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var index = 0; index < 40 && !condition(); index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  await tester.pumpAndSettle();
}

Future<void> _activateRailDestinationWithRemote(
  WidgetTester tester,
  String label,
) async {
  final destinationName = switch (label) {
    'My Library' => 'library',
    _ => label.toLowerCase(),
  };
  final detector = find.byKey(ValueKey('shell-destination-$destinationName'));
  tester.widget<FocusableActionDetector>(detector).focusNode!.requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

Future<void> _focusKeyedAction(WidgetTester tester, String key) async {
  final focusFinder = find
      .descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Focus))
      .first;
  tester.widget<Focus>(focusFinder).focusNode!.requestFocus();
  await tester.pump();
}

Future<void> _focusByDebugLabel(WidgetTester tester, String debugLabel) async {
  final focusFinder = find.byWidgetPredicate(
    (widget) => widget is Focus && widget.focusNode?.debugLabel == debugLabel,
  );
  tester.widget<Focus>(focusFinder).focusNode!.requestFocus();
  await tester.pump();
}

Future<void> _movePipToLeft(WidgetTester tester) async {
  for (var index = 0; index < 5; index++) {
    final corner = tester.widget<PipOverlay>(find.byType(PipOverlay)).corner;
    if (corner == PipCorner.topLeft || corner == PipCorner.bottomLeft) return;
    await tester.tap(find.byKey(const ValueKey('corner-signal-move')));
    await tester.pump();
  }
  fail('Corner Signal did not reach an available left corner.');
}

class _ShellFixture {
  factory _ShellFixture({required int limit, bool failAfterFirst = false}) {
    final transports = _TransportFactory(failAfterFirst: failAfterFirst);
    return _ShellFixture._(
      transports,
      PlaybackManager(
        targetResolver: const _Resolver(),
        admissionPort: _Admission(limit),
        transportFactory: transports.create,
      ),
    );
  }

  _ShellFixture._(this.transports, this.manager);

  final _TransportFactory transports;
  final PlaybackManager manager;
  final HomeController home = HomeController(data: const _HomeData());
  final SourceSetupController sources = SourceSetupController(
    service: const _NoopSetupPort(),
  );

  Widget app() => MaterialApp(
    home: WabbitShell(
      fixtureMode: HomeFixtureMode.runtime,
      initialDestination: ShellDestination.home,
      sourceController: sources,
      browseSource: _source,
      browseData: const _BrowseData(),
      homeController: home,
      playbackManager: manager,
      fullscreenPort: const _Fullscreen(),
    ),
  );

  void dispose() {
    home.dispose();
    sources.dispose();
    manager.dispose();
  }
}

const _source = PersistedSource(
  id: 'source',
  name: 'Strong',
  credentialKey: 'source-key',
  counts: {SourceMediaKind.live: 2},
);

const _one = BrowseCatalogItem(
  id: 'live-one',
  sourceId: 'source',
  libraryItemId: 'library-one',
  kind: SourceMediaKind.live,
  title: 'Channel One',
  artworkLocator: null,
  playbackRef: '{"providerId":"one","kind":"live","extension":"ts"}',
);

const _two = BrowseCatalogItem(
  id: 'live-two',
  sourceId: 'source',
  libraryItemId: 'library-two',
  kind: SourceMediaKind.live,
  title: 'Channel Two',
  artworkLocator: null,
  playbackRef: '{"providerId":"two","kind":"live","extension":"ts"}',
);

class _BrowseData implements BasicBrowseData {
  const _BrowseData();

  @override
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  }) async => const [
    BrowseCategorySummary(
      selection: BrowseCategorySelection.all(),
      name: 'All Live',
      itemCount: 2,
    ),
  ];

  @override
  Future<BrowsePage> browsePage({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit = 100,
  }) async => const BrowsePage(items: [_one, _two], nextCursor: null);
}

class _HomeData implements HomeData {
  const _HomeData();

  @override
  Future<bool> hasSources() async => true;

  @override
  Future<List<HomePersonalShelf>> loadPinnedShelves({
    required int shelfLimit,
    required int itemLimit,
  }) async => const [];

  @override
  Future<List<RecentlyWatchedItem>> loadRecentlyWatched({
    required int limit,
  }) async => [
    RecentlyWatchedItem(
      item: const LibraryCatalogItem(
        libraryItemId: 'library-one',
        catalogItemId: 'catalog-one',
        sourceId: 'source',
        sourceDisplayName: 'Strong',
        kind: SourceMediaKind.live,
        title: 'Channel One',
        artworkLocator: null,
        playbackRef: '{"providerId":"one","kind":"live","extension":"ts"}',
      ),
      lastPlayedAt: DateTime.utc(2026, 8, 19),
    ),
  ];

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async =>
      sourceId == 'source' ? _source : null;
}

class _Resolver implements PlaybackTargetResolverPort {
  const _Resolver();

  @override
  Future<PlaybackResolvedTarget> resolve(PlaybackHandoff handoff) async =>
      PlaybackResolvedTarget(uri: Uri.parse('https://stream.example/video'));
}

class _CredentialsMissingResolver implements PlaybackTargetResolverPort {
  const _CredentialsMissingResolver();

  @override
  Future<PlaybackResolvedTarget> resolve(PlaybackHandoff handoff) async =>
      throw const PlaybackResolutionException(
        PlaybackSessionFailure.credentialsUnavailable,
      );
}

class _Admission implements PlaybackAdmissionPort {
  const _Admission(this.limit);

  final int limit;

  @override
  Future<int> effectiveLimitForSource(String sourceId) async => limit;
}

class _TransportFactory {
  _TransportFactory({
    required this.failAfterFirst,
    this.failSecondAudioTransfer = false,
    this.failOriginalRollbackUnmute = false,
    this.failOpenFrom,
  });

  final bool failAfterFirst;
  final bool failSecondAudioTransfer;
  final bool failOriginalRollbackUnmute;
  final int? failOpenFrom;
  final created = <_Transport>[];

  PlaybackTransport create() {
    final value = _Transport(
      created.length + 1,
      failOpen:
          (failAfterFirst && created.isNotEmpty) ||
          (failOpenFrom != null && created.length >= failOpenFrom!),
      failUnmute: failSecondAudioTransfer && created.isNotEmpty,
      failUnmuteAfterFirst: failOriginalRollbackUnmute && created.isEmpty,
    );
    created.add(value);
    return value;
  }
}

class _Transport implements PlaybackTransport {
  _Transport(
    this.number, {
    required this.failOpen,
    this.failUnmute = false,
    this.failUnmuteAfterFirst = false,
  });

  final int number;
  final bool failOpen;
  final bool failUnmute;
  final bool failUnmuteAfterFirst;
  int _unmuteCalls = 0;
  bool disposed = false;
  final _states = StreamController<PlaybackTransportState>.broadcast(
    sync: true,
  );

  @override
  Stream<PlaybackTransportState> get states => _states.stream;

  @override
  Widget buildVideo() =>
      SizedBox(key: ValueKey('fake-video-$number'), width: 16, height: 9);

  @override
  Future<void> open(
    Uri uri, {
    Map<String, String> httpHeaders = const {},
  }) async {
    if (failOpen) throw StateError('private failure');
    _states.add(
      const PlaybackTransportState(
        hasVideo: true,
        isPlaying: true,
        duration: Duration(hours: 1),
      ),
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    unawaited(_states.close());
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setMuted(bool muted) async {
    if (!muted) {
      _unmuteCalls += 1;
      if (failUnmute || (failUnmuteAfterFirst && _unmuteCalls > 1)) {
        throw StateError('private audio failure');
      }
    }
  }

  @override
  Future<void> setVolume(double volume) async {}

  void emit(PlaybackTransportState state) => _states.add(state);
}

class _NoopSetupPort implements SourceSetupPort {
  const _NoopSetupPort();

  @override
  Future<SourceReady> commit(
    SourceDefinition source,
    List<ImportedStage> stages,
  ) => throw UnimplementedError();
  @override
  Future<ImportedStage> fetch(SourceDefinition source, SourceMediaKind kind) =>
      throw UnimplementedError();
  @override
  Future<void> remove(String sourceId) async {}
}

class _Fullscreen implements FullscreenPort {
  const _Fullscreen();
  @override
  Future<bool> get isFullscreen async => false;
  @override
  Future<void> setFullscreen(bool value) async {}
}
