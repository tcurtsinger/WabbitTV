import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/catalog_scope_controller.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  test('loads only browsable sources and persists one global scope', () async {
    final port = _FakeScopePort(
      sources: [
        _roster('ready', status: 'ready'),
        _roster(
          'failed',
          status: 'refresh_failed',
          counts: const {SourceMediaKind.live: 12},
        ),
        _roster('pending', status: 'pending'),
        _roster('disabled', status: 'ready', enabled: false),
      ],
    );
    final controller = CatalogScopeController(port: port);

    await controller.initialize();

    expect(controller.sources.map((source) => source.id), ['ready', 'failed']);
    expect(controller.scope.isAll, isTrue);

    await controller.select(const LibraryScope.source('failed'));
    expect(controller.scope.sourceId, 'failed');
    expect(port.savedScope?.sourceId, 'failed');

    final resolved = await controller.resolveReadySource('failed');
    expect(resolved?.id, 'failed');
  });

  test(
    'removed or disabled selection falls back to All and announces',
    () async {
      final port = _FakeScopePort(
        sources: [_roster('ready', status: 'ready')],
        scope: const LibraryScope.source('ready'),
      );
      final controller = CatalogScopeController(port: port);
      await controller.initialize();
      expect(controller.scope.sourceId, 'ready');

      port.sources = const [];
      port.scope = const LibraryScope.all();
      await controller.refresh();

      expect(controller.scope.isAll, isTrue);
      expect(
        controller.announcement,
        'Source unavailable. Showing All sources.',
      );
    },
  );

  test('invalid explicit selection normalizes to All', () async {
    final port = _FakeScopePort(sources: [_roster('ready', status: 'ready')]);
    final controller = CatalogScopeController(port: port);
    await controller.initialize();

    await controller.select(const LibraryScope.source('missing'));

    expect(controller.scope.isAll, isTrue);
    expect(controller.announcement, 'Source unavailable. Showing All sources.');
  });

  test('fresh initialization reads roster before persisted scope', () async {
    final port = _OrderedScopePort();
    final controller = CatalogScopeController(port: port);

    final initialization = controller.initialize();
    await Future<void>.delayed(Duration.zero);
    expect(port.scopeLoadCalls, 0);

    port.roster.complete([_roster('ready', status: 'ready')]);
    await Future<void>.delayed(Duration.zero);
    expect(port.scopeLoadCalls, 1);

    port.catalogScope.complete(const LibraryScope.all());
    await initialization;
    expect(controller.initialized, isTrue);
  });

  test(
    'refresh is single-flight and retains the prior local roster on failure',
    () async {
      final port = _FakeScopePort(sources: [_roster('ready', status: 'ready')]);
      final controller = CatalogScopeController(port: port);
      await controller.initialize();

      port.failRoster = true;
      final first = controller.refresh();
      final second = controller.refresh();
      expect(identical(first, second), isTrue);
      await first;

      expect(controller.error, isNull);
      expect(controller.scope.sourceId, isNull);
      expect(controller.sources.map((source) => source.id), ['ready']);
      expect(
        controller.announcement,
        'Could not update sources. Showing the last local catalog.',
      );
    },
  );

  test(
    'rapid selections persist serially and only publish the latest choice',
    () async {
      final port = _GatedSelectionScopePort(
        sources: [
          _roster('first', status: 'ready'),
          _roster('second', status: 'ready'),
        ],
      );
      final controller = CatalogScopeController(port: port);
      await controller.initialize();

      final first = controller.select(const LibraryScope.source('first'));
      await Future<void>.delayed(Duration.zero);
      final second = controller.select(const LibraryScope.source('second'));
      await Future<void>.delayed(Duration.zero);
      expect(port.saveCalls, ['first']);

      port.gates['first']!.complete(const LibraryScope.source('first'));
      await Future<void>.delayed(Duration.zero);
      expect(port.saveCalls, ['first', 'second']);
      expect(controller.scope.isAll, isTrue);

      port.gates['second']!.complete(const LibraryScope.source('second'));
      await Future.wait([first, second]);
      expect(controller.scope.sourceId, 'second');
      expect(port.scope.sourceId, 'second');
    },
  );

  test(
    'latest selection failure reconciles the prior successful persisted scope',
    () async {
      final port = _GatedSelectionScopePort(
        sources: [
          _roster('first', status: 'ready'),
          _roster('second', status: 'ready'),
        ],
      );
      final controller = CatalogScopeController(port: port);
      await controller.initialize();

      final first = controller.select(const LibraryScope.source('first'));
      await Future<void>.delayed(Duration.zero);
      final second = controller.select(const LibraryScope.source('second'));
      port.gates['first']!.complete(const LibraryScope.source('first'));
      await Future<void>.delayed(Duration.zero);
      expect(port.saveCalls, ['first', 'second']);
      expect(controller.scope.isAll, isTrue);

      port.gates['second']!.completeError(StateError('fixture save failure'));
      await Future.wait([first, second]);

      expect(port.scope.sourceId, 'first');
      expect(controller.scope.sourceId, 'first');
      expect(controller.error, isNotNull);
      expect(controller.announcement, 'Could not change source. Try again.');
    },
  );
}

SourceRosterEntry _roster(
  String id, {
  required String status,
  bool enabled = true,
  Map<SourceMediaKind, int> counts = const {},
}) => SourceRosterEntry(
  id: id,
  name: '$id source',
  kind: 'xtream',
  enabled: enabled,
  status: status,
  counts: {for (final kind in SourceMediaKind.values) kind: counts[kind] ?? 0},
);

class _FakeScopePort implements CatalogScopePort {
  _FakeScopePort({
    required this.sources,
    this.scope = const LibraryScope.all(),
  });

  List<SourceRosterEntry> sources;
  LibraryScope scope;
  LibraryScope? savedScope;
  bool failRoster = false;

  @override
  Future<LibraryScope> loadCatalogScope() async => scope;

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async =>
      sources.any((source) => source.id == sourceId)
      ? PersistedSource(
          id: sourceId,
          name: '$sourceId source',
          credentialKey: '$sourceId-key',
          counts: const {},
        )
      : null;

  @override
  Future<List<SourceRosterEntry>> loadSourceRoster() async {
    if (failRoster) throw StateError('local read failure');
    return sources;
  }

  @override
  Future<LibraryScope> saveCatalogScope(LibraryScope requested) async {
    final sourceId = requested.sourceId;
    scope = sourceId == null || sources.any((source) => source.id == sourceId)
        ? requested
        : const LibraryScope.all();
    savedScope = scope;
    return scope;
  }
}

class _OrderedScopePort implements CatalogScopePort {
  final roster = Completer<List<SourceRosterEntry>>();
  final catalogScope = Completer<LibraryScope>();
  int scopeLoadCalls = 0;

  @override
  Future<LibraryScope> loadCatalogScope() {
    scopeLoadCalls++;
    return catalogScope.future;
  }

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;

  @override
  Future<List<SourceRosterEntry>> loadSourceRoster() => roster.future;

  @override
  Future<LibraryScope> saveCatalogScope(LibraryScope scope) async => scope;
}

class _GatedSelectionScopePort extends _FakeScopePort {
  _GatedSelectionScopePort({required super.sources});

  final gates = <String, Completer<LibraryScope>>{
    'first': Completer<LibraryScope>(),
    'second': Completer<LibraryScope>(),
  };
  final saveCalls = <String>[];

  @override
  Future<LibraryScope> saveCatalogScope(LibraryScope requested) async {
    final sourceId = requested.sourceId!;
    saveCalls.add(sourceId);
    final saved = await gates[sourceId]!.future;
    scope = saved;
    savedScope = saved;
    return saved;
  }
}
