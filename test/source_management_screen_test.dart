import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/app_shell.dart';
import 'package:wabbit_tv/src/features/sources/source_management_screen.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/home_fixture_mode.dart';

void main() {
  SourceRosterEntry entry(
    String id,
    String name, {
    bool enabled = true,
    String? status,
  }) => SourceRosterEntry(
    id: id,
    name: name,
    kind: 'Xtream',
    enabled: enabled,
    status:
        status ??
        (enabled ? 'Last refresh complete' : 'Excluded from active results'),
    counts: const {
      SourceMediaKind.live: 56712,
      SourceMediaKind.movies: 176792,
      SourceMediaKind.series: 47253,
    },
  );
  Widget app(SourceManagementController c, {VoidCallback? add}) => MaterialApp(
    home: Scaffold(
      body: SourceManagementScreen(
        initialFocus: FocusNode(),
        onContentFocus: (_) {},
        onOpenRail: () {},
        onAddSource: add ?? () {},
        controller: c,
      ),
    ),
  );
  testWidgets(
    'directory detail ledger keeps actions and large counts visible',
    (tester) async {
      final c = SourceManagementController(
        entries: [
          entry(
            'one',
            'A very long local source name that should truncate cleanly',
          ),
          entry('two', 'Weekend playlist', enabled: false),
        ],
      );
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(c));
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      expect(find.text('Add source'), findsOneWidget);
      expect(find.text('Movies'), findsOneWidget);
      expect(find.text('56,712'), findsOneWidget);
      expect(find.text('176,792'), findsOneWidget);
      expect(find.text('47,253'), findsOneWidget);
      final addShape =
          tester
                  .widget<OutlinedButton>(
                    find.widgetWithText(OutlinedButton, 'Add source'),
                  )
                  .style!
                  .shape!
                  .resolve({})!
              as RoundedRectangleBorder;
      final refreshShape =
          tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Refresh'),
                  )
                  .style!
                  .shape!
                  .resolve({})!
              as RoundedRectangleBorder;
      expect(addShape.borderRadius, BorderRadius.circular(6));
      expect(refreshShape.borderRadius, BorderRadius.circular(6));
      expect(
        find.text('Xtream · Ready · L 56.7K · M 177K · S 47.3K'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('source-row-two')));
      await tester.pump();
      expect(
        find.text('Disabled — excluded from active results'),
        findsOneWidget,
      );
      expect(find.text('Enable'), findsOneWidget);
      final selected = tester.widget<Container>(
        find.byKey(const ValueKey('source-row-two')),
      );
      expect(
        (selected.decoration! as BoxDecoration).color,
        const Color(0xFF222321),
      );
    },
  );

  testWidgets('Enter and remote Select activate the focused directory row', (
    tester,
  ) async {
    final c = SourceManagementController(
      entries: [entry('one', 'One'), entry('two', 'Two')],
    );
    await tester.pumpWidget(app(c));
    final second = tester
        .widget<FocusableActionDetector>(
          find.ancestor(
            of: find.byKey(const ValueKey('source-row-two')),
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .focusNode!;
    second.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(c.selectedId, 'two');

    final first = tester
        .widget<FocusableActionDetector>(
          find.ancestor(
            of: find.byKey(const ValueKey('source-row-one')),
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .focusNode!;
    first.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(c.selectedId, 'one');
  });

  testWidgets(
    'durable failed status is mapped for a disabled reloaded source',
    (tester) async {
      final failed = entry(
        'one',
        'Home provider',
        enabled: false,
        status: 'refresh_failed',
      );
      final c = SourceManagementController(
        entries: [entry('one', 'Home provider')],
        port: _RosterPort([failed]),
      );

      await tester.pumpWidget(app(c));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Xtream · Disabled · Refresh failed · L 56.7K · M 177K · S 47.3K',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Refresh failed. Previous local catalog retained.'),
        findsOneWidget,
      );
      expect(find.text('refresh_failed'), findsNothing);
      final semantics = tester.widget<Semantics>(
        find.byKey(const ValueKey('source-status-one')),
      );
      expect(semantics.properties.liveRegion, isTrue);
    },
  );

  testWidgets('Rename saves only the local name and restores action focus', (
    tester,
  ) async {
    final port = _RosterPort([entry('one', 'Home provider')]);
    final c = SourceManagementController(
      entries: [entry('one', 'Home provider')],
      port: port,
    );
    await tester.pumpWidget(app(c));
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const ValueKey('source-rename-field')),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const ValueKey('source-rename-field')),
      'Living room',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(port.renameCalls, [('one', 'Living room')]);
    expect(port.refreshCalls, isEmpty);
    expect(find.text('Living room'), findsWidgets);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'source management rename',
    );
  });

  testWidgets(
    'Rename Escape cancels and restores focus without changing data',
    (tester) async {
      final port = _RosterPort([entry('one', 'Home provider')]);
      final c = SourceManagementController(
        entries: [entry('one', 'Home provider')],
        port: port,
      );
      await tester.pumpWidget(app(c));
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(port.renameCalls, isEmpty);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'source management rename',
      );
    },
  );
  testWidgets('empty state promotes Add source', (tester) async {
    var added = false;
    await tester.pumpWidget(
      app(SourceManagementController(entries: []), add: () => added = true),
    );
    expect(find.text('No sources yet'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Add source'));
    expect(added, isTrue);
  });
  testWidgets('remove asks for confirmation with Cancel initially focused', (
    tester,
  ) async {
    final c = SourceManagementController(
      entries: [entry('one', 'Home provider')],
    );
    await tester.pumpWidget(app(c));
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Home provider'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Home provider'), findsWidgets);
  });
  testWidgets('narrow layout keeps the directory above details', (
    tester,
  ) async {
    final c = SourceManagementController(
      entries: [entry('one', 'Home provider')],
    );
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(c));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('source-row-one'))).dy,
      lessThan(tester.getTopLeft(find.text('Refresh')).dy),
    );
  });
  testWidgets('narrow high-text-scale rows keep metadata readable', (
    tester,
  ) async {
    final c = SourceManagementController(
      entries: [entry('one', 'A long living room source name')],
    );
    await tester.binding.setSurfaceSize(const Size(520, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SourceManagementScreen(
            initialFocus: FocusNode(),
            onContentFocus: (_) {},
            onOpenRail: () {},
            onAddSource: () {},
            controller: c,
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final rowSize = tester.getSize(
      find.byKey(const ValueKey('source-row-one')),
    );
    expect(rowSize.height, greaterThan(140));
    expect(find.textContaining('L 56.7K'), findsOneWidget);
  });
  testWidgets('Escape returns detail focus to row, then opens rail', (
    tester,
  ) async {
    var rail = 0;
    final c = SourceManagementController(
      entries: [entry('one', 'Home provider')],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceManagementScreen(
            initialFocus: FocusNode(debugLabel: 'management initial'),
            onContentFocus: (_) {},
            onOpenRail: () => rail++,
            onAddSource: () {},
            controller: c,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'management initial',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(rail, 1);
  });
  testWidgets(
    'remove Cancel receives actual focus and restoration preserves rows',
    (tester) async {
      final c = SourceManagementController(
        entries: [entry('one', 'One'), entry('two', 'Two')],
        port: _RosterPort([entry('one', 'One'), entry('two', 'Two')]),
      );
      await tester.pumpWidget(app(c));
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Cancel'),
            )
            .focusNode!
            .hasFocus,
        isTrue,
      );
      await tester.tap(find.text('Remove source'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('source-row-two')), findsOneWidget);
    },
  );
  testWidgets('directory arrow traversal is bounded', (tester) async {
    final c = SourceManagementController(
      entries: [for (var i = 0; i < 12; i++) entry('$i', 'Source $i')],
    );
    await tester.binding.setSurfaceSize(const Size(900, 350));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(c));
    final first = tester
        .widget<FocusableActionDetector>(
          find.ancestor(
            of: find.byKey(const ValueKey('source-row-0')),
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .focusNode!;
    first.requestFocus();
    for (var i = 0; i < 11; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'source row 11');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'source row 11');
  });

  testWidgets('shell-requested return restores the selected directory row', (
    tester,
  ) async {
    final c = SourceManagementController(
      entries: [entry('one', 'One'), entry('two', 'Two')],
    )..select('two');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceManagementScreen(
            initialFocus: FocusNode(debugLabel: 'management first row'),
            onContentFocus: (_) {},
            onOpenRail: () {},
            onAddSource: () {},
            controller: c,
            restoreSelectedFocusOnEntry: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'source row two');
  });

  testWidgets('action failures retain the row, recovery, and action focus', (
    tester,
  ) async {
    final c = SourceManagementController(
      entries: [entry('one', 'Home provider')],
      port: _FailingPort(),
    );
    await tester.pumpWidget(app(c));

    await tester.tap(find.text('Disable'));
    await tester.pump();
    expect(
      find.text(
        'That source could not be updated. Your local catalog is unchanged.',
      ),
      findsOneWidget,
    );
    expect(c.entries, hasLength(1));
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'source management toggle',
    );

    await tester.tap(find.text('Edit'));
    await tester.pump();
    expect(c.entries, hasLength(1));
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'source management edit',
    );

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove source'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(c.entries, hasLength(1));
    expect(
      find.text(
        'That source could not be removed. Your local catalog is unchanged.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('loading and load failure expose a retry path', (tester) async {
    final c = SourceManagementController(
      entries: [entry('one', 'One')],
      port: _RosterPort([entry('one', 'One')]),
    );
    c.state = SourceManagementLoadState.loading;
    await tester.pumpWidget(app(c));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading sources…'), findsOneWidget);
    c.state = SourceManagementLoadState.failed;
    c.notifyListeners();
    await tester.pump();
    expect(find.text('Sources could not be loaded'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.text('Refresh'), findsOneWidget);
  });

  testWidgets('a reload failure retains a populated source directory', (
    tester,
  ) async {
    final c = SourceManagementController(
      entries: [entry('one', 'Last good source')],
      port: _LoadFailingPort(),
    );
    await tester.pumpWidget(app(c));
    await tester.pump();

    expect(c.state, SourceManagementLoadState.ready);
    expect(find.text('Last good source'), findsWidgets);
    expect(find.text('Sources could not be loaded'), findsNothing);
    expect(
      find.text(
        'Sources could not be updated. Showing your last local catalog.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('remove success focuses next row or Add source when empty', (
    tester,
  ) async {
    final two = SourceManagementController(
      entries: [entry('one', 'One'), entry('two', 'Two')],
      port: _RosterPort([entry('one', 'One'), entry('two', 'Two')]),
    );
    await tester.pumpWidget(app(two));
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove source'));
    await tester.pumpAndSettle();
    await tester.pump();
    final survivingRow = tester
        .widget<FocusableActionDetector>(
          find.ancestor(
            of: find.byKey(const ValueKey('source-row-two')),
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .focusNode!;
    expect(survivingRow.hasFocus, isTrue);

    final one = SourceManagementController(
      entries: [entry('one', 'One')],
      port: _RosterPort([entry('one', 'One')]),
    );
    await tester.pumpWidget(app(one));
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove source'));
    await tester.pumpAndSettle();
    final emptyAdd = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Add source'),
    );
    expect(emptyAdd.focusNode?.hasFocus, isTrue);
  });

  testWidgets(
    'delayed removal restores focus to the next non-first surviving row',
    (tester) async {
      final gate = Completer<void>();
      final port = _RosterPort([
        entry('one', 'One'),
        entry('two', 'Two'),
        entry('three', 'Three'),
      ])..removeGate = gate;
      final c = SourceManagementController(
        entries: [
          entry('one', 'One'),
          entry('two', 'Two'),
          entry('three', 'Three'),
        ],
        port: port,
      )..select('two');
      await tester.pumpWidget(app(c));

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove source'));
      await tester.pump();
      expect(c.entries.map((entry) => entry.id), ['one', 'two', 'three']);

      gate.complete();
      await tester.pumpAndSettle();
      expect(c.selectedId, 'three');
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'source row three',
      );
    },
  );

  testWidgets('row and detail focus are reported to the shell', (tester) async {
    final reported = <String?>[];
    final c = SourceManagementController(entries: [entry('one', 'One')]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceManagementScreen(
            initialFocus: FocusNode(debugLabel: 'management initial'),
            onContentFocus: (node) => reported.add(node.debugLabel),
            onOpenRail: () {},
            onAddSource: () {},
            controller: c,
          ),
        ),
      ),
    );
    tester
        .widget<FocusableActionDetector>(
          find.ancestor(
            of: find.byKey(const ValueKey('source-row-one')),
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .focusNode!
        .requestFocus();
    await tester.pump();
    await tester.tap(find.text('Refresh'));
    await tester.pump();
    expect(
      reported,
      containsAll(['management initial', 'source management refresh']),
    );
  });

  testWidgets(
    'Settings Add source Ledger Escape restores focused Sources management',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WabbitShell(
            fixtureMode: HomeFixtureMode.noPersonalization,
            initialDestination: ShellDestination.settings,
            sourceManagementController: SourceManagementController(
              entries: [entry('one', 'One')],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Add source'));
      await tester.pumpAndSettle();
      expect(find.text('Source details'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Sources'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'home first item');
    },
  );
}

class _FailingPort implements SourceManagementPort {
  @override
  Future<List<SourceRosterEntry>> loadRoster() async => [
    SourceRosterEntry(
      id: 'one',
      name: 'Home provider',
      kind: 'Xtream',
      enabled: true,
      status: 'Last refresh complete',
      counts: const {
        SourceMediaKind.live: 56712,
        SourceMediaKind.movies: 176792,
        SourceMediaKind.series: 47253,
      },
    ),
  ];

  @override
  Future<void> editAndRefresh(String sourceId) =>
      Future.error(StateError('provider secret'));
  @override
  Future<void> refresh(String sourceId) =>
      Future.error(StateError('provider secret'));
  @override
  Future<void> rename(String sourceId, String name) =>
      Future.error(StateError('provider secret'));
  @override
  Future<void> remove(String sourceId) =>
      Future.error(StateError('provider secret'));
  @override
  Future<void> setEnabled(String sourceId, bool enabled) =>
      Future.error(StateError('provider secret'));
}

class _LoadFailingPort implements SourceManagementPort {
  @override
  Future<List<SourceRosterEntry>> loadRoster() =>
      Future.error(StateError('local read failure'));

  @override
  Future<void> editAndRefresh(String sourceId) async {}

  @override
  Future<void> refresh(String sourceId) async {}

  @override
  Future<void> remove(String sourceId) async {}

  @override
  Future<void> rename(String sourceId, String name) async {}

  @override
  Future<void> setEnabled(String sourceId, bool enabled) async {}
}

class _RosterPort implements SourceManagementPort {
  _RosterPort(List<SourceRosterEntry> seed) : entries = List.of(seed);
  final List<SourceRosterEntry> entries;
  final List<(String, String)> renameCalls = [];
  final List<String> refreshCalls = [];
  Completer<void>? removeGate;

  @override
  Future<List<SourceRosterEntry>> loadRoster() async => List.of(entries);

  @override
  Future<void> editAndRefresh(String sourceId) async {}

  @override
  Future<void> refresh(String sourceId) async {
    refreshCalls.add(sourceId);
  }

  @override
  Future<void> rename(String sourceId, String name) async {
    renameCalls.add((sourceId, name));
    final index = entries.indexWhere((entry) => entry.id == sourceId);
    final entry = entries[index];
    entries[index] = SourceRosterEntry(
      id: entry.id,
      name: name,
      kind: entry.kind,
      enabled: entry.enabled,
      status: entry.status,
      counts: entry.counts,
    );
  }

  @override
  Future<void> remove(String sourceId) async {
    await removeGate?.future;
    entries.removeWhere((entry) => entry.id == sourceId);
  }

  @override
  Future<void> setEnabled(String sourceId, bool enabled) async {
    final index = entries.indexWhere((entry) => entry.id == sourceId);
    final entry = entries[index];
    entries[index] = SourceRosterEntry(
      id: entry.id,
      name: entry.name,
      kind: entry.kind,
      enabled: enabled,
      status: enabled ? 'ready' : 'disabled',
      counts: entry.counts,
    );
  }
}
