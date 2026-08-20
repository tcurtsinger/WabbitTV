import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/playback/playback_manager.dart';
import 'package:wabbit_tv/src/features/playback/playback_runtime_adapters.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  test('source resolver assembles exact Xtream target just in time', () async {
    const source = PersistedSource(
      id: 'source',
      name: 'Source',
      credentialKey: 'credential-key',
      counts: {},
    );
    const secret = StoredCredential(
      username: 'user',
      password: 'password',
      serverUrl: 'https://provider.example/base',
    );
    final resolver = SourcePlaybackTargetResolver(
      sourceResolver: (_) => source,
      credentialStore: const _Credentials(secret),
    );

    final target = await resolver.resolve(
      const MoviePlaybackHandoff(
        sourceId: 'source',
        title: 'Movie',
        providerItemId: '42',
        extension: 'mkv',
      ),
    );

    expect(target.uri.path, '/base/movie/user/password/42.mkv');
    expect(target.toString(), 'PlaybackResolvedTarget(redacted)');
    expect(target.toString(), isNot(contains('password')));
  });

  test('missing secret fails at the redacted credential boundary', () async {
    final resolver = SourcePlaybackTargetResolver(
      sourceResolver: (_) => const PersistedSource(
        id: 'source',
        name: 'Source',
        credentialKey: 'credential-key',
        counts: {},
      ),
      credentialStore: const _Credentials(null),
    );

    await expectLater(
      resolver.resolve(
        const LivePlaybackHandoff(
          sourceId: 'source',
          title: 'Live',
          providerItemId: '1',
          extension: 'ts',
        ),
      ),
      throwsA(
        isA<PlaybackResolutionException>().having(
          (value) => value.failure,
          'failure',
          PlaybackSessionFailure.credentialsUnavailable,
        ),
      ),
    );
  });

  test('database ports map allowance and exact watched progress', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.database.commitInitialSource(
      const SourceDefinition(
        id: 'source',
        name: 'Source',
        serverUrl: 'https://provider.example',
        username: 'user',
        password: 'private',
        credentialKey: 'key',
      ),
      const [
        ImportedStage(
          kind: SourceMediaKind.movies,
          categories: [],
          items: [
            ImportedCatalogItem(
              providerKey: 'movie',
              title: 'Movie',
              categoryKey: null,
              playbackRef:
                  '{"providerId":"movie","kind":"movies","extension":"mp4"}',
            ),
          ],
        ),
      ],
    );
    final item = (await fixture.database.browseLibraryPage(
      scope: const LibraryScope.all(),
      kind: SourceMediaKind.movies,
    )).items.single;
    final identity = PlaybackProgressIdentity(
      libraryItemId: item.libraryItemId,
      mediaKey: 'movie',
    );
    final progress = DatabasePlaybackProgressPort(fixture.database);
    final checkpoint = PlaybackCheckpoint(
      position: const Duration(seconds: 90),
      duration: const Duration(minutes: 10),
      watched: const Duration(seconds: 35),
      updatedAt: DateTime.utc(2026, 8, 19),
    );

    expect(await progress.save(identity, checkpoint), isTrue);
    final loaded = await progress.load(identity);
    expect(loaded?.position, checkpoint.position);
    expect(loaded?.watched, checkpoint.watched);
    expect(await progress.clear(identity), isTrue);
    expect(await progress.load(identity), isNull);

    await fixture.database.setSourceConnectionLimitOverride(
      sourceId: 'source',
      overrideLimit: 2,
    );
    expect(
      await DatabasePlaybackAdmissionPort(fixture.database)
          .effectiveLimitForSource('source'),
      2,
    );
    expect(
      await DatabasePlaybackAdmissionPort(fixture.database)
          .effectiveLimitForSource('missing'),
      1,
    );

    final current = playbackHandoffForLibrary(item);
    expect(
      await DatabasePlaybackExactVariantPort(fixture.database)
          .loadExactVariants(current),
      isEmpty,
    );
  });
}

class _Credentials implements CredentialStore {
  const _Credentials(this.value);
  final StoredCredential? value;
  @override
  Future<void> delete(String key) async {}
  @override
  Future<StoredCredential?> read(String key) async => value;
  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}

class _Fixture {
  _Fixture(this.directory, this.database);
  final Directory directory;
  final SourceCatalogDatabase database;
  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'wabbit-playback-adapters-',
    );
    return _Fixture(
      directory,
      SourceCatalogDatabase(
        databasePath:
            '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      ),
    );
  }

  Future<void> dispose() => directory.delete(recursive: true);
}
