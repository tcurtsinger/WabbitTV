import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wabbit_tv/src/features/settings/general_settings_section.dart';
import 'package:wabbit_tv/src/features/settings/startup_preferences_controller.dart';
import 'package:wabbit_tv/src/features/sources/source_management_screen.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/startup_models.dart';

void main() {
  testWidgets('startup choices reflow at 600px and 2x text without overflow', (
    tester,
  ) async {
    final controller = StartupPreferencesController(port: _SettingsPort());
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(controller, textScale: 2));
    await tester.pumpAndSettle();

    expect(find.text('General'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Previous screen'), findsOneWidget);
    expect(find.text('Last channel'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full Settings surface stays usable at 600px and 2x text', (
    tester,
  ) async {
    final startup = StartupPreferencesController(port: _SettingsPort());
    final sources = SourceManagementController(port: const _EmptySourcePort());
    addTearDown(startup.dispose);
    addTearDown(sources.dispose);
    final initialFocus = FocusNode();
    addTearDown(initialFocus.dispose);
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: SourceManagementScreen(
          initialFocus: initialFocus,
          onContentFocus: (_) {},
          onOpenRail: () {},
          onAddSource: () {},
          controller: sources,
          startupPreferencesController: startup,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sources'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote Select saves and keeps focus through async rebuilds', (
    tester,
  ) async {
    final save = Completer<void>();
    final port = _SettingsPort()..targetSave = save.future;
    final controller = StartupPreferencesController(port: port);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    final focus = _focus(tester, 'startup previousScreen');
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(controller.displayedTarget, StartupTarget.previousScreen);
    expect(find.text('Saving startup choice…'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus, focus);

    save.complete();
    await tester.pumpAndSettle();
    expect(controller.preference.target, StartupTarget.previousScreen);
    expect(FocusManager.instance.primaryFocus, focus);
  });

  testWidgets(
    'Settings D-pad bridges Sources and General without async focus theft',
    (tester) async {
      final save = Completer<void>();
      final port = _SettingsPort()..targetSave = save.future;
      final startup = StartupPreferencesController(port: port);
      final sources = SourceManagementController(port: const _OneSourcePort());
      final firstSource = FocusNode(debugLabel: 'settings first source');
      addTearDown(startup.dispose);
      addTearDown(sources.dispose);
      addTearDown(firstSource.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: SourceManagementScreen(
            initialFocus: firstSource,
            onContentFocus: (_) {},
            onOpenRail: () {},
            onAddSource: () {},
            controller: sources,
            startupPreferencesController: startup,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus, firstSource);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'startup home');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'startup previousScreen',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(port.saveCalls, [StartupTarget.previousScreen]);
      expect(find.text('Saving startup choice…'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, firstSource);

      save.complete();
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, firstSource);
    },
  );

  testWidgets('zero-source Settings D-pad reaches the primary Add source', (
    tester,
  ) async {
    final startup = StartupPreferencesController(port: _SettingsPort());
    final sources = SourceManagementController(port: const _EmptySourcePort());
    final primarySourceAction = FocusNode(debugLabel: 'empty primary action');
    addTearDown(startup.dispose);
    addTearDown(sources.dispose);
    addTearDown(primarySourceAction.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SourceManagementScreen(
          initialFocus: primarySourceAction,
          onContentFocus: (_) {},
          onOpenRail: () {},
          onAddSource: () {},
          controller: sources,
          startupPreferencesController: startup,
        ),
      ),
    );
    await tester.pumpAndSettle();

    _focus(tester, 'startup home').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, primarySourceAction);
    expect(find.widgetWithText(FilledButton, 'Add source'), findsOneWidget);
  });

  testWidgets('failed-source Settings D-pad reaches Retry', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final startup = StartupPreferencesController(port: _SettingsPort());
    final sources = SourceManagementController(
      port: const _FailingSourcePort(),
    );
    final retryFocus = FocusNode(debugLabel: 'source load retry');
    addTearDown(startup.dispose);
    addTearDown(sources.dispose);
    addTearDown(retryFocus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SourceManagementScreen(
          initialFocus: retryFocus,
          onContentFocus: (_) {},
          onOpenRail: () {},
          onAddSource: () {},
          controller: sources,
          startupPreferencesController: startup,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sources could not be loaded'), findsOneWidget);

    _focus(tester, 'startup home').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, retryFocus);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Retry'))
          .focusNode,
      retryFocus,
    );
  });

  testWidgets('loading-source Settings D-pad uses the stable header action', (
    tester,
  ) async {
    final gate = Completer<List<SourceRosterEntry>>();
    final startup = StartupPreferencesController(port: _SettingsPort());
    final sources = SourceManagementController(
      port: _LoadingSourcePort(gate.future),
    );
    final primarySourceAction = FocusNode(debugLabel: 'loading primary action');
    addTearDown(startup.dispose);
    addTearDown(sources.dispose);
    addTearDown(primarySourceAction.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SourceManagementScreen(
          initialFocus: primarySourceAction,
          onContentFocus: (_) {},
          onOpenRail: () {},
          onAddSource: () {},
          controller: sources,
          startupPreferencesController: startup,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Loading sources…'), findsOneWidget);

    _focus(tester, 'startup home').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'source management add',
    );
    gate.complete(const []);
    await tester.pumpAndSettle();
  });

  testWidgets('failed save shows recovery and restores the durable choice', (
    tester,
  ) async {
    final port = _SettingsPort()..failTargetSave = true;
    final controller = StartupPreferencesController(port: port);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('startup-choice-lastChannel')));
    await tester.pumpAndSettle();

    expect(controller.displayedTarget, StartupTarget.home);
    expect(find.textContaining('previous choice is unchanged'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('startup-settings-retry')),
      findsOneWidget,
    );
  });
}

Widget _app(StartupPreferencesController controller, {double textScale = 1}) =>
    MaterialApp(
      theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: GeneralSettingsSection(
            controller: controller,
            onContentFocus: (_) {},
          ),
        ),
      ),
    );

FocusNode _focus(WidgetTester tester, String debugLabel) => tester
    .widget<Focus>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Focus && widget.focusNode?.debugLabel == debugLabel,
      ),
    )
    .focusNode!;

class _SettingsPort implements StartupPreferencesPort {
  StartupPreference value = const StartupPreference.defaults();
  Future<void>? targetSave;
  bool failTargetSave = false;
  final saveCalls = <StartupTarget>[];

  @override
  Future<StartupPreference> loadStartupPreference() async => value;

  @override
  Future<StartupResolution> resolveStartupDestination() async =>
      const StartupResolution.home();

  @override
  Future<bool> saveLastLiveLibraryItem(String libraryItemId) async => true;

  @override
  Future<StartupPreference> savePreviousDestination(
    StartupDestinationSlug destination,
  ) async => value;

  @override
  Future<StartupPreference> saveStartupTarget(StartupTarget target) async {
    saveCalls.add(target);
    final pending = targetSave;
    if (pending != null) await pending;
    if (failTargetSave) throw StateError('private save failure');
    value = StartupPreference(
      target: target,
      previousDestination: value.previousDestination,
      lastLiveLibraryItemId: value.lastLiveLibraryItemId,
    );
    return value;
  }
}

class _EmptySourcePort implements SourceManagementPort {
  const _EmptySourcePort();

  @override
  Future<void> editAndRefresh(String sourceId) async {}
  @override
  Future<List<SourceRosterEntry>> loadRoster() async => const [];
  @override
  Future<void> refresh(String sourceId) async {}
  @override
  Future<void> remove(String sourceId) async {}
  @override
  Future<void> rename(String sourceId, String name) async {}
  @override
  Future<void> setEnabled(String sourceId, bool enabled) async {}
}

class _OneSourcePort implements SourceManagementPort {
  const _OneSourcePort();

  @override
  Future<void> editAndRefresh(String sourceId) async {}
  @override
  Future<List<SourceRosterEntry>> loadRoster() async => const [
    SourceRosterEntry(
      id: 'strong',
      name: 'Strong',
      kind: 'xtream',
      enabled: true,
      status: 'ready',
      counts: {SourceMediaKind.live: 1},
    ),
  ];
  @override
  Future<void> refresh(String sourceId) async {}
  @override
  Future<void> remove(String sourceId) async {}
  @override
  Future<void> rename(String sourceId, String name) async {}
  @override
  Future<void> setEnabled(String sourceId, bool enabled) async {}
}

class _FailingSourcePort implements SourceManagementPort {
  const _FailingSourcePort();

  @override
  Future<void> editAndRefresh(String sourceId) async {}
  @override
  Future<List<SourceRosterEntry>> loadRoster() async =>
      throw StateError('local load failure');
  @override
  Future<void> refresh(String sourceId) async {}
  @override
  Future<void> remove(String sourceId) async {}
  @override
  Future<void> rename(String sourceId, String name) async {}
  @override
  Future<void> setEnabled(String sourceId, bool enabled) async {}
}

class _LoadingSourcePort implements SourceManagementPort {
  const _LoadingSourcePort(this.result);

  final Future<List<SourceRosterEntry>> result;

  @override
  Future<void> editAndRefresh(String sourceId) async {}
  @override
  Future<List<SourceRosterEntry>> loadRoster() => result;
  @override
  Future<void> refresh(String sourceId) async {}
  @override
  Future<void> remove(String sourceId) async {}
  @override
  Future<void> rename(String sourceId, String name) async {}
  @override
  Future<void> setEnabled(String sourceId, bool enabled) async {}
}
