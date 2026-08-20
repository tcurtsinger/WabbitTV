import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/app_shell.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_editor.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_controller.dart';
import 'package:wabbit_tv/src/home_fixture_mode.dart';

void main() {
  testWidgets('Sources uses the durable multi-source roster and real actions', (
    tester,
  ) async {
    final controller = _ShellSourceController();
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_shell(controller));
    await tester.pumpAndSettle();

    expect(find.text('Primary'), findsWidgets);
    expect(find.text('Weekend'), findsOneWidget);
    expect(find.textContaining('Disabled'), findsOneWidget);
    expect(controller.rosterLoads, greaterThanOrEqualTo(1));

    await tester.tap(find.byKey(const ValueKey('source-row-primary')));
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(controller.refreshes, ['primary']);

    await tester.tap(find.text('Disable'));
    await tester.pumpAndSettle();
    expect(controller.enabledChanges, ['primary:false']);

    await tester.tap(find.byKey(const ValueKey('source-row-weekend')));
    await tester.tap(find.text('Enable'));
    await tester.pumpAndSettle();
    expect(controller.enabledChanges, ['primary:false', 'weekend:true']);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove source'));
    await tester.pumpAndSettle();
    expect(controller.removed, ['weekend']);
    expect(find.text('Weekend'), findsNothing);
  });

  testWidgets(
    'Add exits back to a reloaded roster and invokes its local picker seam',
    (tester) async {
      final controller = _ShellSourceController(entries: []);
      addTearDown(controller.dispose);
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var pickerCalls = 0;
      await tester.pumpWidget(
        _shell(
          controller,
          picker: () async {
            pickerCalls++;
            return r'C:\Lists\weekend.m3u';
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('source-action-Add source')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-connector-m3uFile')));
      await tester.pump();
      await tester.tap(find.text('Choose M3U file'));
      await tester.pumpAndSettle();
      expect(pickerCalls, 1);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('source-field-M3U file')),
            )
            .controller!
            .text,
        r'C:\Lists\weekend.m3u',
      );

      await tester.enterText(
        find.byKey(const ValueKey('source-field-Source name')),
        'Weekend list',
      );
      await tester.tap(find.text('Connect and import'));
      await tester.pumpAndSettle();
      expect(find.text('Source ready'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Weekend list'), findsWidgets);
      expect(controller.rosterLoads, greaterThanOrEqualTo(2));
    },
  );

  testWidgets(
    'Add source clears prior ready presentation without clearing persisted truth',
    (tester) async {
      final controller = _ShellSourceController()
        ..ready = const SourceReady(
          counts: {
            SourceMediaKind.live: 4,
            SourceMediaKind.movies: 5,
            SourceMediaKind.series: 6,
          },
        )
        ..persisted = const PersistedSource(
          id: 'primary',
          name: 'Primary',
          credentialKey: 'primary-key',
          counts: {
            SourceMediaKind.live: 4,
            SourceMediaKind.movies: 5,
            SourceMediaKind.series: 6,
          },
        );
      addTearDown(controller.dispose);
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_shell(controller));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('source-action-Add source')).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Source ready'), findsNothing);
      expect(find.text('Source details'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('source-field-Source name')),
        findsOneWidget,
      );
      expect(controller.ready, isNull);
      expect(controller.persisted?.id, 'primary');
    },
  );

  testWidgets(
    'Edit prefills, saves, returns to the selected row, and cancel never hangs',
    (tester) async {
      final controller = _ShellSourceController();
      addTearDown(controller.dispose);
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_shell(controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('source-row-weekend')));
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Edit source'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('source-field-Source name')),
            )
            .controller!
            .text,
        'Weekend',
      );

      await tester.enterText(
        find.byKey(const ValueKey('source-field-Source name')),
        'Weekend renamed',
      );
      await tester.ensureVisible(find.text('Save and refresh'));
      await tester.tap(find.text('Save and refresh'));
      await tester.pumpAndSettle();
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('Weekend renamed'), findsWidgets);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'source row weekend',
      );

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Sources'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'source row weekend',
      );

      final loadsBeforeRestart = controller.rosterLoads;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_shell(controller));
      await tester.pumpAndSettle();
      expect(find.text('Weekend renamed'), findsWidgets);
      expect(controller.rosterLoads, greaterThan(loadsBeforeRestart));
    },
  );

  testWidgets(
    'rail navigation closes an open editor operation before leaving Sources',
    (tester) async {
      final controller = _ShellSourceController();
      addTearDown(controller.dispose);
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_shell(controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('source-row-weekend')));
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Edit source'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.live_tv_outlined).first);
      await tester.pumpAndSettle();
      expect(find.text('Edit source'), findsNothing);

      await tester.tap(find.byIcon(Icons.settings_outlined).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();

      expect(controller.refreshes, ['weekend']);
      expect(
        find.text('Another source action is already in progress.'),
        findsNothing,
      );
    },
  );
}

Widget _shell(_ShellSourceController controller, {M3uFilePicker? picker}) =>
    MaterialApp(
      home: WabbitShell(
        fixtureMode: HomeFixtureMode.noPersonalization,
        initialDestination: ShellDestination.settings,
        sourceController: controller,
        m3uFilePicker: picker,
      ),
    );

class _ShellSourceController extends SourceSetupController {
  _ShellSourceController({List<SourceRosterEntry>? entries})
    : _entries =
          entries ??
          [
            _entry('primary', 'Primary'),
            _entry('weekend', 'Weekend', enabled: false, kind: 'm3u_file'),
          ],
      super(
        service: const _NoopSetupPort(),
        credentialStore: const _NoopStore(),
      );

  final List<SourceRosterEntry> _entries;
  int rosterLoads = 0;
  final refreshes = <String>[];
  final enabledChanges = <String>[];
  final removed = <String>[];

  @override
  Future<List<SourceRosterEntry>> loadSourceRoster() async {
    rosterLoads++;
    return List.of(_entries);
  }

  @override
  Future<void> refreshManagedSource(String sourceId) async {
    refreshes.add(sourceId);
  }

  @override
  Future<void> setManagedSourceEnabled(String sourceId, bool enabled) async {
    enabledChanges.add('$sourceId:$enabled');
    _replace(sourceId, enabled: enabled);
  }

  @override
  Future<bool> removeManagedSource(String sourceId) async {
    removed.add(sourceId);
    _entries.removeWhere((entry) => entry.id == sourceId);
    return true;
  }

  @override
  Future<void> connectM3uFile({
    required String name,
    required String path,
  }) async {
    final id = 'added';
    _entries.add(_entry(id, name, kind: 'm3u_file'));
    ready = const SourceReady(
      counts: {
        SourceMediaKind.live: 1,
        SourceMediaKind.movies: 0,
        SourceMediaKind.series: 0,
      },
    );
    persisted = PersistedSource(
      id: id,
      name: name,
      credentialKey: 'added-key',
      counts: ready!.counts,
    );
    notifyListeners();
  }

  @override
  Future<SourceEditorDraft?> loadEditor(SourceEditorRequest request) async {
    final entry = _entries.where((entry) => entry.id == request.sourceId).first;
    return SourceEditorDraft(
      sourceId: entry.id,
      credentialKey: '${entry.id}-key',
      kind: SourceEditorKindLabels.fromDatabaseKind(entry.kind),
      name: entry.name,
      endpoint: entry.kind == 'm3u_file'
          ? r'C:\Lists\weekend.m3u'
          : 'https://provider.example',
      username: entry.kind == 'xtream' ? 'user' : '',
      password: entry.kind == 'xtream' ? 'password' : '',
    );
  }

  @override
  Future<bool> saveEditor({
    required SourceEditorDraft draft,
    required String name,
    required String endpoint,
    required String username,
    required String password,
  }) async {
    _replace(draft.sourceId, name: name.trim());
    return true;
  }

  void _replace(String id, {String? name, bool? enabled}) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    final current = _entries[index];
    final isEnabled = enabled ?? current.enabled;
    _entries[index] = SourceRosterEntry(
      id: current.id,
      name: name ?? current.name,
      kind: current.kind,
      enabled: isEnabled,
      status: isEnabled ? 'Ready' : 'Excluded from active results',
      counts: current.counts,
    );
  }
}

SourceRosterEntry _entry(
  String id,
  String name, {
  bool enabled = true,
  String kind = 'xtream',
}) => SourceRosterEntry(
  id: id,
  name: name,
  kind: kind,
  enabled: enabled,
  status: enabled ? 'Ready' : 'Excluded from active results',
  counts: const {
    SourceMediaKind.live: 1,
    SourceMediaKind.movies: 2,
    SourceMediaKind.series: 3,
  },
);

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

class _NoopStore implements CredentialStore {
  const _NoopStore();

  @override
  Future<void> delete(String key) async {}

  @override
  Future<StoredCredential?> read(String key) async => null;

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}
