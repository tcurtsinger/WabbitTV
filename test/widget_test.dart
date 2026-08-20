import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wabbit_tv/main.dart';
import 'package:wabbit_tv/src/app_shell.dart';
import 'package:wabbit_tv/src/features/browse/catalog_scope_controller.dart';
import 'package:wabbit_tv/src/features/home/home_screen.dart';
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
    'remote Menu opens the rail when content has no contextual Menu action',
    (tester) async {
      await tester.pumpWidget(
        const WabbitApp(fixtureMode: HomeFixtureMode.noPersonalization),
      );
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus?.debugLabel, 'home first item');

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Home navigation');
      expect(find.text('Wabbit TV'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Live navigation');
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Live navigation');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus?.debugLabel, 'home first item');
    },
  );

  for (final textScale in const [1.5, 2.0]) {
    testWidgets(
      'expanded rail keeps complete labels reachable at ${textScale}x text in short height',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(600, 360));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const WabbitShell(
              fixtureMode: HomeFixtureMode.noPersonalization,
              initialDestination: ShellDestination.home,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        for (final destination in ShellDestination.values) {
          final label = find.descendant(
            of: find.byKey(ValueKey('shell-destination-${destination.name}')),
            matching: find.text(destination.label),
          );
          expect(label, findsOneWidget);
          expect(tester.widget<Text>(label).overflow, isNull);
        }

        for (var index = 1; index < ShellDestination.values.length; index++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }

        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'Settings navigation',
        );
        final settingsRect = tester.getRect(
          find.byKey(const ValueKey('shell-destination-settings')),
        );
        expect(settingsRect.top, greaterThanOrEqualTo(0));
        expect(settingsRect.bottom, lessThanOrEqualTo(360));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'rail exposes one semantic name, selected location, cursor, and utility group',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const WabbitApp(fixtureMode: HomeFixtureMode.populated),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('rail-selected-location-marker')),
        findsOneWidget,
      );
      final collapsedMarkerRect = tester.getRect(
        find.byKey(const ValueKey('rail-selected-location-marker')),
      );
      final collapsedIconRect = tester.getRect(
        find.byKey(const ValueKey('shell-destination-icon-home')),
      );
      expect(collapsedMarkerRect.width, 2);
      expect(collapsedMarkerRect.right, lessThan(collapsedIconRect.left));
      final collapsedHome = tester.widget<FocusableActionDetector>(
        find.byKey(const ValueKey('shell-destination-home')),
      );
      expect(collapsedHome.mouseCursor, SystemMouseCursors.click);
      expect(collapsedHome.onShowHoverHighlight, isNotNull);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1000, 700));
      await mouse.moveTo(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Wabbit TV'), findsOneWidget);
      final expandedMarkerRect = tester.getRect(
        find.byKey(const ValueKey('rail-selected-location-marker')),
      );
      final expandedIconRect = tester.getRect(
        find.byKey(const ValueKey('shell-destination-icon-home')),
      );
      expect(expandedMarkerRect.width, 2);
      expect(expandedMarkerRect.right, lessThan(expandedIconRect.left));
      await mouse.moveTo(const Offset(1000, 700));
      await tester.pump(const Duration(milliseconds: 200));
      await mouse.removePointer();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      final homeSemantics = tester
          .getSemantics(find.byKey(const ValueKey('shell-destination-home')))
          .getSemanticsData();
      expect(homeSemantics.label, 'Home');
      expect(homeSemantics.flagsCollection.isButton, isTrue);
      expect(homeSemantics.flagsCollection.isSelected.toBoolOrNull(), isTrue);
      expect(homeSemantics.hasAction(SemanticsAction.tap), isTrue);

      final separatorRect = tester.getRect(
        find.byKey(const ValueKey('rail-settings-separator')),
      );
      final libraryRect = tester.getRect(
        find.byKey(const ValueKey('shell-destination-library')),
      );
      final settingsRect = tester.getRect(
        find.byKey(const ValueKey('shell-destination-settings')),
      );
      expect(separatorRect.top, greaterThan(libraryRect.bottom));
      expect(settingsRect.top, greaterThan(separatorRect.top));
      expect(settingsRect.bottom, lessThanOrEqualTo(713));

      final liveSemantics = tester.getSemantics(
        find.byKey(const ValueKey('shell-destination-live')),
      );
      expect(
        liveSemantics.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );
      tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
        liveSemantics.id,
        SemanticsAction.tap,
      );
      await tester.pumpAndSettle();
      expect(find.text('No source ready'), findsOneWidget);
      semantics.dispose();
    },
  );

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
      final home = HomeController(
        data: const _FixedHomeData(sourcePresent: true),
      );
      addTearDown(scope.dispose);
      addTearDown(home.dispose);
      await tester.pumpWidget(
        WabbitApp(
          fixtureMode: HomeFixtureMode.runtime,
          sourceController: controller,
          catalogScopeController: scope,
          homeController: home,
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
    final scope = CatalogScopeController(port: const _ImmediateScopePort());
    final home = HomeController(
      data: const _FixedHomeData(sourcePresent: false),
    );
    addTearDown(scope.dispose);
    addTearDown(home.dispose);
    await tester.pumpWidget(
      WabbitApp(
        fixtureMode: HomeFixtureMode.runtime,
        sourceController: controller,
        catalogScopeController: scope,
        homeController: home,
      ),
    );
    await tester.pumpAndSettle();
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

class _FixedHomeData implements HomeData {
  const _FixedHomeData({required this.sourcePresent});

  final bool sourcePresent;

  @override
  Future<bool> hasSources() async => sourcePresent;

  @override
  Future<List<RecentlyWatchedItem>> loadRecentlyWatched({
    required int limit,
  }) async => const [];

  @override
  Future<List<HomePersonalShelf>> loadPinnedShelves({
    required int shelfLimit,
    required int itemLimit,
  }) async => const [];

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;
}
