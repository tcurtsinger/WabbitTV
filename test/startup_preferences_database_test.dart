import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/startup_models.dart';

void main() {
  test('startup settings strictly decode and default Home', () async {
    final fixture = await _StartupFixture.create();
    addTearDown(fixture.dispose);

    expect(
      (await fixture.database.loadStartupPreference()).target,
      StartupTarget.home,
    );
    expect(
      (await fixture.database.resolveStartupDestination()).destination,
      StartupDestinationSlug.home,
    );

    await fixture.database.saveStartupTarget(StartupTarget.previousScreen);
    await fixture.database.savePreviousDestination(
      StartupDestinationSlug.library,
    );
    var preference = await fixture.database.loadStartupPreference();
    expect(preference.target, StartupTarget.previousScreen);
    expect(preference.previousDestination, StartupDestinationSlug.library);
    expect(
      (await fixture.database.resolveStartupDestination()).destination,
      StartupDestinationSlug.library,
    );

    final raw = sqlite3.open(fixture.path);
    raw.execute(
      "UPDATE app_settings SET value = 'Previous Screen' WHERE key = 'startup_target'",
    );
    raw.execute(
      "UPDATE app_settings SET value = '/library?token=secret' WHERE key = 'previous_destination'",
    );
    raw.close();
    preference = await fixture.database.loadStartupPreference();
    expect(preference.target, StartupTarget.home);
    expect(preference.previousDestination, isNull);
    expect(
      (await fixture.database.resolveStartupDestination()).destination,
      StartupDestinationSlug.home,
    );
  });

  test(
    'last channel stores only an exact Live identity and resolves eligibility',
    () async {
      final fixture = await _StartupFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed('live', SourceMediaKind.live, category: true);
      await fixture.seed('movie', SourceMediaKind.movies);

      expect(
        await fixture.database.saveLastLiveLibraryItem('movie:movies:item'),
        isFalse,
      );
      expect(
        await fixture.database.saveLastLiveLibraryItem('missing:live:item'),
        isFalse,
      );
      expect(
        await fixture.database.saveLastLiveLibraryItem('live:live:item'),
        isTrue,
      );
      await fixture.database.saveStartupTarget(StartupTarget.lastChannel);

      var resolution = await fixture.database.resolveStartupDestination();
      expect(resolution.destination, StartupDestinationSlug.live);
      expect(resolution.lastLiveItem?.libraryItemId, 'live:live:item');
      expect(resolution.lastLiveItem?.sourceId, 'live');

      final raw = sqlite3.open(fixture.path);
      raw.execute(
        "UPDATE source_groups SET hidden = 1 WHERE source_id = 'live'",
      );
      raw.close();
      resolution = await fixture.database.resolveStartupDestination();
      expect(resolution.destination, StartupDestinationSlug.home);
      expect(resolution.lastLiveItem, isNull);

      final restore = sqlite3.open(fixture.path);
      restore.execute(
        "UPDATE source_groups SET hidden = 0 WHERE source_id = 'live'",
      );
      restore.execute(
        "UPDATE sources SET last_error = 'unreachable' WHERE id = 'live'",
      );
      restore.close();
      resolution = await fixture.database.resolveStartupDestination();
      expect(resolution.opensLastChannel, isTrue);

      await fixture.database.setSourceEnabled('live', false);
      expect(
        (await fixture.database.resolveStartupDestination()).destination,
        StartupDestinationSlug.home,
      );
      await fixture.database.setSourceEnabled('live', true);
      expect(
        (await fixture.database.resolveStartupDestination()).opensLastChannel,
        isTrue,
      );
    },
  );

  test('source removal clears the exact last-channel pointer and no secret setting is written', () async {
    final fixture = await _StartupFixture.create();
    addTearDown(fixture.dispose);
    const playbackSecret =
        'https://provider.invalid/live/user/password/stream.ts?token=secret';
    await fixture.seed(
      'live',
      SourceMediaKind.live,
      playbackRef: playbackSecret,
    );
    await fixture.database.saveLastLiveLibraryItem('live:live:item');
    await fixture.database.saveStartupTarget(StartupTarget.lastChannel);
    await fixture.database.savePreviousDestination(StartupDestinationSlug.live);

    var raw = sqlite3.open(fixture.path);
    var settings = raw
        .select('SELECT key, value FROM app_settings')
        .map((row) => '${row['key']}=${row['value']}')
        .join('\n');
    raw.close();
    expect(settings, isNot(contains(playbackSecret)));
    expect(settings, isNot(contains('password')));
    expect(settings, isNot(contains('token=')));

    await fixture.database.removeSource('live');
    final preference = await fixture.database.loadStartupPreference();
    expect(preference.lastLiveLibraryItemId, isNull);
    expect(
      (await fixture.database.resolveStartupDestination()).destination,
      StartupDestinationSlug.home,
    );
    raw = sqlite3.open(fixture.path);
    settings = raw
        .select('SELECT key, value FROM app_settings')
        .map((row) => '${row['key']}=${row['value']}')
        .join('\n');
    raw.close();
    expect(settings, isNot(contains('live:live:item')));
  });
}

class _StartupFixture {
  _StartupFixture(this.directory)
    : path = '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      database = SourceCatalogDatabase(
        databasePath:
            '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      );

  final Directory directory;
  final String path;
  final SourceCatalogDatabase database;

  static Future<_StartupFixture> create() async =>
      _StartupFixture(await Directory.systemTemp.createTemp('wabbit-startup-'));

  Future<void> seed(
    String id,
    SourceMediaKind kind, {
    bool category = false,
    String playbackRef = 'safe-ref',
  }) => database.commitInitialSource(
    SourceDefinition(
      id: id,
      name: id,
      serverUrl: 'https://provider.invalid',
      username: 'fixture-user',
      password: 'fixture-password',
      credentialKey: '$id-key',
    ),
    [
      ImportedStage(
        kind: kind,
        categories: category
            ? const [ImportedCategory(providerKey: 'group', name: 'Group')]
            : const [],
        items: [
          ImportedCatalogItem(
            providerKey: 'item',
            title: '$id item',
            categoryKey: category ? 'group' : null,
            playbackRef: playbackRef,
          ),
        ],
      ),
    ],
  );

  Future<void> dispose() => directory.delete(recursive: true);
}
