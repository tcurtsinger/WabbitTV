// THESIS: Wabbit TV is a calm, local-first launch board for a user's own IPTV library.
// OWN-WORLD: Quiet Broadcast uses graphite surfaces, warm white typography, restrained
// signal-amber focus, and color only in clearly synthetic fixture art.
// STORY: A persistent rail reaches a unified Home whose first pinned shelf reveals context
// without becoming a promotional hero.
// FIRST VIEWPORT: A quiet header, focused pinned shelf, then personal shelves—never a
// provider storefront.
// FORM: Near-square cards, 8 px rhythm, crisp 2 px amber focus, and short functional motion.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app_shell.dart';
import 'src/features/browse/basic_browse_screen.dart';
import 'src/features/browse/catalog_scope_controller.dart';
import 'src/features/search/local_search_screen.dart';
import 'src/features/sources/source_catalog_database.dart';
import 'src/features/sources/source_editor.dart';
import 'src/home_fixture_mode.dart';
import 'src/features/sources/source_setup_controller.dart';
import 'src/features/sources/source_models.dart';
import 'src/features/sources/credential_store.dart';
import 'src/features/playback/player_screen.dart';
import 'src/spikes/phase0/catalog_scale_probe.dart';
import 'src/spikes/phase0/sqlite_fts5_probe.dart';
import 'src/spikes/phase1/basic_browse_fixture.dart';

const _sqliteProbeEnabled = bool.fromEnvironment('WABBIT_SQLITE_PROBE');
const _catalogScaleProbeEnabled = bool.fromEnvironment(
  'WABBIT_CATALOG_SCALE_PROBE',
);
const _basicBrowseFixture = String.fromEnvironment('WABBIT_BROWSE_FIXTURE');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
  }
  if (_catalogScaleProbeEnabled) {
    unawaited(_emitCatalogScaleProbeDiagnostic());
  } else if (_sqliteProbeEnabled) {
    unawaited(_emitSqliteProbeDiagnostic());
  }
  final fixtureKind = SourceMediaKind.values
      .where((kind) => kind.name == _basicBrowseFixture)
      .firstOrNull;
  runApp(
    WabbitApp(
      fixtureMode: fixtureKind == null
          ? HomeFixtureMode.fromEnvironment()
          : HomeFixtureMode.noPersonalization,
      browseSource: fixtureKind == null ? null : BasicBrowseFixtureData.source,
      browseData: fixtureKind == null ? null : const BasicBrowseFixtureData(),
      initialDestination: fixtureKind == null
          ? null
          : switch (fixtureKind) {
              SourceMediaKind.live => ShellDestination.live,
              SourceMediaKind.movies => ShellDestination.movies,
              SourceMediaKind.series => ShellDestination.series,
            },
    ),
  );
}

Future<void> _emitCatalogScaleProbeDiagnostic() async {
  try {
    final result = await CatalogScaleProbe.run();
    debugPrint(
      'WABBIT_CATALOG_SCALE_PROBE: '
      '${jsonEncode({"status": "ok", ...result.toJson()})}',
    );
  } catch (_) {
    debugPrint(
      'WABBIT_CATALOG_SCALE_PROBE: '
      '${jsonEncode({"status": "error", "error": "catalog-scale-probe-failed"})}',
    );
  }
}

Future<void> _emitSqliteProbeDiagnostic() async {
  try {
    final result = await SqliteFts5Probe.run();
    debugPrint(
      'WABBIT_SQLITE_PROBE: ${jsonEncode({"status": "ok", ...result.toJson()})}',
    );
  } catch (error) {
    debugPrint(
      'WABBIT_SQLITE_PROBE: ${jsonEncode({"status": "error", "error": "$error"})}',
    );
  }
}

class WabbitApp extends StatelessWidget {
  const WabbitApp({
    super.key,
    this.fixtureMode = HomeFixtureMode.runtime,
    this.sourceController,
    this.browseSource,
    this.browseData,
    this.scopedBrowseData,
    this.catalogScopeController,
    this.localSearchData,
    this.playbackSourceResolver,
    this.initialDestination,
    this.credentialStore,
    this.playbackTransportFactory,
    this.fullscreenPort,
    this.m3uFilePicker,
  });

  final HomeFixtureMode fixtureMode;
  final SourceSetupController? sourceController;
  final PersistedSource? browseSource;
  final BasicBrowseData? browseData;
  final ScopedBrowseData? scopedBrowseData;
  final CatalogScopeController? catalogScopeController;
  final LocalSearchData? localSearchData;
  final FutureOr<PersistedSource?> Function(String sourceId)?
  playbackSourceResolver;
  final ShellDestination? initialDestination;
  final CredentialStore? credentialStore;
  final PlaybackTransportFactory? playbackTransportFactory;
  final FullscreenPort? fullscreenPort;
  final M3uFilePicker? m3uFilePicker;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wabbit TV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF111212),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFFB347),
          onPrimary: Color(0xFF17120A),
          surface: Color(0xFF191A1A),
          onSurface: Color(0xFFF4F0E7),
          secondary: Color(0xFFBEBAB1),
        ),
        fontFamily: 'Segoe UI',
      ),
      home: WabbitShell(
        fixtureMode: fixtureMode,
        sourceController: sourceController,
        browseSource: browseSource,
        browseData: browseData,
        scopedBrowseData: scopedBrowseData,
        catalogScopeController: catalogScopeController,
        localSearchData: localSearchData,
        playbackSourceResolver: playbackSourceResolver,
        initialDestination: initialDestination,
        credentialStore: credentialStore,
        playbackTransportFactory: playbackTransportFactory,
        fullscreenPort: fullscreenPort,
        m3uFilePicker: m3uFilePicker,
      ),
    );
  }
}
