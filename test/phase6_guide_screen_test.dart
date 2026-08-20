import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/basic_browse_screen.dart';
import 'package:wabbit_tv/src/app_shell.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/guide/guide_data.dart';
import 'package:wabbit_tv/src/features/guide/guide_screen.dart';
import 'package:wabbit_tv/src/features/playback/pip_overlay.dart';
import 'package:wabbit_tv/src/features/playback/playback_manager.dart';
import 'package:wabbit_tv/src/features/playback/playback_transport.dart';
import 'package:wabbit_tv/src/features/playback/player_screen.dart';
import 'package:wabbit_tv/src/features/sources/epg_models.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/home_fixture_mode.dart';

void main() {
  testWidgets('classic matrix loads cache first and tunes exact channel', (
    tester,
  ) async {
    final data = _GuideFixtureData();
    PlaybackHandoff? tuned;
    await tester.pumpWidget(
      _guideApp(data: data, onPlayback: (handoff) => tuned = handoff),
    );
    await tester.pumpAndSettle();

    expect(find.text('Guide'), findsOneWidget);
    expect(find.text('Fixture Xtream'), findsWidgets);
    expect(find.text('All Live'), findsWidgets);
    expect(find.text('Channel One'), findsOneWidget);
    expect(find.text('Morning News'), findsOneWidget);
    expect(find.byKey(const ValueKey('guide-channel-list')), findsOneWidget);
    expect(data.loadedWindowIds, isNotEmpty);
    expect(data.loadedWindowIds.length, lessThanOrEqualTo(20));
    expect(data.refreshedIds.length, lessThanOrEqualTo(20));

    await tester.tap(find.byKey(const ValueKey('guide-channel-channel-1')));
    expect(tuned, isA<LivePlaybackHandoff>());
    expect((tuned! as LivePlaybackHandoff).providerItemId, '101');
  });

  testWidgets('D-pad enters programs, follows nearest row, and tunes', (
    tester,
  ) async {
    final data = _GuideFixtureData();
    PlaybackHandoff? tuned;
    await tester.pumpWidget(
      _guideApp(data: data, onPlayback: (handoff) => tuned = handoff),
    );
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'guide initial');
    final initialProgramFocus = tester.widget<Focus>(
      find
          .descendant(
            of: find.byKey(
              _guideProgramKey(
                'channel-1',
                DateTime.utc(2026, 8, 19, 10),
                DateTime.utc(2026, 8, 19, 11),
              ),
            ),
            matching: find.byType(Focus),
          )
          .first,
    );
    expect(initialProgramFocus.focusNode?.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'guide program');
    expect(
      find.byKey(
        _guideProgramKey(
          'channel-1',
          DateTime.utc(2026, 8, 19, 10),
          DateTime.utc(2026, 8, 19, 11),
        ),
      ),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'guide program');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect((tuned! as LivePlaybackHandoff).providerItemId, '202');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'guide category');
  });

  testWidgets('category selection remains source-local and resets rows', (
    tester,
  ) async {
    final data = _GuideFixtureData();
    await tester.pumpWidget(_guideApp(data: data));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('guide-dropdown-Category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('News').last);
    await tester.pumpAndSettle();

    expect(find.text('Channel One'), findsOneWidget);
    expect(find.text('Channel Two'), findsNothing);
    expect(data.lastSelection?.sourceGroupId, 7);
  });

  testWidgets('failed source switch clears old rows and Retry recovers', (
    tester,
  ) async {
    final failingSources = <String>{'source-2'};
    final data = _GuideFixtureData(
      sources: const [_source, _sourceB],
      channels: const [..._fixtureChannels, _fixtureSourceBChannel],
      failingChannelSourceIds: failingSources,
    );
    final session = GuideSession();
    PlaybackHandoff? tuned;
    await tester.pumpWidget(
      _guideApp(
        data: data,
        session: session,
        onPlayback: (handoff) => tuned = handoff,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Channel One'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('guide-dropdown-Source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backup Xtream').last);
    await tester.pumpAndSettle();

    expect(session.sourceId, 'source-2');
    expect(find.text('Guide unavailable'), findsOneWidget);
    expect(find.text('Channel One'), findsNothing);
    expect(find.byKey(const ValueKey('guide-channel-channel-1')), findsNothing);
    expect(tuned, isNull);
    expect(data.cancelCalls, 1);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'guide initial');

    failingSources.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(find.text('Backup News'), findsOneWidget);
    expect(find.text('Channel One'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('guide-channel-channel-backup')),
    );
    expect((tuned! as LivePlaybackHandoff).sourceId, 'source-2');
  });

  testWidgets('Escape dismisses selector before Left reaches the rail', (
    tester,
  ) async {
    var railOpenCount = 0;
    final data = _GuideFixtureData();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GuideScreen(
            initialFocus: FocusNode(debugLabel: 'guide initial'),
            onContentFocus: (_) {},
            onOpenRail: () => railOpenCount += 1,
            session: GuideSession(),
            onPlaybackHandoff: (_) {},
            data: data,
            onBrowseLive: () {},
            onOpenSettings: () {},
            now: () => _now,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('guide-dropdown-Category')));
    await tester.pumpAndSettle();
    expect(find.text('News'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('News'), findsNothing);
    expect(railOpenCount, 0);

    final firstChannel = tester.widget<Focus>(
      find
          .descendant(
            of: find.byKey(const ValueKey('guide-channel-channel-1')),
            matching: find.byType(Focus),
          )
          .first,
    );
    firstChannel.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(railOpenCount, 1);
  });

  testWidgets('horizontal ruler reveals later exact-duration programs', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_guideApp(data: _GuideFixtureData()));
    await tester.pumpAndSettle();
    final late = find.byKey(
      _guideProgramKey(
        'channel-1',
        DateTime.utc(2026, 8, 19, 16),
        DateTime.utc(2026, 8, 19, 17),
      ),
    );
    expect(tester.getRect(late).left, greaterThan(1265));

    await tester.drag(
      find.byKey(const ValueKey('guide-time-ruler-scroll')),
      const Offset(-900, 0),
    );
    await tester.pumpAndSettle();

    expect(tester.getRect(late).left, lessThan(1265));
    expect(
      find
          .byKey(
            _guideProgramVisualKey(
              'channel-1',
              DateTime.utc(2026, 8, 19, 16),
              DateTime.utc(2026, 8, 19, 17),
            ),
          )
          .hitTestable(),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('guide-go-now')), findsOneWidget);
    final ruler = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('guide-time-ruler-scroll')),
    );
    final awayOffset = ruler.controller!.offset;
    await tester.tap(find.byKey(const ValueKey('guide-go-now')));
    await tester.pumpAndSettle();
    expect(ruler.controller!.offset, lessThan(awayOffset));
  });

  testWidgets('saved schedule survives a channel refresh failure', (
    tester,
  ) async {
    final data = _GuideFixtureData(
      availability: EpgAvailability.temporarilyUnavailable,
      refreshSummary: const EpgRefreshSummary(
        claimed: 2,
        refreshed: 0,
        empty: 0,
        failed: 2,
        unsupported: 0,
      ),
    );
    await tester.pumpWidget(_guideApp(data: data));
    await tester.pumpAndSettle();

    expect(find.text('Morning News'), findsOneWidget);
    expect(
      find.text('Guide update failed · showing saved schedule'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('guide-retry')), findsOneWidget);
  });

  testWidgets('no capable Xtream source offers Live and Settings paths', (
    tester,
  ) async {
    var live = false;
    var settings = false;
    await tester.pumpWidget(
      _guideApp(
        data: _GuideFixtureData(sources: const []),
        onBrowseLive: () => live = true,
        onSettings: () => settings = true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Guide needs an Xtream source'), findsOneWidget);
    expect(
      find.textContaining('M3U channels remain available'),
      findsOneWidget,
    );
    await tester.tap(find.text('Open Settings'));
    await tester.tap(find.text('Browse Live'));
    expect(settings, isTrue);
    expect(live, isTrue);
  });

  testWidgets('unsupported source keeps exact channel tuning available', (
    tester,
  ) async {
    final data = _GuideFixtureData(
      availability: EpgAvailability.unsupported,
      programs: const [],
    );
    PlaybackHandoff? tuned;
    await tester.pumpWidget(
      _guideApp(data: data, onPlayback: (handoff) => tuned = handoff),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('does not expose a short Live guide'),
      findsOneWidget,
    );
    expect(find.text('No schedule available'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('guide-channel-channel-2')));
    expect((tuned! as LivePlaybackHandoff).providerItemId, '202');
  });

  testWidgets('stationary empty window gets one bounded retry wakeup', (
    tester,
  ) async {
    var clock = _now;
    final data = _GuideFixtureData(
      availability: EpgAvailability.empty,
      programs: const [],
    );
    await tester.pumpWidget(_guideApp(data: data, now: () => clock));
    await tester.pumpAndSettle();
    expect(data.refreshCalls, 1);

    clock = clock.add(const Duration(minutes: 15, milliseconds: 200));
    await tester.pump(const Duration(minutes: 15, milliseconds: 200));
    await tester.pump();

    expect(data.refreshCalls, 2);
  });

  testWidgets('unsettled rows stay preparing until guide absence is known', (
    tester,
  ) async {
    for (final availability in [
      EpgAvailability.unknown,
      EpgAvailability.refreshing,
    ]) {
      await tester.pumpWidget(
        _guideApp(
          data: _GuideFixtureData(
            availability: availability,
            programs: const [],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Preparing schedule…'), findsNWidgets(3));
      expect(find.text('No schedule available'), findsNothing);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      _guideApp(
        data: _GuideFixtureData(
          availability: EpgAvailability.empty,
          programs: const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Preparing schedule…'), findsNothing);
    expect(find.text('No schedule available'), findsNWidgets(2));
    expect(
      find.text(
        'No schedule for these channels · channels remain ready to tune',
      ),
      findsOneWidget,
    );
  });

  testWidgets('40 settled empty channels report only the active viewport', (
    tester,
  ) async {
    final data = _GuideFixtureData(
      channels: _manyChannels(40),
      availability: EpgAvailability.empty,
      programs: const [],
    );
    await tester.pumpWidget(_guideApp(data: data));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'No schedule for these channels · channels remain ready to tune',
      ),
      findsOneWidget,
    );
    expect(find.text('Preparing schedule…'), findsNothing);
    expect(data.loadedWindowIds, isNotEmpty);
    expect(data.loadedWindowIds.length, lessThanOrEqualTo(20));
    expect(data.loadedWindowIds.length, lessThan(40));
  });

  testWidgets('previous viewport stays settled without another provider wave', (
    tester,
  ) async {
    final reverseRead = Completer<void>();
    var blockReverse = false;
    final data = _GuideFixtureData(
      channels: _manyChannels(40),
      availability: EpgAvailability.empty,
      programs: const [],
      beforeEpgRead: (ids) async {
        if (blockReverse && ids.first == 'channel-001') {
          await reverseRead.future;
        }
      },
    );
    await tester.pumpWidget(_guideApp(data: data));
    await tester.pumpAndSettle();

    final list = find.byKey(const ValueKey('guide-channel-list'));
    await tester.drag(list, const Offset(0, -720));
    await tester.pumpAndSettle();
    expect(data.loadedWindowIds.first, isNot('channel-001'));
    final refreshesAfterDown = data.refreshCalls;

    blockReverse = true;
    await tester.drag(list, const Offset(0, 720));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump();

    expect(find.text('Preparing schedule…'), findsNothing);
    expect(
      find.text(
        'No schedule for these channels · channels remain ready to tune',
      ),
      findsOneWidget,
    );
    expect(data.refreshCalls, refreshesAfterDown);

    reverseRead.complete();
    await tester.pumpAndSettle();
    expect(data.refreshCalls, refreshesAfterDown);
  });

  testWidgets('three-view LRU keeps gated A to B to C to A terminal', (
    tester,
  ) async {
    final returningA = Completer<void>();
    var blockReturningA = false;
    final data = _GuideFixtureData(
      channels: _manyChannels(40),
      availability: EpgAvailability.empty,
      programs: const [],
      beforeEpgRead: (ids) async {
        if (blockReturningA && ids.first == 'channel-001') {
          await returningA.future;
        }
      },
    );
    await tester.pumpWidget(_guideApp(data: data));
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('guide-channel-list')),
    );
    list.controller!.jumpTo(900);
    await tester.pumpAndSettle();
    final bFirst = data.loadedWindowIds.first;
    expect(bFirst, isNot('channel-001'));

    list.controller!.jumpTo(1800);
    await tester.pumpAndSettle();
    final cFirst = data.loadedWindowIds.first;
    expect(cFirst, isNot(anyOf('channel-001', bFirst)));
    final refreshesAfterC = data.refreshCalls;

    blockReturningA = true;
    list.controller!.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump();

    expect(find.text('Preparing schedule…'), findsNothing);
    expect(
      find.text(
        'No schedule for these channels · channels remain ready to tune',
      ),
      findsOneWidget,
    );
    expect(data.refreshCalls, refreshesAfterC);

    returningA.complete();
    await tester.pumpAndSettle();
    expect(data.refreshCalls, refreshesAfterC);
  });

  testWidgets('three disjoint tall 40-row views retain A through B and C', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final returningA = Completer<void>();
    var blockReturningA = false;
    final data = _GuideFixtureData(
      channels: _manyChannels(120),
      returnAllChannelsInFirstPage: true,
      availability: EpgAvailability.empty,
      programs: const [],
      beforeEpgRead: (ids) async {
        if (blockReturningA && ids.first == 'channel-001') {
          await returningA.future;
        }
      },
    );
    await tester.pumpWidget(_guideApp(data: data));
    await tester.pumpAndSettle();
    expect(data.loadedWindowIds, hasLength(40));
    expect(data.loadedWindowIds.first, 'channel-001');
    expect(data.loadedWindowIds.last, 'channel-040');

    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('guide-channel-list')),
    );
    list.controller!.jumpTo(42 * 66);
    await tester.pumpAndSettle();
    expect(data.loadedWindowIds, hasLength(40));
    expect(data.loadedWindowIds.first, 'channel-041');
    expect(data.loadedWindowIds.last, 'channel-080');

    list.controller!.jumpTo(82 * 66);
    await tester.pumpAndSettle();
    expect(data.loadedWindowIds, hasLength(40));
    expect(data.loadedWindowIds.first, 'channel-081');
    expect(data.loadedWindowIds.last, 'channel-120');
    final refreshesAfterC = data.refreshCalls;

    blockReturningA = true;
    list.controller!.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump();

    expect(find.text('Preparing schedule…'), findsNothing);
    expect(
      find.text(
        'No schedule for these channels · channels remain ready to tune',
      ),
      findsOneWidget,
    );
    expect(data.refreshCalls, refreshesAfterC);

    returningA.complete();
    await tester.pumpAndSettle();
    expect(data.refreshCalls, refreshesAfterC);
  });

  testWidgets('delayed A to B to A read cannot replace latest viewport truth', (
    tester,
  ) async {
    final middleRead = Completer<void>();
    var holdMiddle = false;
    var middlePending = false;
    final data = _GuideFixtureData(
      channels: _manyChannels(40),
      availability: EpgAvailability.empty,
      programs: const [],
      beforeEpgRead: (ids) async {
        if (holdMiddle && ids.first != 'channel-001') {
          middlePending = true;
          await middleRead.future;
        }
      },
    );
    await tester.pumpWidget(_guideApp(data: data));
    await tester.pumpAndSettle();

    final list = find.byKey(const ValueKey('guide-channel-list'));
    holdMiddle = true;
    await tester.drag(list, const Offset(0, -720));
    await tester.pump(const Duration(milliseconds: 160));
    expect(middlePending, isTrue);

    await tester.drag(list, const Offset(0, 720));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump();
    expect(find.text('Channel 001'), findsOneWidget);
    expect(find.text('Preparing schedule…'), findsNothing);

    middleRead.complete();
    await tester.pumpAndSettle();
    expect(find.text('Channel 001'), findsOneWidget);
    expect(find.text('Preparing schedule…'), findsNothing);
    expect(
      find.text(
        'No schedule for these channels · channels remain ready to tune',
      ),
      findsOneWidget,
    );
  });

  testWidgets('tall viewport gives every mounted row a bounded local result', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final channels = _manyChannels(40);
    final data = _GuideFixtureData(
      channels: channels,
      availability: EpgAvailability.empty,
      programs: const [],
    );
    await tester.pumpWidget(_guideApp(data: data));
    await tester.pumpAndSettle();

    final listRect = tester.getRect(
      find.byKey(const ValueKey('guide-channel-list')),
    );
    final visibleIds = <String>[];
    for (final channel in channels) {
      final row = find.byKey(ValueKey('guide-channel-${channel.id}'));
      if (row.evaluate().isNotEmpty && tester.getRect(row).overlaps(listRect)) {
        visibleIds.add(channel.id);
      }
    }
    expect(visibleIds.length, greaterThan(20));
    expect(data.loadedWindowIds.length, lessThanOrEqualTo(40));
    expect(data.loadedWindowIds, containsAll(visibleIds));
    expect(find.text('Preparing schedule…'), findsNothing);
  });

  testWidgets('local EPG claim failure exposes Retry and bypasses throttle', (
    tester,
  ) async {
    final data = _GuideFixtureData(
      availability: EpgAvailability.empty,
      programs: const [],
      refreshSummaryForCall: (call) => call == 1
          ? const EpgRefreshSummary(
              claimed: 0,
              refreshed: 0,
              empty: 0,
              failed: 2,
              unsupported: 0,
              failure: EpgRefreshFailure.localPersistence,
            )
          : const EpgRefreshSummary.none(),
    );
    await tester.pumpWidget(_guideApp(data: data));
    await tester.pumpAndSettle();

    expect(
      find.text('Schedule unavailable · channels remain ready to tune'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('guide-retry')), findsOneWidget);
    expect(data.refreshCalls, 1);
    expect(data.refreshManualRetries, const [false]);

    await tester.tap(find.byKey(const ValueKey('guide-retry')));
    await tester.pumpAndSettle();

    expect(data.refreshCalls, 2);
    expect(data.refreshManualRetries, const [false, true]);
    expect(
      find.text(
        'No schedule for these channels · channels remain ready to tune',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'forward page failure preserves rows and remote Retry loads more channels',
    (tester) async {
      final failingCursors = <String>{'channel-040'};
      final data = _GuideFixtureData(
        channels: _manyChannels(95),
        failingForwardPageCursorIds: failingCursors,
      );
      await tester.pumpWidget(_guideApp(data: data));
      await tester.pumpAndSettle();

      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('guide-channel-list')),
      );
      list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'More channels could not be loaded · current channels remain available',
        ),
        findsOneWidget,
      );
      expect(find.text('Retry more channels'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('guide-channel-channel-040')),
        findsOneWidget,
      );
      expect(find.textContaining('Schedule unavailable'), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'guide retry');

      failingCursors.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(find.text('Retry more channels'), findsNothing);
      expect(
        data.forwardPageCursorIds.where((id) => id == 'channel-040'),
        hasLength(2),
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot('guide retry'),
      );
    },
  );

  testWidgets(
    'backward page failure preserves rows and remote Retry loads earlier channels',
    (tester) async {
      final failingCursors = <String>{'channel-045'};
      final data = _GuideFixtureData(
        channels: _manyChannels(95),
        failingPreviousPageCursorIds: failingCursors,
      );
      final session = GuideSession()..focusedChannelId = 'channel-065';
      await tester.pumpWidget(_guideApp(data: data, session: session));
      await tester.pumpAndSettle();

      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('guide-channel-list')),
      );
      list.controller!.jumpTo(0);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Earlier channels could not be loaded · current channels remain available',
        ),
        findsOneWidget,
      );
      expect(find.text('Retry earlier channels'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('guide-channel-channel-045')),
        findsOneWidget,
      );
      expect(find.textContaining('Schedule unavailable'), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'guide retry');

      failingCursors.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(find.text('Retry earlier channels'), findsNothing);
      expect(
        data.previousPageCursorIds.where((id) => id == 'channel-045'),
        hasLength(2),
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot('guide retry'),
      );
    },
  );

  testWidgets(
    'rapid category supersession cancels without awaiting old scope',
    (tester) async {
      final firstCancel = Completer<void>();
      final data = _GuideFixtureData(
        categorySummaries: const [
          BrowseCategorySummary(
            selection: BrowseCategorySelection.all(),
            name: 'All Live',
            itemCount: 2,
          ),
          BrowseCategorySummary(
            selection: BrowseCategorySelection.sourceGroup(7),
            name: 'News',
            itemCount: 1,
          ),
          BrowseCategorySummary(
            selection: BrowseCategorySelection.sourceGroup(8),
            name: 'Sports',
            itemCount: 1,
          ),
        ],
        beforeCancel: (call) async {
          if (call == 1) await firstCancel.future;
        },
      );
      await tester.pumpWidget(_guideApp(data: data));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('guide-dropdown-Category')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('News').last);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('guide-dropdown-Category')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sports').last);
      await tester.pumpAndSettle();

      expect(data.cancelCalls, 2);
      expect(find.text('Sports'), findsOneWidget);
      expect(find.text('Channel Two'), findsOneWidget);
      expect(find.text('Channel One'), findsNothing);

      firstCancel.complete();
      await tester.pumpAndSettle();
      expect(find.text('Sports'), findsOneWidget);
      expect(find.text('Channel Two'), findsOneWidget);
      expect(find.text('Channel One'), findsNothing);
    },
  );

  testWidgets('category failure offers remote Retry and restores old scope', (
    tester,
  ) async {
    final failingGroups = <int>{7};
    final data = _GuideFixtureData(failingCategoryGroupIds: failingGroups);
    final session = GuideSession();
    await tester.pumpWidget(_guideApp(data: data, session: session));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('guide-dropdown-Category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('News').last);
    await tester.pumpAndSettle();

    expect(find.text('Guide category unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Keep current category'), findsOneWidget);
    expect(session.category.kind, BrowseCategorySelectionKind.all);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'guide initial');

    await tester.tap(find.text('Keep current category'));
    await tester.pumpAndSettle();
    expect(find.text('Guide category unavailable'), findsNothing);
    expect(find.text('Channel One'), findsOneWidget);
    expect(find.text('Channel Two'), findsOneWidget);
    expect(session.category.kind, BrowseCategorySelectionKind.all);

    await tester.tap(find.byKey(const ValueKey('guide-dropdown-Category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('News').last);
    await tester.pumpAndSettle();
    failingGroups.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(find.text('Guide category unavailable'), findsNothing);
    expect(find.text('News'), findsWidgets);
    expect(find.text('Channel One'), findsOneWidget);
    expect(find.text('Channel Two'), findsNothing);
    expect(session.category.sourceGroupId, 7);
  });

  testWidgets('Guide disposal cancels the active EPG scope', (tester) async {
    final data = _GuideFixtureData();
    await tester.pumpWidget(_guideApp(data: data));
    await tester.pumpAndSettle();
    expect(data.cancelCalls, 0);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(data.cancelCalls, 1);
  });

  testWidgets('program semantics distinguish past current and upcoming', (
    tester,
  ) async {
    final past = EpgProgram(
      catalogItemId: 'channel-1',
      startUtc: DateTime.utc(2026, 8, 19, 9, 30),
      endUtc: DateTime.utc(2026, 8, 19, 10),
      title: 'Earlier Bulletin',
    );
    await tester.pumpWidget(
      _guideApp(
        data: _GuideFixtureData(
          programs: [past, ..._fixturePrograms('channel-1')],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final semantics = tester.getSemantics(
      find
          .descendant(
            of: find.byKey(
              _guideProgramKey('channel-1', past.startUtc, past.endUtc),
            ),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(semantics.label, contains('Earlier Bulletin'));
    expect(semantics.label, endsWith('past'));
  });

  testWidgets(
    'same-start programs retain distinct end-boundary focus identity',
    (tester) async {
      final start = DateTime.utc(2026, 8, 19, 10, 30);
      final shortEnd = DateTime.utc(2026, 8, 19, 11);
      final longEnd = DateTime.utc(2026, 8, 19, 11, 30);
      final session = GuideSession();
      await tester.pumpWidget(
        _guideApp(
          session: session,
          data: _GuideFixtureData(
            programs: [
              EpgProgram(
                catalogItemId: 'channel-1',
                startUtc: start,
                endUtc: shortEnd,
                title: 'Short Cut',
              ),
              EpgProgram(
                catalogItemId: 'channel-1',
                startUtc: start,
                endUtc: longEnd,
                title: 'Long Cut',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final shortTarget = find.byKey(
        _guideProgramKey('channel-1', start, shortEnd),
      );
      final longTarget = find.byKey(
        _guideProgramKey('channel-1', start, longEnd),
      );
      expect(shortTarget, findsOneWidget);
      expect(longTarget, findsOneWidget);
      final longFocus = tester.widget<Focus>(
        find.descendant(of: longTarget, matching: find.byType(Focus)).first,
      );
      longFocus.focusNode!.requestFocus();
      await tester.pump();

      expect(session.focusedProgramStartUtcMs, start.millisecondsSinceEpoch);
      expect(session.focusedProgramEndUtcMs, longEnd.millisecondsSinceEpoch);
    },
  );

  testWidgets('minute programs keep separate 44px-class interaction targets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final firstStart = DateTime.utc(2026, 8, 19, 10, 20);
    final firstEnd = DateTime.utc(2026, 8, 19, 10, 21);
    final secondEnd = DateTime.utc(2026, 8, 19, 10, 22);
    final session = GuideSession();
    PlaybackHandoff? tuned;
    await tester.pumpWidget(
      _guideApp(
        session: session,
        onPlayback: (handoff) => tuned = handoff,
        data: _GuideFixtureData(
          programs: [
            EpgProgram(
              catalogItemId: 'channel-1',
              startUtc: firstStart,
              endUtc: firstEnd,
              title: 'One Minute One',
            ),
            EpgProgram(
              catalogItemId: 'channel-1',
              startUtc: firstEnd,
              endUtc: secondEnd,
              title: 'One Minute Two',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final firstRect = tester.getRect(
      find.byKey(_guideProgramKey('channel-1', firstStart, firstEnd)),
    );
    final secondRect = tester.getRect(
      find.byKey(_guideProgramKey('channel-1', firstEnd, secondEnd)),
    );
    final truthfulVisual = tester.getRect(
      find.byKey(_guideProgramVisualKey('channel-1', firstStart, firstEnd)),
    );
    expect(truthfulVisual.width, closeTo(3, 0.1));
    expect(firstRect.width, greaterThanOrEqualTo(44));
    expect(secondRect.width, greaterThanOrEqualTo(44));
    expect(firstRect.right, lessThanOrEqualTo(secondRect.left));

    final firstVisual = find.byKey(
      _guideProgramVisualKey('channel-1', firstStart, firstEnd),
    );
    final secondVisual = find.byKey(
      _guideProgramVisualKey('channel-1', firstEnd, secondEnd),
    );
    await tester.tap(firstVisual);
    await tester.pump();
    expect(tuned, isA<LivePlaybackHandoff>());
    expect(session.focusedProgramEndUtcMs, firstEnd.millisecondsSinceEpoch);
    expect(find.textContaining('One Minute One ·'), findsOneWidget);
    var decoration =
        tester
                .widget<AnimatedContainer>(
                  find
                      .descendant(
                        of: firstVisual,
                        matching: find.byType(AnimatedContainer),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(decoration.border!.top.color, const Color(0xFFFFB347));

    await tester.tap(secondVisual);
    await tester.pump();
    expect(session.focusedProgramEndUtcMs, secondEnd.millisecondsSinceEpoch);
    expect(find.textContaining('One Minute Two ·'), findsOneWidget);
    decoration =
        tester
                .widget<AnimatedContainer>(
                  find
                      .descendant(
                        of: secondVisual,
                        matching: find.byType(AnimatedContainer),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(decoration.border!.top.color, const Color(0xFFFFB347));
  });

  testWidgets('matrix retains its composition at constrained high text scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _guideApp(
        data: _GuideFixtureData(),
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('guide-channel-list')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('guide-time-ruler-scroll')),
      findsOneWidget,
    );
    expect(find.text('Morning News'), findsOneWidget);
  });

  testWidgets('Live browse shows quiet exact cached Now and Next only', (
    tester,
  ) async {
    final data = _GuideFixtureData();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BasicBrowseScreen(
            kind: SourceMediaKind.live,
            source: const PersistedSource(
              id: 'source-1',
              name: 'Fixture Xtream',
              credentialKey: 'unused',
              counts: {
                SourceMediaKind.live: 2,
                SourceMediaKind.movies: 0,
                SourceMediaKind.series: 0,
              },
            ),
            initialFocus: FocusNode(debugLabel: 'browse guide initial'),
            onContentFocus: (_) {},
            onOpenRail: () {},
            session: BasicBrowseSession(),
            data: data,
            epgWindowPort: data,
            now: () => _now,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('browse-now-next-channel-1')),
      findsOneWidget,
    );
    expect(find.textContaining('Now · Morning News'), findsOneWidget);
    expect(find.textContaining('Next ·'), findsNWidgets(2));
    expect(data.loadedWindowIds.length, lessThanOrEqualTo(20));
    expect(data.refreshedIds.length, lessThanOrEqualTo(20));
  });

  testWidgets('shell places Guide after Live and restores its exact row', (
    tester,
  ) async {
    final manager = PlaybackManager(
      targetResolver: const _GuideResolver(),
      admissionPort: const _GuideAdmission(),
      transportFactory: _GuideTransport.new,
    );
    addTearDown(manager.dispose);
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: WabbitShell(
          fixtureMode: HomeFixtureMode.populated,
          initialDestination: ShellDestination.guide,
          guideData: _GuideFixtureData(),
          playbackManager: manager,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final live = tester.getCenter(
      find.byKey(const ValueKey('shell-destination-live')),
    );
    final guide = tester.getCenter(
      find.byKey(const ValueKey('shell-destination-guide')),
    );
    final movies = tester.getCenter(
      find.byKey(const ValueKey('shell-destination-movies')),
    );
    expect(guide.dy, greaterThan(live.dy));
    expect(guide.dy, lessThan(movies.dy));

    await tester.tap(find.byKey(const ValueKey('guide-channel-channel-2')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);
    await tester.runAsync(
      () async =>
          tester.widget<PlayerScreen>(find.byType(PlayerScreen)).onExit(),
    );
    await tester.pumpAndSettle();

    expect(find.byType(GuideScreen), findsOneWidget);
    final restoredChannelFocus = tester.widget<Focus>(
      find
          .descendant(
            of: find.byKey(const ValueKey('guide-channel-channel-2')),
            matching: find.byType(Focus),
          )
          .first,
    );
    expect(restoredChannelFocus.focusNode?.hasFocus, isTrue);
  });

  testWidgets('Guide remount restores the exact program after cache settles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = _GuideFixtureData(
      epgReadDelay: const Duration(milliseconds: 40),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: WabbitShell(
          fixtureMode: HomeFixtureMode.populated,
          initialDestination: ShellDestination.guide,
          guideData: data,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final firstKey = _guideProgramKey(
      'channel-1',
      DateTime.utc(2026, 8, 19, 10),
      DateTime.utc(2026, 8, 19, 11),
    );
    final firstFocus = tester.widget<Focus>(
      find
          .descendant(of: find.byKey(firstKey), matching: find.byType(Focus))
          .first,
    );
    firstFocus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final restoredKey = _guideProgramKey(
      'channel-1',
      DateTime.utc(2026, 8, 19, 11),
      DateTime.utc(2026, 8, 19, 12),
    );
    expect(
      tester
          .widget<Focus>(
            find
                .descendant(
                  of: find.byKey(restoredKey),
                  matching: find.byType(Focus),
                )
                .first,
          )
          .focusNode
          ?.hasFocus,
      isTrue,
    );

    await _activateShellDestination(tester, ShellDestination.movies);
    expect(find.byType(GuideScreen), findsNothing);
    await _activateShellDestination(tester, ShellDestination.guide);

    expect(
      tester
          .widget<Focus>(
            find
                .descendant(
                  of: find.byKey(restoredKey),
                  matching: find.byType(Focus),
                )
                .first,
          )
          .focusNode
          ?.hasFocus,
      isTrue,
    );
  });

  testWidgets('Guide remount restores a channel beyond the first local page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final channels = _manyChannels(95);
    final data = _GuideFixtureData(channels: channels);
    final session = GuideSession();
    await tester.pumpWidget(_guideApp(data: data, session: session));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('guide-channel-list')),
      const Offset(0, -3000),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('guide-channel-list')),
      const Offset(0, -1800),
    );
    await tester.pumpAndSettle();

    final deepChannel = find.byKey(const ValueKey('guide-channel-channel-065'));
    expect(deepChannel, findsOneWidget);
    final channelFocus = tester.widget<Focus>(
      find.descendant(of: deepChannel, matching: find.byType(Focus)).first,
    );
    channelFocus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final exactProgram = _guideProgramKey(
      'channel-065',
      DateTime.utc(2026, 8, 19, 10),
      DateTime.utc(2026, 8, 19, 11),
    );
    expect(
      tester
          .widget<Focus>(
            find
                .descendant(
                  of: find.byKey(exactProgram),
                  matching: find.byType(Focus),
                )
                .first,
          )
          .focusNode
          ?.hasFocus,
      isTrue,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_guideApp(data: data, session: session));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('guide-channel-channel-065')),
      findsOneWidget,
    );
    expect(data.loadedWindowIds, contains('channel-065'));
    expect(
      tester
          .widget<Focus>(
            find
                .descendant(
                  of: find.byKey(exactProgram),
                  matching: find.byType(Focus),
                )
                .first,
          )
          .focusNode
          ?.hasFocus,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey('guide-channel-channel-064')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('guide-channel-channel-066')),
      findsOneWidget,
    );
    expect(find.text('All Live · 95 channels'), findsOneWidget);

    for (var attempt = 0; attempt < 3; attempt++) {
      await tester.drag(
        find.byKey(const ValueKey('guide-channel-list')),
        const Offset(0, 5000),
      );
      await tester.pumpAndSettle();
    }
    expect(
      find.byKey(const ValueKey('guide-channel-channel-001')),
      findsOneWidget,
    );
    expect(data.previousPageCursorIds, contains('channel-045'));

    for (var attempt = 0; attempt < 3; attempt++) {
      await tester.drag(
        find.byKey(const ValueKey('guide-channel-list')),
        const Offset(0, -8000),
      );
      await tester.pumpAndSettle();
    }
    expect(
      find.byKey(const ValueKey('guide-channel-channel-095')),
      findsOneWidget,
    );
    expect(data.forwardPageCursorIds, contains('channel-084'));
    expect(find.text('All Live · 95 channels'), findsOneWidget);
  });

  testWidgets('deep remount revalidates every nonfocused restored row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final removed = <String>{};
    final data = _GuideFixtureData(
      channels: _manyChannels(95),
      removedChannelIds: removed,
    );
    final session = GuideSession()..focusedChannelId = 'channel-065';

    await tester.pumpWidget(_guideApp(data: data, session: session));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('guide-channel-channel-064')),
      findsOneWidget,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    removed.add('channel-064');
    await tester.pumpWidget(_guideApp(data: data, session: session));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('guide-channel-channel-064')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('guide-channel-channel-065')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('guide-channel-channel-066')),
      findsOneWidget,
    );
    expect(find.text('All Live · 94 channels'), findsOneWidget);
  });

  testWidgets('offscreen exact program remount is revealed and focused', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final start = DateTime.utc(2026, 8, 19, 10);
    final end = DateTime.utc(2026, 8, 19, 11);
    final session = GuideSession()
      ..focusedChannelId = 'channel-065'
      ..focusedProgramStartUtcMs = start.millisecondsSinceEpoch
      ..focusedProgramEndUtcMs = end.millisecondsSinceEpoch;
    final data = _GuideFixtureData(channels: _manyChannels(95));
    final exact = _guideProgramKey('channel-065', start, end);
    await tester.pumpWidget(
      _guideApp(
        data: data,
        session: session,
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Focus>(
            find
                .descendant(of: find.byKey(exact), matching: find.byType(Focus))
                .first,
          )
          .focusNode
          ?.hasFocus,
      isTrue,
    );

    final list = find.byKey(const ValueKey('guide-channel-list'));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(list),
        scrollDelta: const Offset(0, 1800),
      ),
    );
    await tester.pumpAndSettle();
    final listRect = tester.getRect(list);
    final offscreen = find.byKey(exact);
    expect(
      offscreen.evaluate().isEmpty ||
          !tester.getRect(offscreen).overlaps(listRect),
      isTrue,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpWidget(
      _guideApp(
        data: data,
        session: session,
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();

    final restored = find.byKey(exact);
    final restoredFocus = tester.widget<Focus>(
      find.descendant(of: restored, matching: find.byType(Focus)).first,
    );
    expect(restoredFocus.focusNode?.hasFocus, isTrue);
    expect(tester.getRect(restored).overlaps(tester.getRect(list)), isTrue);
  });

  testWidgets('offscreen exact program remains visible across 1x to 2x', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final start = DateTime.utc(2026, 8, 19, 10);
    final end = DateTime.utc(2026, 8, 19, 11);
    final session = GuideSession()
      ..focusedChannelId = 'channel-065'
      ..focusedProgramStartUtcMs = start.millisecondsSinceEpoch
      ..focusedProgramEndUtcMs = end.millisecondsSinceEpoch;
    final data = _GuideFixtureData(channels: _manyChannels(95));
    final exact = _guideProgramKey('channel-065', start, end);
    await tester.pumpWidget(_guideApp(data: data, session: session));
    await tester.pumpAndSettle();

    final list = find.byKey(const ValueKey('guide-channel-list'));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(list),
        scrollDelta: const Offset(0, 1800),
      ),
    );
    await tester.pumpAndSettle();
    final offscreen = find.byKey(exact);
    expect(
      offscreen.evaluate().isEmpty ||
          !tester.getRect(offscreen).overlaps(tester.getRect(list)),
      isTrue,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpWidget(
      _guideApp(
        data: data,
        session: session,
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();

    final restored = find.byKey(exact);
    final restoredFocus = tester.widget<Focus>(
      find.descendant(of: restored, matching: find.byType(Focus)).first,
    );
    expect(restoredFocus.focusNode?.hasFocus, isTrue);
    expect(tester.getRect(restored).overlaps(tester.getRect(list)), isTrue);
  });

  testWidgets('delayed prepend preserves focused row state and live offset', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gate = Completer<void>();
    final data = _GuideFixtureData(
      channels: _manyChannels(95),
      previousPageGate: gate,
    );
    final session = GuideSession()..focusedChannelId = 'channel-045';
    await tester.pumpWidget(_guideApp(data: data, session: session));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    for (var move = 0; move < 16; move++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
    }

    final list = find.byKey(const ValueKey('guide-channel-list'));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(list),
        scrollDelta: const Offset(0, -500),
      ),
    );
    await tester.pump();
    expect(data.previousPageCursorIds, contains('channel-025'));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(list),
        scrollDelta: const Offset(0, 50),
      ),
    );
    await tester.pump();
    final focusedProgram = _guideProgramKey(
      'channel-029',
      DateTime.utc(2026, 8, 19, 10),
      DateTime.utc(2026, 8, 19, 11),
    );
    final beforeFinder = find.byKey(focusedProgram);
    final beforeTop = tester.getTopLeft(beforeFinder).dy;
    final beforeFocus = tester.widget<Focus>(
      find.descendant(of: beforeFinder, matching: find.byType(Focus)).first,
    );
    expect(beforeFocus.focusNode?.hasFocus, isTrue);

    gate.complete();
    await tester.pumpAndSettle();

    final afterFinder = find.byKey(focusedProgram);
    final afterFocus = tester.widget<Focus>(
      find.descendant(of: afterFinder, matching: find.byType(Focus)).first,
    );
    expect(
      afterFocus.focusNode?.hasFocus,
      isTrue,
      reason:
          'primary=${FocusManager.instance.primaryFocus?.debugLabel}, session=${session.focusedChannelId}',
    );
    expect(identical(afterFocus.focusNode, beforeFocus.focusNode), isTrue);
    expect(tester.getTopLeft(afterFinder).dy, closeTo(beforeTop, 0.1));
  });

  testWidgets('removed saved channel remount falls back to first viable row', (
    tester,
  ) async {
    final removed = <String>{};
    final data = _GuideFixtureData(
      channels: _manyChannels(3),
      removedChannelIds: removed,
    );
    final session = GuideSession();
    await tester.pumpWidget(_guideApp(data: data, session: session));
    await tester.pumpAndSettle();
    final second = tester.widget<Focus>(
      find
          .descendant(
            of: find.byKey(const ValueKey('guide-channel-channel-002')),
            matching: find.byType(Focus),
          )
          .first,
    );
    second.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(session.focusedChannelId, 'channel-002');

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    removed.add('channel-002');
    await tester.pumpWidget(_guideApp(data: data, session: session));
    await tester.pumpAndSettle();

    expect(session.focusedChannelId, 'channel-001');
    expect(session.focusedProgramStartUtcMs, isNull);
    expect(
      find.textContaining('Saved Guide channel is no longer available'),
      findsOneWidget,
    );
    final first = tester.widget<Focus>(
      find
          .descendant(
            of: find.byKey(const ValueKey('guide-channel-channel-001')),
            matching: find.byType(Focus),
          )
          .first,
    );
    expect(first.focusNode?.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('Channel 003 · Live channel'), findsOneWidget);
    expect(
      find.textContaining('Saved Guide channel is no longer available'),
      findsNothing,
    );
  });

  testWidgets(
    'resolved scope fallback is announced once and yields to focused context',
    (tester) async {
      final session = GuideSession()
        ..sourceId = 'removed-source'
        ..category = const BrowseCategorySelection.sourceGroup(999);
      await tester.pumpWidget(
        _guideApp(data: _GuideFixtureData(), session: session),
      );
      await tester.pumpAndSettle();

      const message =
          'Saved Guide source and category are unavailable · showing Fixture Xtream · All Live.';
      expect(find.text(message), findsOneWidget);
      final announced = tester.getSemantics(
        find.byKey(const ValueKey('guide-focus-context')),
      );
      expect(announced.getSemanticsData().flagsCollection.isLiveRegion, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(find.text(message), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('guide-focus-context')))
            .data,
        contains('Local Weather'),
      );
      final settled = tester.getSemantics(
        find.byKey(const ValueKey('guide-focus-context')),
      );
      expect(settled.getSemanticsData().flagsCollection.isLiveRegion, isFalse);
    },
  );

  testWidgets('missing channel notice wins over resolved scope fallback', (
    tester,
  ) async {
    final session = GuideSession()
      ..sourceId = 'removed-source'
      ..category = const BrowseCategorySelection.sourceGroup(999)
      ..focusedChannelId = 'removed-channel';
    await tester.pumpWidget(
      _guideApp(data: _GuideFixtureData(), session: session),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Saved Guide channel is no longer available'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Saved Guide source and category'),
      findsNothing,
    );
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('guide-focus-context')),
    );
    expect(semantics.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
  });

  testWidgets(
    'Go to now refocuses a visible current program after far future',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_guideApp(data: _GuideFixtureData()));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guide-go-now')), findsOneWidget);

      final goNow = tester.widget<Focus>(
        find
            .descendant(
              of: find.byKey(const ValueKey('guide-go-now')),
              matching: find.byType(Focus),
            )
            .first,
      );
      goNow.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      final current = find.byKey(
        _guideProgramKey(
          'channel-1',
          DateTime.utc(2026, 8, 19, 10),
          DateTime.utc(2026, 8, 19, 11),
        ),
      );
      final currentFocus = tester.widget<Focus>(
        find.descendant(of: current, matching: find.byType(Focus)).first,
      );
      expect(currentFocus.focusNode?.hasFocus, isTrue);
      final currentRect = tester.getRect(current);
      final rulerRect = tester.getRect(
        find.byKey(const ValueKey('guide-time-ruler-scroll')),
      );
      expect(currentRect.left, greaterThanOrEqualTo(rulerRect.left));
      expect(currentRect.right, lessThanOrEqualTo(rulerRect.right));
    },
  );

  testWidgets(
    'conditional controls return focus before removal and reach rail',
    (tester) async {
      final focused = <String?>[];
      var railCount = 0;
      final data = _GuideFixtureData(
        availability: EpgAvailability.temporarilyUnavailable,
        availabilityAfterSecondRefresh: EpgAvailability.available,
      );
      await tester.pumpWidget(
        _guideApp(
          data: data,
          onContentFocus: (node) => focused.add(node.debugLabel),
          onOpenRail: () => railCount += 1,
        ),
      );
      await tester.pumpAndSettle();

      final sourceFocus = tester
          .widgetList<Focus>(
            find.descendant(
              of: find.byKey(const ValueKey('guide-source-selector')),
              matching: find.byType(Focus),
            ),
          )
          .map((focus) => focus.focusNode)
          .whereType<FocusNode>()
          .firstWhere((node) => node.debugLabel == 'guide source');
      sourceFocus.requestFocus();
      await tester.pump();
      expect(focused.last, 'guide source');
      final categoryFocus = tester
          .widgetList<Focus>(
            find.descendant(
              of: find.byKey(const ValueKey('guide-category-selector')),
              matching: find.byType(Focus),
            ),
          )
          .map((focus) => focus.focusNode)
          .whereType<FocusNode>()
          .firstWhere((node) => node.debugLabel == 'guide category');
      categoryFocus.requestFocus();
      await tester.pump();
      expect(focused.last, 'guide category');

      final retry = tester.widget<Focus>(
        find
            .descendant(
              of: find.byKey(const ValueKey('guide-retry')),
              matching: find.byType(Focus),
            )
            .first,
      );
      retry.focusNode!.requestFocus();
      await tester.pump();
      expect(focused.last, 'guide retry');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('guide-retry')), findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot('guide retry'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(railCount, 1);
    },
  );

  testWidgets('Go to now returns focus and Escape reaches Guide rail', (
    tester,
  ) async {
    final data = _GuideFixtureData();
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: WabbitShell(
          fixtureMode: HomeFixtureMode.populated,
          initialDestination: ShellDestination.guide,
          guideData: data,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('guide-time-ruler-scroll')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();

    final goNow = tester.widget<Focus>(
      find
          .descendant(
            of: find.byKey(const ValueKey('guide-go-now')),
            matching: find.byType(Focus),
          )
          .first,
    );
    goNow.focusNode!.requestFocus();
    await tester.pump();
    expect(goNow.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('guide-go-now')), findsNothing);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      isNot('guide go to now'),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Guide navigation');
  });

  testWidgets('Go to now rebase rejects delayed old-window focus', (
    tester,
  ) async {
    final oldRead = Completer<void>();
    final rebasedRead = Completer<void>();
    var readCalls = 0;
    var oldReadStarted = false;
    var rebasedReadStarted = false;
    var clock = _now;
    final start = DateTime.utc(2026, 8, 19, 10);
    final end = DateTime.utc(2026, 8, 19, 11);
    final session = GuideSession()
      ..focusedChannelId = 'channel-1'
      ..focusedProgramStartUtcMs = start.millisecondsSinceEpoch
      ..focusedProgramEndUtcMs = end.millisecondsSinceEpoch;
    final data = _GuideFixtureData(
      beforeEpgRead: (_) async {
        readCalls += 1;
        if (readCalls == 1) {
          oldReadStarted = true;
          await oldRead.future;
        } else if (readCalls == 2) {
          rebasedReadStarted = true;
          await rebasedRead.future;
        }
      },
    );
    await tester.pumpWidget(
      _guideApp(data: data, session: session, now: () => clock),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    expect(oldReadStarted, isTrue);

    clock = clock.add(const Duration(hours: 10));
    await tester.drag(
      find.byKey(const ValueKey('guide-time-ruler-scroll')),
      const Offset(-500, 0),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('guide-go-now')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('guide-go-now')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    expect(rebasedReadStarted, isTrue);

    final sourceFocus = tester
        .widgetList<Focus>(
          find.descendant(
            of: find.byKey(const ValueKey('guide-source-selector')),
            matching: find.byType(Focus),
          ),
        )
        .map((focus) => focus.focusNode)
        .whereType<FocusNode>()
        .firstWhere((node) => node.debugLabel == 'guide source');
    sourceFocus.requestFocus();
    await tester.pump();

    rebasedRead.complete();
    await tester.pumpAndSettle();

    expect(session.focusedProgramStartUtcMs, isNull);
    expect(session.focusedProgramEndUtcMs, isNull);
    expect(sourceFocus.hasFocus, isTrue);

    oldRead.complete();
    await tester.pumpAndSettle();
    expect(session.focusedProgramStartUtcMs, isNull);
    expect(session.focusedProgramEndUtcMs, isNull);
    expect(sourceFocus.hasFocus, isTrue);
  });

  testWidgets(
    'time window restores exactly then rebases after bounded expiry',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var clock = _now;
      final session = GuideSession();
      final data = _GuideFixtureData();
      await tester.pumpWidget(
        _guideApp(data: data, session: session, now: () => clock),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('guide-time-ruler-scroll')),
        const Offset(-50, 0),
      );
      await tester.pumpAndSettle();
      final retainedStart = session.windowStartUtc;
      final retainedOffset = session.horizontalOffset;

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      clock = clock.add(const Duration(hours: 1));
      await tester.pumpWidget(
        _guideApp(data: data, session: session, now: () => clock),
      );
      await tester.pumpAndSettle();
      final restoredRuler = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey('guide-time-ruler-scroll')),
      );
      expect(data.loadedWindowStarts.last, retainedStart);
      expect(restoredRuler.controller!.offset, closeTo(retainedOffset, 0.1));

      clock = clock.add(const Duration(hours: 9));
      await tester.drag(
        find.byKey(const ValueKey('guide-time-ruler-scroll')),
        const Offset(-20, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('guide-go-now')));
      await tester.pumpAndSettle();
      final expectedStart = DateTime.utc(
        clock.year,
        clock.month,
        clock.day,
        clock.hour,
      ).subtract(const Duration(minutes: 30));
      expect(session.windowStartUtc, expectedStart);
      expect(data.loadedWindowStarts.last, expectedStart);
    },
  );

  testWidgets('fall-back labels disambiguate repeated hour and local date', (
    tester,
  ) async {
    final repeatedStart = DateTime.utc(2026, 11, 1, 6, 30);
    final repeatedEnd = DateTime.utc(2026, 11, 1, 7, 30);
    await tester.pumpWidget(
      _guideApp(
        now: () => DateTime.utc(2026, 11, 1, 0, 15),
        localize: _centralUsLocalize,
        data: _GuideFixtureData(
          programs: [
            EpgProgram(
              catalogItemId: 'channel-1',
              startUtc: DateTime.utc(2026, 11, 1, 4, 30),
              endUtc: DateTime.utc(2026, 11, 1, 5, 30),
              title: 'Midnight Crossing',
            ),
            EpgProgram(
              catalogItemId: 'channel-1',
              startUtc: repeatedStart,
              endUtc: repeatedEnd,
              title: 'Repeated Hour',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('1:30 AM CDT–1:30 AM CST'), findsWidgets);
    final localizations = MaterialLocalizations.of(
      tester.element(find.byType(GuideScreen)),
    );
    expect(
      find.textContaining(
        localizations.formatShortDate(DateTime.utc(2026, 10, 31, 23, 30)),
      ),
      findsWidgets,
    );
    expect(
      find.textContaining(
        localizations.formatShortDate(DateTime.utc(2026, 11, 1, 0, 30)),
      ),
      findsWidgets,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Repeated Hour · 1:30 AM CDT UTC−05:00'),
      findsOneWidget,
    );
  });

  testWidgets('spring-forward labels show the skipped local hour truthfully', (
    tester,
  ) async {
    final start = DateTime.utc(2026, 3, 8, 7, 30);
    final end = DateTime.utc(2026, 3, 8, 8, 30);
    await tester.pumpWidget(
      _guideApp(
        now: () => DateTime.utc(2026, 3, 8, 7, 15),
        localize: _centralUsLocalize,
        data: _GuideFixtureData(
          programs: [
            EpgProgram(
              catalogItemId: 'channel-1',
              startUtc: start,
              endUtc: end,
              title: 'Spring Transition',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('1:30 AM CST–3:30 AM CDT'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'Spring Transition · 1:30 AM CST UTC−06:00–3:30 AM CDT UTC−05:00',
      ),
      findsOneWidget,
    );
  });

  testWidgets('DST ruler compacts long Windows zone names without overlap', (
    tester,
  ) async {
    await tester.pumpWidget(
      _guideApp(
        now: () => DateTime.utc(2026, 11, 1, 0, 15),
        localize: _centralUsWindowsLocalize,
        data: _GuideFixtureData(
          programs: [
            EpgProgram(
              catalogItemId: 'channel-1',
              startUtc: DateTime.utc(2026, 11, 1, 4, 30),
              endUtc: DateTime.utc(2026, 11, 1, 5, 30),
              title: 'Midnight Crossing',
            ),
            EpgProgram(
              catalogItemId: 'channel-1',
              startUtc: DateTime.utc(2026, 11, 1, 6, 30),
              endUtc: DateTime.utc(2026, 11, 1, 7, 30),
              title: 'Repeated Hour',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final ruler = find.byKey(const ValueKey('guide-time-ruler-scroll'));
    final rulerText = tester
        .widgetList<Text>(
          find.descendant(of: ruler, matching: find.byType(Text)),
        )
        .map((text) => text.data ?? '')
        .join(' ');
    expect(rulerText, isNot(contains('Central Daylight Time')));
    expect(rulerText, isNot(contains('Central Standard Time')));
    expect(rulerText, contains('CDT'));
    expect(rulerText, contains('CST'));
    for (var index = 0; index < 8; index++) {
      final current = tester.getRect(
        find.byKey(ValueKey('guide-ruler-label-$index')),
      );
      final next = tester.getRect(
        find.byKey(ValueKey('guide-ruler-label-${index + 1}')),
      );
      expect(current.right, lessThanOrEqualTo(next.left));
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'Repeated Hour · 1:30 AM Central Daylight Time UTC−05:00',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'Corner Signal remains active over the seventh Guide destination',
    (tester) async {
      final manager = PlaybackManager(
        targetResolver: const _GuideResolver(),
        admissionPort: const _GuideAdmission(),
        transportFactory: _GuideTransport.new,
      );
      addTearDown(manager.dispose);
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: WabbitShell(
            fixtureMode: HomeFixtureMode.populated,
            initialDestination: ShellDestination.guide,
            guideData: _GuideFixtureData(),
            playbackManager: manager,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('guide-channel-channel-1')));
      await tester.pumpAndSettle();
      tester.widget<PlayerScreen>(find.byType(PlayerScreen)).onEnterPip!();
      await tester.pumpAndSettle();

      expect(find.byType(GuideScreen), findsOneWidget);
      expect(find.byType(PipOverlay), findsOneWidget);
      await _activateShellDestination(tester, ShellDestination.movies);
      expect(find.byType(PipOverlay), findsOneWidget);
      await _activateShellDestination(tester, ShellDestination.guide);
      expect(find.byType(GuideScreen), findsOneWidget);
      expect(find.byType(PipOverlay), findsOneWidget);
    },
  );
}

Future<void> _activateShellDestination(
  WidgetTester tester,
  ShellDestination destination,
) async {
  final detector = tester.widget<FocusableActionDetector>(
    find.byKey(ValueKey('shell-destination-${destination.name}')),
  );
  detector.focusNode!.requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

final _now = DateTime.utc(2026, 8, 19, 10, 15);

GuideLocalInstant _centralUsLocalize(DateTime utc) {
  final instant = utc.toUtc();
  final daylightStart = DateTime.utc(2026, 3, 8, 8);
  final daylightEnd = DateTime.utc(2026, 11, 1, 7);
  final daylight =
      !instant.isBefore(daylightStart) && instant.isBefore(daylightEnd);
  final offset = Duration(hours: daylight ? -5 : -6);
  return GuideLocalInstant(
    wallTime: instant.add(offset),
    utcOffset: offset,
    zoneName: daylight ? 'CDT' : 'CST',
  );
}

GuideLocalInstant _centralUsWindowsLocalize(DateTime utc) {
  final localized = _centralUsLocalize(utc);
  return GuideLocalInstant(
    wallTime: localized.wallTime,
    utcOffset: localized.utcOffset,
    zoneName: localized.zoneName == 'CDT'
        ? 'Central Daylight Time'
        : 'Central Standard Time',
  );
}

Widget _guideApp({
  required _GuideFixtureData data,
  ValueChanged<PlaybackHandoff>? onPlayback,
  ValueChanged<FocusNode>? onContentFocus,
  VoidCallback? onOpenRail,
  VoidCallback? onBrowseLive,
  VoidCallback? onSettings,
  TextScaler textScaler = TextScaler.noScaling,
  DateTime Function()? now,
  GuideLocalInstant Function(DateTime utc)? localize,
  GuideSession? session,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: textScaler),
    child: child!,
  ),
  home: Scaffold(
    body: GuideScreen(
      initialFocus: FocusNode(debugLabel: 'guide initial'),
      onContentFocus: onContentFocus ?? (_) {},
      onOpenRail: onOpenRail ?? () {},
      session: session ?? GuideSession(),
      onPlaybackHandoff: onPlayback ?? (_) {},
      data: data,
      onBrowseLive: onBrowseLive ?? () {},
      onOpenSettings: onSettings ?? () {},
      now: now ?? () => _now,
      localize: localize,
    ),
  ),
);

ValueKey<String> _guideProgramKey(
  String channelId,
  DateTime startUtc,
  DateTime endUtc,
) => ValueKey(
  'guide-program-$channelId-${startUtc.millisecondsSinceEpoch}-${endUtc.millisecondsSinceEpoch}',
);

ValueKey<String> _guideProgramVisualKey(
  String channelId,
  DateTime startUtc,
  DateTime endUtc,
) => ValueKey(
  'guide-program-visual-$channelId-${startUtc.millisecondsSinceEpoch}-${endUtc.millisecondsSinceEpoch}',
);

class _GuideFixtureData
    implements GuideDataPort, GuideRestorationDataPort, BasicBrowseData {
  _GuideFixtureData({
    List<SourceRosterEntry>? sources,
    List<BrowseCatalogItem>? channels,
    this.removedChannelIds = const {},
    this.failingChannelSourceIds = const {},
    this.failingCategoryGroupIds = const {},
    this.failingForwardPageCursorIds = const {},
    this.failingPreviousPageCursorIds = const {},
    this.previousPageGate,
    this.availability = EpgAvailability.available,
    this.refreshSummary = const EpgRefreshSummary.none(),
    List<EpgProgram>? programs,
    this.epgReadDelay = Duration.zero,
    this.availabilityAfterSecondRefresh,
    this.beforeEpgRead,
    this.beforeCancel,
    this.refreshSummaryForCall,
    this.categorySummaries,
    this.returnAllChannelsInFirstPage = false,
  }) : sources = sources ?? const [_source],
       channels = channels ?? _fixtureChannels,
       programs = programs ?? _fixturePrograms('channel-1');

  final List<SourceRosterEntry> sources;
  final List<BrowseCatalogItem> channels;
  final Set<String> removedChannelIds;
  final Set<String> failingChannelSourceIds;
  final Set<int> failingCategoryGroupIds;
  final Set<String> failingForwardPageCursorIds;
  final Set<String> failingPreviousPageCursorIds;
  final Completer<void>? previousPageGate;
  EpgAvailability availability;
  final EpgRefreshSummary refreshSummary;
  final List<EpgProgram> programs;
  final Duration epgReadDelay;
  final EpgAvailability? availabilityAfterSecondRefresh;
  final Future<void> Function(List<String> ids)? beforeEpgRead;
  final Future<void> Function(int call)? beforeCancel;
  final EpgRefreshSummary Function(int call)? refreshSummaryForCall;
  final List<BrowseCategorySummary>? categorySummaries;
  final bool returnAllChannelsInFirstPage;
  final List<String> loadedWindowIds = [];
  final List<List<String>> loadedWindowRequests = [];
  final List<String> refreshedIds = [];
  final List<List<String>> refreshRequests = [];
  final List<bool> refreshManualRetries = [];
  final List<String> previousPageCursorIds = [];
  final List<String?> forwardPageCursorIds = [];
  int refreshCalls = 0;
  int emptyRefreshSignals = 0;
  int cancelCalls = 0;
  BrowseCategorySelection? lastSelection;
  final List<DateTime> loadedWindowStarts = [];

  @override
  Future<List<SourceRosterEntry>> loadXtreamSources() async => sources;

  @override
  Future<List<BrowseCategorySummary>> loadCategories(String sourceId) async =>
      browseCategories(sourceId: sourceId, kind: SourceMediaKind.live);

  @override
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  }) async {
    final visible = channels
        .where(
          (channel) =>
              channel.sourceId == sourceId &&
              !removedChannelIds.contains(channel.id),
        )
        .length;
    return categorySummaries ??
        [
          BrowseCategorySummary(
            selection: const BrowseCategorySelection.all(),
            name: 'All Live',
            itemCount: visible,
          ),
          BrowseCategorySummary(
            selection: const BrowseCategorySelection.sourceGroup(7),
            name: 'News',
            itemCount: visible == 0 ? 0 : 1,
          ),
        ];
  }

  @override
  Future<BrowsePage> loadChannels({
    required String sourceId,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit = guideChannelPageSize,
  }) => browsePage(
    sourceId: sourceId,
    kind: SourceMediaKind.live,
    selection: selection,
    cursor: cursor,
    limit: limit,
  );

  @override
  Future<BrowsePage> browsePage({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit = 100,
  }) async {
    if (failingChannelSourceIds.contains(sourceId)) {
      throw StateError('Fixture channel load failed.');
    }
    final groupId = selection.sourceGroupId;
    if (groupId != null && failingCategoryGroupIds.contains(groupId)) {
      throw StateError('Fixture category load failed.');
    }
    forwardPageCursorIds.add(cursor?.id);
    if (cursor != null && failingForwardPageCursorIds.contains(cursor.id)) {
      throw StateError('Fixture forward page load failed.');
    }
    lastSelection = selection;
    final all = channels
        .where(
          (channel) =>
              channel.sourceId == sourceId &&
              !removedChannelIds.contains(channel.id),
        )
        .toList(growable: false);
    final scoped = switch (selection) {
      BrowseCategorySelection(kind: BrowseCategorySelectionKind.all) => all,
      BrowseCategorySelection(sourceGroupId: 8) =>
        all.skip(1).take(1).toList(growable: false),
      _ => all.take(1).toList(growable: false),
    };
    if (returnAllChannelsInFirstPage && cursor == null) {
      return BrowsePage(items: scoped, nextCursor: null);
    }
    final start = cursor == null
        ? 0
        : scoped.indexWhere((channel) => channel.id == cursor.id) + 1;
    final end = (start + limit).clamp(0, scoped.length);
    final items = start < 0 || start >= scoped.length
        ? const <BrowseCatalogItem>[]
        : scoped.sublist(start, end);
    return BrowsePage(
      items: items,
      nextCursor: end < scoped.length && items.isNotEmpty
          ? BrowseCursor(normalizedTitle: items.last.title, id: items.last.id)
          : null,
    );
  }

  @override
  Future<CatalogBrowseWindow?> loadChannelWindow({
    required String sourceId,
    required BrowseCategorySelection selection,
    required String catalogItemId,
    int limit = guideChannelPageSize,
  }) async {
    final scoped = channels
        .where(
          (channel) =>
              channel.sourceId == sourceId &&
              !removedChannelIds.contains(channel.id) &&
              (selection.kind == BrowseCategorySelectionKind.all ||
                  channel == channels.firstOrNull),
        )
        .toList(growable: false);
    final anchor = scoped.indexWhere((channel) => channel.id == catalogItemId);
    if (anchor < 0) return null;
    final before = limit ~/ 2;
    final start = (anchor - before).clamp(0, scoped.length);
    final end = (start + limit).clamp(0, scoped.length);
    final items = scoped.sublist(start, end);
    return CatalogBrowseWindow(
      items: items,
      previousCursor: start > 0
          ? BrowseCursor(normalizedTitle: items.first.title, id: items.first.id)
          : null,
      nextCursor: end < scoped.length
          ? BrowseCursor(normalizedTitle: items.last.title, id: items.last.id)
          : null,
    );
  }

  @override
  Future<CatalogBrowseWindow> loadPreviousChannels({
    required String sourceId,
    required BrowseCategorySelection selection,
    required BrowseCursor cursor,
    int limit = guideChannelPageSize,
  }) async {
    previousPageCursorIds.add(cursor.id);
    if (failingPreviousPageCursorIds.contains(cursor.id)) {
      throw StateError('Fixture previous page load failed.');
    }
    final gate = previousPageGate;
    if (gate != null) await gate.future;
    final scoped = channels
        .where(
          (channel) =>
              channel.sourceId == sourceId &&
              !removedChannelIds.contains(channel.id) &&
              (selection.kind == BrowseCategorySelectionKind.all ||
                  channel == channels.firstOrNull),
        )
        .toList(growable: false);
    final boundary = scoped.indexWhere((channel) => channel.id == cursor.id);
    if (boundary <= 0) {
      return const CatalogBrowseWindow(
        items: [],
        previousCursor: null,
        nextCursor: null,
      );
    }
    final start = (boundary - limit).clamp(0, boundary);
    final items = scoped.sublist(start, boundary);
    return CatalogBrowseWindow(
      items: items,
      previousCursor: start > 0
          ? BrowseCursor(normalizedTitle: items.first.title, id: items.first.id)
          : null,
      nextCursor: null,
    );
  }

  @override
  Future<List<EpgChannelWindow>> loadEpgWindow({
    required List<String> catalogItemIds,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    required DateTime atUtc,
  }) async {
    final ids = List<String>.unmodifiable(catalogItemIds);
    loadedWindowRequests.add(ids);
    final readGate = beforeEpgRead;
    if (readGate != null) await readGate(ids);
    if (epgReadDelay > Duration.zero) await Future<void>.delayed(epgReadDelay);
    loadedWindowIds
      ..clear()
      ..addAll(ids);
    loadedWindowStarts.add(windowStartUtc);
    return [
      for (final id in ids)
        EpgChannelWindow(
          catalogItemId: id,
          availability: availability,
          programs: [
            for (final program in programs)
              EpgProgram(
                catalogItemId: id,
                startUtc: program.startUtc,
                endUtc: program.endUtc,
                title: id == 'channel-2' && program.title == 'Morning News'
                    ? 'Local Weather'
                    : program.title,
              ),
          ],
          nowNext: EpgNowNext(
            current: programs.isEmpty
                ? null
                : EpgProgram(
                    catalogItemId: id,
                    startUtc: programs.first.startUtc,
                    endUtc: programs.first.endUtc,
                    title: id == 'channel-2' ? 'Local Weather' : 'Morning News',
                  ),
            next: programs.length < 2
                ? null
                : EpgProgram(
                    catalogItemId: id,
                    startUtc: programs[1].startUtc,
                    endUtc: programs[1].endUtc,
                    title: 'Late Morning',
                  ),
          ),
        ),
    ];
  }

  @override
  Future<EpgRefreshSummary> refreshCatalogItems(
    Iterable<String> catalogItemIds, {
    bool manualRetry = false,
  }) async {
    final ids = catalogItemIds.toList(growable: false);
    if (ids.isEmpty) {
      emptyRefreshSignals += 1;
      return const EpgRefreshSummary.none();
    }
    refreshCalls += 1;
    refreshRequests.add(List.unmodifiable(ids));
    refreshManualRetries.add(manualRetry);
    if (refreshCalls >= 2 && availabilityAfterSecondRefresh != null) {
      availability = availabilityAfterSecondRefresh!;
    }
    refreshedIds
      ..clear()
      ..addAll(ids);
    return refreshSummaryForCall?.call(refreshCalls) ?? refreshSummary;
  }

  @override
  Future<void> cancelActiveEpgRefresh() async {
    cancelCalls += 1;
    final gate = beforeCancel;
    if (gate != null) await gate(cancelCalls);
  }
}

const _source = SourceRosterEntry(
  id: 'source-1',
  name: 'Fixture Xtream',
  kind: 'xtream',
  enabled: true,
  status: 'ready',
  counts: {
    SourceMediaKind.live: 2,
    SourceMediaKind.movies: 0,
    SourceMediaKind.series: 0,
  },
);

const _sourceB = SourceRosterEntry(
  id: 'source-2',
  name: 'Backup Xtream',
  kind: 'xtream',
  enabled: true,
  status: 'ready',
  counts: {
    SourceMediaKind.live: 1,
    SourceMediaKind.movies: 0,
    SourceMediaKind.series: 0,
  },
);

const _fixtureChannels = [
  BrowseCatalogItem(
    id: 'channel-1',
    sourceId: 'source-1',
    kind: SourceMediaKind.live,
    title: 'Channel One',
    artworkLocator: null,
    playbackRef: '{"providerId":"101","kind":"live"}',
  ),
  BrowseCatalogItem(
    id: 'channel-2',
    sourceId: 'source-1',
    kind: SourceMediaKind.live,
    title: 'Channel Two',
    artworkLocator: null,
    playbackRef: '{"providerId":"202","kind":"live"}',
  ),
];

const _fixtureSourceBChannel = BrowseCatalogItem(
  id: 'channel-backup',
  sourceId: 'source-2',
  kind: SourceMediaKind.live,
  title: 'Backup News',
  artworkLocator: null,
  playbackRef: '{"providerId":"303","kind":"live"}',
);

List<BrowseCatalogItem> _manyChannels(int count) => [
  for (var index = 1; index <= count; index++)
    BrowseCatalogItem(
      id: 'channel-${index.toString().padLeft(3, '0')}',
      sourceId: 'source-1',
      kind: SourceMediaKind.live,
      title: 'Channel ${index.toString().padLeft(3, '0')}',
      artworkLocator: null,
      playbackRef: '{"providerId":"$index","kind":"live"}',
    ),
];

List<EpgProgram> _fixturePrograms(String id) => [
  EpgProgram(
    catalogItemId: id,
    startUtc: DateTime.utc(2026, 8, 19, 10),
    endUtc: DateTime.utc(2026, 8, 19, 11),
    title: 'Morning News',
  ),
  EpgProgram(
    catalogItemId: id,
    startUtc: DateTime.utc(2026, 8, 19, 11),
    endUtc: DateTime.utc(2026, 8, 19, 12),
    title: 'Late Morning',
  ),
  EpgProgram(
    catalogItemId: id,
    startUtc: DateTime.utc(2026, 8, 19, 16),
    endUtc: DateTime.utc(2026, 8, 19, 17),
    title: 'Evening Report',
  ),
];

class _GuideResolver implements PlaybackTargetResolverPort {
  const _GuideResolver();

  @override
  Future<PlaybackResolvedTarget> resolve(PlaybackHandoff handoff) async =>
      PlaybackResolvedTarget(uri: Uri.parse('https://stream.invalid/live'));
}

class _GuideAdmission implements PlaybackAdmissionPort {
  const _GuideAdmission();

  @override
  Future<int> effectiveLimitForSource(String sourceId) async => 1;
}

class _GuideTransport implements PlaybackTransport {
  final _states = StreamController<PlaybackTransportState>.broadcast(
    sync: true,
  );

  @override
  Stream<PlaybackTransportState> get states => _states.stream;

  @override
  Widget buildVideo() => const SizedBox(key: ValueKey('guide-video'));

  @override
  Future<void> open(
    Uri uri, {
    Map<String, String> httpHeaders = const {},
  }) async {
    _states.add(
      const PlaybackTransportState(
        hasVideo: true,
        isPlaying: true,
        duration: Duration(hours: 1),
      ),
    );
  }

  @override
  Future<void> dispose() async => _states.close();
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
