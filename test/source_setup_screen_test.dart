import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/main.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_editor.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_controller.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_screen.dart';
import 'package:wabbit_tv/src/features/sources/xtream_connector.dart';
import 'package:wabbit_tv/src/home_fixture_mode.dart';

void main() {
  testWidgets('Home Add source opens the shared in-shell Source Ledger', (
    tester,
  ) async {
    await tester.pumpWidget(
      const WabbitApp(fixtureMode: HomeFixtureMode.noSources),
    );
    await tester.tap(find.text('Add source'));
    await tester.pumpAndSettle();

    expect(find.text('Source details'), findsOneWidget);
    expect(find.byKey(const ValueKey('source-stage-dock')), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
  });

  testWidgets('Source Ledger Escape restores the no-source Home launcher', (
    tester,
  ) async {
    await tester.pumpWidget(
      const WabbitApp(fixtureMode: HomeFixtureMode.noSources),
    );
    await tester.tap(find.text('Add source'));
    await tester.pumpAndSettle();
    expect(find.text('Source details'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Add your first source'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'home first item');
  });

  testWidgets(
    'Escape exits idle Source Setup from the focused Server URL field',
    (tester) async {
      await tester.pumpWidget(
        const WabbitApp(fixtureMode: HomeFixtureMode.noSources),
      );
      await tester.tap(find.text('Add source'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      final server = tester.widget<TextField>(
        find.byKey(const ValueKey('source-field-Server URL')),
      );
      server.focusNode!.requestFocus();
      await tester.pump();
      expect(server.focusNode!.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Add your first source'), findsOneWidget);
    },
  );

  testWidgets(
    'Escape from a focused field during import focuses Cancel without exit',
    (tester) async {
      final initialFocus = FocusNode(debugLabel: 'source name');
      addTearDown(initialFocus.dispose);
      final service = _DelayedWidgetSourcePort();
      final controller = SourceSetupController(
        service: service,
        credentialStore: _WidgetCredentialStore(),
      );
      var exits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourceSetupScreen(
              initialFocus: initialFocus,
              onContentFocus: (_) {},
              onExit: () => exits++,
              onBrowse: (_) {},
              controller: controller,
            ),
          ),
        ),
      );
      await _enterSource(tester);
      final server = tester.widget<TextField>(
        find.byKey(const ValueKey('source-field-Server URL')),
      );
      server.focusNode!.requestFocus();
      await tester.pump();
      expect(server.focusNode!.hasFocus, isTrue);
      final operation = controller.connect(
        name: 'My IPTV',
        serverUrl: 'https://provider.example',
        username: 'fixture-user',
        password: 'fixture-password',
      );
      expect(controller.isImporting, isTrue);
      expect(server.focusNode!.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(exits, 0);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'source cancel');
      await controller.cancel();
      service.release();
      await operation;
    },
  );

  testWidgets('failure stays inline and Escape exits without clearing fields', (
    tester,
  ) async {
    final initialFocus = FocusNode(debugLabel: 'source name');
    addTearDown(initialFocus.dispose);
    var exits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceSetupScreen(
            initialFocus: initialFocus,
            onContentFocus: (_) {},
            onExit: () => exits++,
            onBrowse: (_) {},
            controller: SourceSetupController(
              service: _FailingWidgetSourcePort(),
              credentialStore: _WidgetCredentialStore(),
            ),
          ),
        ),
      ),
    );
    await _enterSource(tester);
    await _tapConnect(tester);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'That provider did not return a usable catalog. Check the server URL and try again.',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('source-field-Server URL')),
          )
          .controller!
          .text,
      'https://provider.example',
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('source-field-Username')),
          )
          .controller!
          .text,
      'fixture-user',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(exits, 1);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('source-field-Server URL')),
          )
          .controller!
          .text,
      'https://provider.example',
    );
  });

  testWidgets(
    'Source Ledger maintains three equal stage cells at the approved width',
    (tester) async {
      final initialFocus = FocusNode();
      addTearDown(initialFocus.dispose);
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourceSetupScreen(
              initialFocus: initialFocus,
              onContentFocus: (_) {},
              onExit: () {},
              onBrowse: (_) {},
              controller: SourceSetupController(
                service: _WidgetSourcePort(),
                credentialStore: _WidgetCredentialStore(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dock = tester.getRect(
        find.byKey(const ValueKey('source-stage-dock')),
      );
      final live = tester.getRect(find.text('Live'));
      final movies = tester.getRect(find.text('Movies'));
      final series = tester.getRect(find.text('Series'));
      expect(dock.width, greaterThan(0));
      expect((movies.left - live.left), closeTo(series.left - movies.left, 2));
    },
  );

  testWidgets('successful synthetic import exposes the three shaped handoffs', (
    tester,
  ) async {
    final initialFocus = FocusNode();
    addTearDown(initialFocus.dispose);
    SourceMediaKind? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceSetupScreen(
            initialFocus: initialFocus,
            onContentFocus: (_) {},
            onExit: () {},
            onBrowse: (kind) => selected = kind,
            controller: SourceSetupController(
              service: _WidgetSourcePort(),
              credentialStore: _WidgetCredentialStore(),
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('source-field-Source name')),
      'My IPTV',
    );
    await tester.enterText(
      find.byKey(const ValueKey('source-field-Server URL')),
      'https://provider.example',
    );
    await tester.enterText(
      find.byKey(const ValueKey('source-field-Username')),
      'fixture-user',
    );
    await tester.enterText(
      find.byKey(const ValueKey('source-field-Password')),
      'fixture-password',
    );
    await tester.ensureVisible(find.text('Connect and import'));
    await _tapConnect(tester);
    await tester.pumpAndSettle();

    expect(find.text('Source ready'), findsOneWidget);
    expect(find.text('Browse Live'), findsOneWidget);
    expect(find.text('Browse Movies'), findsOneWidget);
    expect(find.text('Browse Series'), findsOneWidget);
    await tester.tap(find.text('Browse Movies'));
    expect(selected, SourceMediaKind.movies);
  });

  testWidgets(
    'Cancel is left of Connect while traversal remains Connect then Cancel',
    (tester) async {
      final initialFocus = FocusNode(debugLabel: 'source name');
      addTearDown(initialFocus.dispose);
      await tester.pumpWidget(_sourceScreen(initialFocus, _WidgetSourcePort()));
      final cancel = find.widgetWithText(OutlinedButton, 'Cancel');
      final connect = find.widgetWithText(FilledButton, 'Connect and import');
      await tester.ensureVisible(connect);
      expect(
        tester.getRect(cancel).left,
        lessThan(tester.getRect(connect).left),
      );

      initialFocus.requestFocus();
      await tester.pump();
      final connectNode = tester.widget<FilledButton>(connect).focusNode!;
      final cancelNode = tester.widget<OutlinedButton>(cancel).focusNode!;
      final scope = FocusScope.of(tester.element(connect));
      for (var index = 0; index < 5; index++) {
        scope.nextFocus();
        await tester.pump();
      }
      expect(connectNode.hasFocus, isTrue);
      scope.nextFocus();
      await tester.pump();
      expect(cancelNode.hasFocus, isTrue);
    },
  );

  testWidgets('import focus moves to Cancel, then Browse Live when ready', (
    tester,
  ) async {
    final initialFocus = FocusNode(debugLabel: 'source name');
    addTearDown(initialFocus.dispose);
    final service = _DelayedWidgetSourcePort();
    await tester.pumpWidget(_sourceScreen(initialFocus, service));
    await _enterSource(tester);

    await _tapConnect(tester);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'source cancel');

    service.release();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'browse Live');
  });

  testWidgets('preloaded ready source focuses Browse Live on first build', (
    tester,
  ) async {
    final initialFocus = FocusNode(debugLabel: 'source name');
    addTearDown(initialFocus.dispose);
    final controller =
        SourceSetupController(
            service: _WidgetSourcePort(),
            credentialStore: _WidgetCredentialStore(),
          )
          ..ready = const SourceReady(
            counts: {
              SourceMediaKind.live: 1,
              SourceMediaKind.movies: 1,
              SourceMediaKind.series: 1,
            },
          );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceSetupScreen(
            initialFocus: initialFocus,
            onContentFocus: (_) {},
            onExit: () {},
            onBrowse: (_) {},
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'browse Live');
  });

  testWidgets('editor load failure leaves loading for the unavailable state', (
    tester,
  ) async {
    final initialFocus = FocusNode(debugLabel: 'source name');
    addTearDown(initialFocus.dispose);
    final controller = _ThrowingEditorController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceSetupScreen(
            initialFocus: initialFocus,
            onContentFocus: (_) {},
            onExit: () {},
            onBrowse: (_) {},
            controller: controller,
            editRequest: const SourceEditorRequest(
              sourceId: 'unavailable',
              sourceName: 'Unavailable',
              databaseKind: 'xtream',
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Source details are unavailable'), findsOneWidget);
  });

  testWidgets('cancellation acknowledgement returns focus to Source name', (
    tester,
  ) async {
    final initialFocus = FocusNode(debugLabel: 'source name');
    addTearDown(initialFocus.dispose);
    final service = _DelayedWidgetSourcePort();
    await tester.pumpWidget(_sourceScreen(initialFocus, service));
    await _enterSource(tester);

    await _tapConnect(tester);
    await tester.pump();
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'source name');
    service.release();
  });

  testWidgets('Escape during import moves focus to Cancel without cancelling', (
    tester,
  ) async {
    final initialFocus = FocusNode(debugLabel: 'source name');
    addTearDown(initialFocus.dispose);
    final service = _DelayedWidgetSourcePort();
    await tester.pumpWidget(_sourceScreen(initialFocus, service));
    await _enterSource(tester);

    await _tapConnect(tester);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'source cancel');
    service.release();
  });

  testWidgets('ready dock shows exactly three formatted media counts', (
    tester,
  ) async {
    final initialFocus = FocusNode();
    addTearDown(initialFocus.dispose);
    await tester.pumpWidget(
      _sourceScreen(initialFocus, _LargeCountsSourcePort()),
    );
    await _enterSource(tester);
    await _tapConnect(tester);
    await tester.pumpAndSettle();

    final dock = find.byKey(const ValueKey('source-stage-dock'));
    expect(
      find.descendant(of: dock, matching: find.text('1,200 items')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dock, matching: find.text('2,345 items')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dock, matching: find.text('6,789 items')),
      findsOneWidget,
    );
    for (final kind in SourceMediaKind.values) {
      expect(
        find.byKey(ValueKey('source-stage-cell-${kind.name}')),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(const ValueKey('source-stage-cell-disclaimer')),
      findsNothing,
    );
  });

  testWidgets(
    'an empty add ledger selects all three supported connector forms',
    (tester) async {
      final initialFocus = FocusNode(debugLabel: 'source name');
      addTearDown(initialFocus.dispose);
      await tester.binding.setSurfaceSize(const Size(540, 620));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourceSetupScreen(
              initialFocus: initialFocus,
              onContentFocus: (_) {},
              onExit: () {},
              onBrowse: (_) {},
              m3uFilePicker: () async => r'C:\Lists\weekend.m3u',
              controller: SourceSetupController(
                service: _WidgetSourcePort(),
                credentialStore: _WidgetCredentialStore(),
              ),
            ),
          ),
        ),
      );

      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('source-field-Source name')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(
        find.byKey(const ValueKey('source-field-Server URL')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('source-connector-m3uUrl')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('source-field-M3U URL')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('source-field-Username')), findsNothing);

      final m3uFile = find.byKey(const ValueKey('source-connector-m3uFile'));
      await tester.ensureVisible(m3uFile);
      await tester.tap(m3uFile);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('source-field-M3U file')),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Choose M3U file'));
      await tester.tap(find.text('Choose M3U file'));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('source-field-M3U file')),
            )
            .controller!
            .text,
        r'C:\Lists\weekend.m3u',
      );

      final xtream = find.byKey(const ValueKey('source-connector-xtream'));
      await tester.ensureVisible(xtream);
      await tester.tap(xtream);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('source-field-Password')),
        findsOneWidget,
      );
    },
  );
}

class _FailingWidgetSourcePort extends _WidgetSourcePort {
  @override
  Future<ImportedStage> fetch(SourceDefinition source, SourceMediaKind kind) =>
      Future<ImportedStage>.error(
        const SourceImportFailure(SourceImportFailureKind.emptyResponse),
      );
}

class _ThrowingEditorController extends SourceSetupController {
  _ThrowingEditorController()
    : super(
        service: _WidgetSourcePort(),
        credentialStore: _WidgetCredentialStore(),
      );

  @override
  Future<SourceEditorDraft?> loadEditor(SourceEditorRequest request) async {
    throw StateError('fixture editor load failure');
  }
}

class _WidgetSourcePort implements SourceSetupPort {
  @override
  Future<ImportedStage> fetch(
    SourceDefinition source,
    SourceMediaKind kind,
  ) async => ImportedStage(
    kind: kind,
    categories: const [],
    items: [
      ImportedCatalogItem(
        providerKey: kind.name,
        title: '${kind.label} fixture',
        categoryKey: null,
        playbackRef: '{}',
      ),
    ],
  );

  @override
  Future<SourceReady> commit(
    SourceDefinition source,
    List<ImportedStage> stages,
  ) async => SourceReady(
    counts: {for (final stage in stages) stage.kind: stage.itemCount},
  );

  @override
  Future<void> remove(String sourceId) async {}
}

class _WidgetCredentialStore implements CredentialStore {
  @override
  Future<StoredCredential?> read(String key) async => null;

  @override
  Future<void> delete(String key) async {}

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}

Widget _sourceScreen(FocusNode initialFocus, SourceSetupPort service) =>
    MaterialApp(
      home: Scaffold(
        body: SourceSetupScreen(
          initialFocus: initialFocus,
          onContentFocus: (_) {},
          onExit: () {},
          onBrowse: (_) {},
          controller: SourceSetupController(
            service: service,
            credentialStore: _WidgetCredentialStore(),
          ),
        ),
      ),
    );

Future<void> _tapConnect(WidgetTester tester) async {
  final button = find.widgetWithText(FilledButton, 'Connect and import');
  await tester.ensureVisible(button);
  await tester.tap(button);
}

Future<void> _enterSource(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('source-field-Source name')),
    'My IPTV',
  );
  await tester.enterText(
    find.byKey(const ValueKey('source-field-Server URL')),
    'https://provider.example',
  );
  await tester.enterText(
    find.byKey(const ValueKey('source-field-Username')),
    'fixture-user',
  );
  await tester.enterText(
    find.byKey(const ValueKey('source-field-Password')),
    'fixture-password',
  );
}

class _DelayedWidgetSourcePort extends _WidgetSourcePort {
  final _gate = Completer<void>();
  bool _waiting = true;

  @override
  Future<ImportedStage> fetch(
    SourceDefinition source,
    SourceMediaKind kind,
  ) async {
    if (_waiting) {
      await _gate.future;
      _waiting = false;
    }
    return super.fetch(source, kind);
  }

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }
}

class _LargeCountsSourcePort extends _WidgetSourcePort {
  static const _counts = [1200, 2345, 6789];

  @override
  Future<ImportedStage> fetch(
    SourceDefinition source,
    SourceMediaKind kind,
  ) async => ImportedStage(
    kind: kind,
    categories: const [],
    items: [
      for (var index = 0; index < _counts[kind.index]; index++)
        ImportedCatalogItem(
          providerKey: '${kind.name}-$index',
          title: '${kind.label} $index',
          categoryKey: null,
          playbackRef: '{}',
        ),
    ],
  );
}
