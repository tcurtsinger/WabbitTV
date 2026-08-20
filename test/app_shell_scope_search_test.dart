import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/app_shell.dart';
import 'package:wabbit_tv/src/features/browse/basic_browse_screen.dart';
import 'package:wabbit_tv/src/features/browse/catalog_scope_controller.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/playback/playback_transport.dart';
import 'package:wabbit_tv/src/features/playback/player_screen.dart';
import 'package:wabbit_tv/src/features/search/local_search_screen.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/home_fixture_mode.dart';

void main() {
  testWidgets('one scope controller persists from Browse into Search', (
    tester,
  ) async {
    final port = _ScopePort(scope: const LibraryScope.source('source-b'));
    final scope = CatalogScopeController(port: port);
    final searchData = _SearchData();
    addTearDown(scope.dispose);
    await tester.pumpWidget(
      _shell(
        initial: ShellDestination.live,
        scope: scope,
        browseData: const _BrowseData(),
        searchData: searchData,
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final searchDestination = tester.widget<FocusableActionDetector>(
      find.byKey(const ValueKey('shell-destination-search')),
    );
    searchDestination.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'news');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();

    expect(scope.scope.sourceId, 'source-b');
    expect(searchData.lastScope?.sourceId, 'source-b');
  });

  testWidgets('Search Live result preserves source B despite stale source A', (
    tester,
  ) async {
    PlaybackHandoff? handoff;
    final scope = CatalogScopeController(port: _ScopePort());
    addTearDown(scope.dispose);
    await tester.pumpWidget(
      _shell(
        initial: ShellDestination.search,
        scope: scope,
        searchData: _SearchData(),
        browseSource: _sourceA,
        onHandoff: (value) => handoff = value,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'news');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-item-live-b')));

    expect(handoff, isA<LivePlaybackHandoff>());
    expect(handoff?.sourceId, 'source-b');
  });

  testWidgets('production manager resolves the exact selected source', (
    tester,
  ) async {
    final scope = CatalogScopeController(port: _ScopePort());
    addTearDown(scope.dispose);
    final transport = _Transport();
    final resolverCalls = <String>[];
    await tester.pumpWidget(
      _shell(
        initial: ShellDestination.search,
        scope: scope,
        searchData: _SearchData(),
        browseSource: _sourceA,
        playbackResolver: (sourceId) {
          resolverCalls.add(sourceId);
          return _sourceB;
        },
        credentialStore: const _Credentials(),
        transportFactory: () => transport,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'news');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-item-live-b')));
    await _pumpUntil(
      tester,
      () => find.byType(PlayerScreen).evaluate().isNotEmpty,
    );

    final player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    expect(player.manager, isNotNull);
    expect(player.sessionId, isNotNull);
    expect(player.sourceResolver, isNull);
    expect(resolverCalls, contains('source-b'));
    expect(transport.openedUri?.host, 'selected.example');
  });

  testWidgets('an authoritative null resolver cannot revive matching stale A', (
    tester,
  ) async {
    final scope = CatalogScopeController(port: _ScopePort());
    addTearDown(scope.dispose);
    var transportCalls = 0;
    await tester.pumpWidget(
      _shell(
        initial: ShellDestination.search,
        scope: scope,
        searchData: _SearchData(sourceId: 'source-a'),
        browseSource: _sourceA,
        playbackResolver: (_) => null,
        transportFactory: () {
          transportCalls++;
          return _Transport();
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'news');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-item-live-b')));
    await _pumpUntil(tester, () => find.text('Retry').evaluate().isNotEmpty);

    expect(transportCalls, 0);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Open Settings'), findsNothing);
  });

  testWidgets('Search Escape opens rail, then restores its focused row', (
    tester,
  ) async {
    final scope = CatalogScopeController(port: _ScopePort());
    addTearDown(scope.dispose);
    await tester.pumpWidget(
      _shell(
        initial: ShellDestination.search,
        scope: scope,
        searchData: _SearchData(),
        onHandoff: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'news');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-item-live-b')));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Search navigation');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'search live-b');
  });

  testWidgets('selected source falls back to All before the next catalog', (
    tester,
  ) async {
    final port = _ScopePort(scope: const LibraryScope.source('source-b'));
    final scope = CatalogScopeController(port: port);
    addTearDown(scope.dispose);
    await tester.pumpWidget(
      _shell(
        initial: ShellDestination.search,
        scope: scope,
        browseData: const _BrowseData(),
        searchData: _SearchData(),
      ),
    );
    await tester.pumpAndSettle();
    port.sources = const [_sourceEntryA];

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(40, 162));
    await tester.pumpAndSettle();

    expect(scope.scope.isAll, isTrue);
    expect(port.savedScopes.last.isAll, isTrue);
  });
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

Widget _shell({
  required ShellDestination initial,
  required CatalogScopeController scope,
  BasicBrowseData? browseData,
  LocalSearchData? searchData,
  PersistedSource? browseSource,
  ValueChanged<PlaybackHandoff>? onHandoff,
  FutureOr<PersistedSource?> Function(String sourceId)? playbackResolver,
  CredentialStore? credentialStore,
  PlaybackTransportFactory? transportFactory,
}) => MaterialApp(
  home: WabbitShell(
    fixtureMode: HomeFixtureMode.noPersonalization,
    initialDestination: initial,
    catalogScopeController: scope,
    browseData: browseData,
    scopedBrowseData: const _ScopedData(),
    localSearchData: searchData,
    browseSource: browseSource,
    onPlaybackHandoff: onHandoff,
    playbackSourceResolver: playbackResolver,
    credentialStore: credentialStore,
    playbackTransportFactory: transportFactory,
  ),
);

const _sourceA = PersistedSource(
  id: 'source-a',
  name: 'Stale A',
  credentialKey: 'stale-key',
  counts: {},
);
const _sourceB = PersistedSource(
  id: 'source-b',
  name: 'Backup',
  credentialKey: 'backup-key',
  counts: {},
);
const _sourceEntryA = SourceRosterEntry(
  id: 'source-a',
  name: 'Primary',
  kind: 'xtream',
  enabled: true,
  status: 'ready',
  counts: {SourceMediaKind.live: 1},
);
const _sourceEntryB = SourceRosterEntry(
  id: 'source-b',
  name: 'Backup',
  kind: 'xtream',
  enabled: true,
  status: 'ready',
  counts: {SourceMediaKind.live: 1},
);

class _ScopePort implements CatalogScopePort {
  _ScopePort({this.scope = const LibraryScope.all()});

  LibraryScope scope;
  List<SourceRosterEntry> sources = const [_sourceEntryA, _sourceEntryB];
  final savedScopes = <LibraryScope>[];

  @override
  Future<LibraryScope> loadCatalogScope() async => scope;

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async =>
      sourceId == 'source-a'
      ? _sourceA
      : sourceId == 'source-b'
      ? _sourceB
      : null;

  @override
  Future<List<SourceRosterEntry>> loadSourceRoster() async => sources;

  @override
  Future<LibraryScope> saveCatalogScope(LibraryScope requested) async {
    scope = requested;
    savedScopes.add(requested);
    return requested;
  }
}

class _BrowseData implements BasicBrowseData {
  const _BrowseData();

  @override
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  }) async => const [];

  @override
  Future<BrowsePage> browsePage({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit = 100,
  }) async => const BrowsePage(items: [], nextCursor: null);
}

class _ScopedData implements ScopedBrowseData {
  const _ScopedData();

  @override
  Future<LibraryPage> browseLibraryPage({
    required LibraryScope scope,
    required SourceMediaKind kind,
    BrowseCursor? cursor,
    int limit = 100,
  }) async => const LibraryPage(items: [], nextCursor: null);

  @override
  Future<int> countLibraryItems({
    required LibraryScope scope,
    required SourceMediaKind kind,
  }) async => 0;
}

class _SearchData implements LocalSearchData {
  _SearchData({this.sourceId = 'source-b'});
  final String sourceId;
  LibraryScope? lastScope;

  LibraryCatalogItem get _item => LibraryCatalogItem(
    libraryItemId: 'live-b',
    catalogItemId: 'catalog-b',
    sourceId: sourceId,
    sourceDisplayName: 'Backup',
    kind: SourceMediaKind.live,
    title: 'News at Nine',
    artworkLocator: null,
    playbackRef: '{"providerId":"42","kind":"live","extension":"ts"}',
  );

  @override
  Future<int> count({
    required String query,
    required LibraryScope scope,
  }) async {
    lastScope = scope;
    return query.isEmpty ? 0 : 1;
  }

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;

  @override
  Future<LibraryPage> searchPage({
    required String query,
    required LibraryScope scope,
    BrowseCursor? cursor,
    int limit = 100,
  }) async {
    lastScope = scope;
    return LibraryPage(
      items: query.isEmpty ? const [] : [_item],
      nextCursor: null,
    );
  }
}

class _Credentials implements CredentialStore {
  const _Credentials();

  @override
  Future<void> delete(String key) async {}

  @override
  Future<StoredCredential?> read(String key) async => key == 'backup-key'
      ? const StoredCredential(
          username: 'user',
          password: 'secret',
          serverUrl: 'https://selected.example',
        )
      : null;

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}

class _Transport implements PlaybackTransport {
  final StreamController<PlaybackTransportState> _states =
      StreamController<PlaybackTransportState>.broadcast();
  Uri? openedUri;

  @override
  Stream<PlaybackTransportState> get states => _states.stream;

  @override
  Widget buildVideo() => const SizedBox.expand();

  @override
  Future<void> dispose() async => _states.close();

  @override
  Future<void> open(
    Uri uri, {
    Map<String, String> httpHeaders = const {},
  }) async {
    openedUri = uri;
    _states.add(const PlaybackTransportState(hasVideo: true));
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
