import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wabbit_tv/main.dart';
import 'package:wabbit_tv/src/features/browse/catalog_scope_controller.dart';
import 'package:wabbit_tv/src/home_fixture_mode.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_controller.dart';

void main() {
  testWidgets('shows the focused personal shelf fixture', (tester) async {
    await tester.pumpWidget(
      const WabbitApp(fixtureMode: HomeFixtureMode.populated),
    );

    expect(find.text('Home'), findsAtLeastNWidgets(1));
    expect(find.text('Living Room'), findsOneWidget);
    expect(find.text('Northbound'), findsAtLeastNWidgets(1));
  });

  testWidgets('Home keeps visible space at the Windows reference viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const WabbitApp(fixtureMode: HomeFixtureMode.populated),
    );
    await tester.pumpAndSettle();

    final shelf = tester.getRect(
      find.byKey(const ValueKey('home-focused-shelf')),
    );
    final card = tester.getRect(
      find.byKey(const ValueKey('fixture-card-Northbound')),
    );

    expect(shelf.width, greaterThan(0));
    expect(card.width, greaterThan(0));
    expect(card.left, greaterThanOrEqualTo(72));
    expect(card.right, lessThanOrEqualTo(1265));
    expect(card.top, greaterThanOrEqualTo(0));
    expect(card.bottom, lessThanOrEqualTo(713));
  });

  testWidgets('Home remains visible in a narrow window', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const WabbitApp(fixtureMode: HomeFixtureMode.populated),
    );
    await tester.pumpAndSettle();

    final shelf = tester.getRect(
      find.byKey(const ValueKey('home-focused-shelf')),
    );
    final card = tester.getRect(
      find.byKey(const ValueKey('fixture-card-Northbound')),
    );

    expect(shelf.width, greaterThan(0));
    expect(card.width, greaterThan(0));
    expect(card.left, greaterThanOrEqualTo(72));
    expect(card.right, lessThanOrEqualTo(480));
  });

  testWidgets('Escape expands rail and restores the card focus', (
    tester,
  ) async {
    await tester.pumpWidget(
      const WabbitApp(fixtureMode: HomeFixtureMode.populated),
    );
    await tester.pumpAndSettle();

    expect(find.text('Wabbit TV'), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'home first item');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Wabbit TV'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Home navigation');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Wabbit TV'), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'home first item');
  });
  testWidgets(
    'catalog destination restores its no-source action focus after rail close',
    (tester) async {
      await tester.pumpWidget(
        const WabbitApp(fixtureMode: HomeFixtureMode.populated),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Home navigation');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Live navigation');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('No source ready'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'home first item');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Live navigation');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Wabbit TV'), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'home first item');
    },
  );
  testWidgets('shows direct entries when sources lack personalization', (
    tester,
  ) async {
    await tester.pumpWidget(
      const WabbitApp(fixtureMode: HomeFixtureMode.noPersonalization),
    );

    expect(find.text('Start with what you want to watch'), findsOneWidget);
    expect(find.text('Live'), findsAtLeastNWidgets(1));
    expect(find.text('Movies'), findsAtLeastNWidgets(1));
    expect(find.text('Series'), findsAtLeastNWidgets(1));
    expect(
      find.text('Favorite something or create a group to make Home personal.'),
      findsOneWidget,
    );
    expect(find.text('All sources · local fixture'), findsOneWidget);
    expect(find.textContaining('This local source fixture'), findsOneWidget);
  });
  testWidgets('direct entries traverse horizontally before opening the rail', (
    tester,
  ) async {
    await tester.pumpWidget(
      const WabbitApp(fixtureMode: HomeFixtureMode.noPersonalization),
    );
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'home first item');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'no-personalization movies',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'no-personalization series',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'no-personalization movies',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'home first item');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Home navigation');
  });
  testWidgets(
    'fixture-injected controller is not initialized or disposed by the shell',
    (tester) async {
      final controller = _TrackingController();
      await tester.pumpWidget(
        WabbitApp(
          fixtureMode: HomeFixtureMode.populated,
          sourceController: controller,
        ),
      );
      await tester.pump();
      expect(controller.initializations, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(controller.disposals, 0);
      controller.dispose();
    },
  );

  testWidgets(
    'runtime injected controller initializes Home from no source to no personalization',
    (tester) async {
      final controller = _TrackingController(readyOnInitialize: true);
      final scope = CatalogScopeController(port: const _ImmediateScopePort());
      addTearDown(scope.dispose);
      await tester.pumpWidget(
        WabbitApp(
          fixtureMode: HomeFixtureMode.runtime,
          sourceController: controller,
          catalogScopeController: scope,
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.sawNoSourceBeforeInitialize, isTrue);
      expect(controller.initializations, 1);
      expect(find.text('Start with what you want to watch'), findsOneWidget);
      expect(find.text('All sources'), findsOneWidget);
      expect(
        find.text(
          'Your library has no Favorites, groups, or watch history yet.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('fixture'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('shows the content-neutral no-source state', (tester) async {
    await tester.pumpWidget(
      const WabbitApp(fixtureMode: HomeFixtureMode.noSources),
    );

    expect(find.text('Add your first source'), findsOneWidget);
    expect(find.text('Add source'), findsOneWidget);
  });

  testWidgets('runtime rail does not claim fixture content', (tester) async {
    final controller = _TrackingController();
    await tester.pumpWidget(
      WabbitApp(
        fixtureMode: HomeFixtureMode.runtime,
        sourceController: controller,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Local fixture preview'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

class _TrackingController extends SourceSetupController {
  _TrackingController({this.readyOnInitialize = false})
    : super(
        productionService: SourceSetupService(
          database: const SourceCatalogDatabase(databasePath: ':memory:'),
        ),
        credentialStore: _NoopCredentials(),
      );

  final bool readyOnInitialize;
  int initializations = 0;
  int disposals = 0;
  bool sawNoSourceBeforeInitialize = false;

  @override
  Future<void> initialize() async {
    initializations++;
    sawNoSourceBeforeInitialize = persisted == null;
    if (readyOnInitialize) {
      persisted = const PersistedSource(
        id: 'fixture',
        name: 'Fixture',
        credentialKey: 'fixture-key',
        counts: {
          SourceMediaKind.live: 1,
          SourceMediaKind.movies: 1,
          SourceMediaKind.series: 1,
        },
      );
      ready = persisted!.ready;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

class _NoopCredentials implements CredentialStore {
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

class _ImmediateScopePort implements CatalogScopePort {
  const _ImmediateScopePort();

  @override
  Future<LibraryScope> loadCatalogScope() async => const LibraryScope.all();

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;

  @override
  Future<List<SourceRosterEntry>> loadSourceRoster() async => const [];

  @override
  Future<LibraryScope> saveCatalogScope(LibraryScope scope) async => scope;
}
