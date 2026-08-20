import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  test(
    'custom groups validate names and retain explicit directory order',
    () async {
      final fixture = await _OrganizationFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed();

      expect(
        (await fixture.database.createCustomGroup('   ')).outcome,
        PersonalLibraryMutationOutcome.invalidName,
      );
      final first = await fixture.database.createCustomGroup('Weekend');
      final second = await fixture.database.createCustomGroup('Family Picks');
      final third = await fixture.database.createCustomGroup('Documentaries');
      expect(first.outcome, PersonalLibraryMutationOutcome.changed);
      expect(
        (await fixture.database.createCustomGroup(' weekend ')).outcome,
        PersonalLibraryMutationOutcome.duplicateName,
      );

      final firstId = first.collection!.collectionId!;
      final secondId = second.collection!.collectionId!;
      final thirdId = third.collection!.collectionId!;
      expect(
        (await fixture.database.loadPersonalLibraryDirectory())
            .where((entry) => entry.collectionId != null)
            .map((entry) => entry.collectionId),
        [firstId, secondId, thirdId],
      );

      expect(
        (await fixture.database.moveCustomGroup(
          customGroupId: thirdId,
          direction: PersonalLibraryMoveDirection.up,
        )).outcome,
        PersonalLibraryMutationOutcome.changed,
      );
      expect(
        (await fixture.database.renameCustomGroup(
          customGroupId: thirdId,
          name: 'Documentary Night',
        )).outcome,
        PersonalLibraryMutationOutcome.changed,
      );
      final reordered = await fixture.database.loadPersonalLibraryDirectory();
      expect(
        reordered
            .where((entry) => entry.collectionId != null)
            .map((entry) => entry.name),
        ['Weekend', 'Documentary Night', 'Family Picks'],
      );

      expect(
        (await fixture.database.deleteCustomGroup(secondId)).outcome,
        PersonalLibraryMutationOutcome.changed,
      );
      expect(
        (await fixture.database.deleteCustomGroup(secondId)).outcome,
        PersonalLibraryMutationOutcome.missingGroup,
      );
      expect(
        (await fixture.database.loadPersonalLibraryDirectory())
            .where((entry) => entry.collectionId != null)
            .map((entry) => entry.directoryOrdinal),
        [0, 1],
      );
    },
  );

  test(
    'one organizer save atomically replaces Favorite and several groups',
    () async {
      final fixture = await _OrganizationFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed();
      final a = (await fixture.database.createCustomGroup('A'))
          .collection!
          .collectionId!;
      final b = (await fixture.database.createCustomGroup('B'))
          .collection!
          .collectionId!;
      final c = (await fixture.database.createCustomGroup('C'))
          .collection!
          .collectionId!;

      expect(
        (await fixture.database.saveItemOrganization(
          libraryItemId: 'source:movies:movie',
          favorite: true,
          customGroupIds: {a, b},
        )).outcome,
        PersonalLibraryMutationOutcome.changed,
      );
      var state = await fixture.database.loadItemOrganization(
        'source:movies:movie',
      );
      expect(state!.isFavorite, isTrue);
      expect(
        state.groups
            .where((group) => group.selected)
            .map((group) => group.groupId),
        [a, b],
      );
      expect(
        (await fixture.database.saveItemOrganization(
          libraryItemId: 'source:movies:movie',
          favorite: true,
          customGroupIds: {a, b},
        )).outcome,
        PersonalLibraryMutationOutcome.unchanged,
      );

      expect(
        (await fixture.database.saveItemOrganization(
          libraryItemId: 'source:movies:movie',
          favorite: false,
          customGroupIds: {b, c},
        )).outcome,
        PersonalLibraryMutationOutcome.changed,
      );
      state = await fixture.database.loadItemOrganization(
        'source:movies:movie',
      );
      expect(state!.isFavorite, isFalse);
      expect(
        state.groups
            .where((group) => group.selected)
            .map((group) => group.groupId),
        [b, c],
      );

      final before = sqlite3.open(fixture.path);
      final beforeRows = before.select(
        '''SELECT custom_group_id FROM custom_group_items
         WHERE library_item_id = ? ORDER BY custom_group_id''',
        ['source:movies:movie'],
      );
      before.close();
      expect(
        (await fixture.database.saveItemOrganization(
          libraryItemId: 'source:movies:movie',
          favorite: true,
          customGroupIds: {b, 'missing'},
        )).outcome,
        PersonalLibraryMutationOutcome.missingGroup,
      );
      final after = sqlite3.open(fixture.path);
      expect(
        after
            .select(
              '''SELECT custom_group_id FROM custom_group_items
           WHERE library_item_id = ? ORDER BY custom_group_id''',
              ['source:movies:movie'],
            )
            .map((row) => row['custom_group_id']),
        beforeRows.map((row) => row['custom_group_id']),
      );
      expect(
        after.select('SELECT * FROM favorites WHERE library_item_id = ?', [
          'source:movies:movie',
        ]),
        isEmpty,
      );
      after.close();
    },
  );

  test(
    'mixed group item order and removal never alter source catalog data',
    () async {
      final fixture = await _OrganizationFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed();
      final group = (await fixture.database.createCustomGroup('Mixed'))
          .collection!
          .collectionId!;
      for (final item in [
        'source:live:channel',
        'source:movies:movie',
        'source:series:show',
      ]) {
        await fixture.database.saveItemOrganization(
          libraryItemId: item,
          favorite: false,
          customGroupIds: {group},
        );
      }
      expect(
        (await fixture.database.loadCustomGroupLibraryPage(
          customGroupId: group,
        )).items.map((item) => item.kind),
        [SourceMediaKind.live, SourceMediaKind.movies, SourceMediaKind.series],
      );

      await fixture.database.moveCustomGroupItem(
        customGroupId: group,
        libraryItemId: 'source:series:show',
        direction: PersonalLibraryMoveDirection.up,
      );
      expect(
        (await fixture.database.loadCustomGroupLibraryPage(
          customGroupId: group,
        )).items.map((item) => item.libraryItemId),
        ['source:live:channel', 'source:series:show', 'source:movies:movie'],
      );
      await fixture.database.removeCustomGroupItem(
        customGroupId: group,
        libraryItemId: 'source:live:channel',
      );
      final raw = sqlite3.open(fixture.path);
      expect(
        raw.select('SELECT 1 FROM catalog_items WHERE id = ?', [
          'source:live:channel',
        ]),
        isNotEmpty,
      );
      expect(
        raw.select('SELECT 1 FROM library_items WHERE id = ?', [
          'source:live:channel',
        ]),
        isNotEmpty,
      );
      raw.close();
      await fixture.database.moveCustomGroupItem(
        customGroupId: group,
        libraryItemId: 'source:movies:movie',
        direction: PersonalLibraryMoveDirection.up,
      );
      expect(
        (await fixture.database.loadCustomGroupLibraryPage(
          customGroupId: group,
        )).items.map((item) => item.libraryItemId),
        ['source:movies:movie', 'source:series:show'],
      );
    },
  );

  test('Favorites and groups share one durable pinned Home order', () async {
    final fixture = await _OrganizationFixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed();
    final a = (await fixture.database.createCustomGroup('A'))
        .collection!
        .reference;
    final b = (await fixture.database.createCustomGroup('B'))
        .collection!
        .reference;
    const favorites = PersonalLibraryCollectionRef.favorites();

    await fixture.database.setPersonalCollectionPinned(
      collection: b,
      pinned: true,
    );
    await fixture.database.setPersonalCollectionPinned(
      collection: favorites,
      pinned: true,
    );
    await fixture.database.setPersonalCollectionPinned(
      collection: a,
      pinned: true,
    );
    expect(
      (await fixture.database.loadPinnedPersonalLibraryDirectory()).map(
        (entry) => entry.reference.key,
      ),
      [b.key, favorites.key, a.key],
    );
    await fixture.database.movePinnedPersonalCollection(
      collection: a,
      direction: PersonalLibraryMoveDirection.up,
    );
    await fixture.database.setPersonalCollectionPinned(
      collection: b,
      pinned: false,
    );
    final restarted = SourceCatalogDatabase(databasePath: fixture.path);
    final pinned = await restarted.loadPinnedPersonalLibraryDirectory();
    expect(pinned.map((entry) => entry.reference.key), [a.key, favorites.key]);
    expect(pinned.map((entry) => entry.homeOrdinal), [0, 1]);
  });

  test(
    'refresh, disable, and removal preserve personal organization',
    () async {
      final fixture = await _OrganizationFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed();
      final group = (await fixture.database.createCustomGroup('Persistent'))
          .collection!;
      await fixture.database.saveItemOrganization(
        libraryItemId: 'source:movies:movie',
        favorite: true,
        customGroupIds: {group.collectionId!},
      );
      await fixture.database.setPersonalCollectionPinned(
        collection: group.reference,
        pinned: true,
      );
      final refresh = await fixture.database.beginRefresh('source');
      await fixture.database.commitRefresh(
        refresh!,
        _OrganizationFixture.stages,
      );

      final restarted = SourceCatalogDatabase(databasePath: fixture.path);
      expect(
        (await restarted.loadItemOrganization('source:movies:movie'))!
            .isFavorite,
        isTrue,
      );
      expect(
        (await restarted.loadPinnedPersonalLibraryDirectory()).single.name,
        'Persistent',
      );
      await restarted.setSourceEnabled('source', false);
      final retained = await restarted.loadCustomGroupLibraryPage(
        customGroupId: group.collectionId!,
      );
      expect(retained.items.single.libraryItemId, 'source:movies:movie');
      expect(retained.items.single.isAvailable, isFalse);
      await restarted.removeSource('source');
      final removed = await restarted.loadCustomGroupLibraryPage(
        customGroupId: group.collectionId!,
      );
      expect(removed.items.single.libraryItemId, 'source:movies:movie');
      expect(removed.items.single.isAvailable, isFalse);
      expect(
        (await restarted.loadItemOrganization('source:movies:movie'))!
            .isFavorite,
        isTrue,
      );
      expect(
        (await restarted.loadPinnedPersonalLibraryDirectory())
            .single
            .reference
            .key,
        group.reference.key,
      );
    },
  );

  test('matching titles remain separate provider item identities', () async {
    final fixture = await _OrganizationFixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed();
    await fixture.database.commitInitialSource(
      const SourceDefinition(
        id: 'other',
        name: 'Other',
        serverUrl: 'https://other.example',
        username: 'user',
        password: 'secret',
        credentialKey: 'other-key',
      ),
      const [
        ImportedStage(kind: SourceMediaKind.live, categories: [], items: []),
        ImportedStage(
          kind: SourceMediaKind.movies,
          categories: [],
          items: [
            ImportedCatalogItem(
              providerKey: 'movie',
              title: 'Movie',
              categoryKey: null,
              playbackRef: '{"providerId":"movie","kind":"movies"}',
            ),
          ],
        ),
        ImportedStage(kind: SourceMediaKind.series, categories: [], items: []),
      ],
    );
    final group = (await fixture.database.createCustomGroup('Same title'))
        .collection!
        .collectionId!;
    for (final itemId in ['source:movies:movie', 'other:movies:movie']) {
      expect(
        (await fixture.database.saveItemOrganization(
          libraryItemId: itemId,
          favorite: false,
          customGroupIds: {group},
        )).outcome,
        PersonalLibraryMutationOutcome.changed,
      );
    }
    final items = (await fixture.database.loadCustomGroupLibraryPage(
      customGroupId: group,
    )).items;
    expect(items.map((item) => item.title), ['Movie', 'Movie']);
    expect(items.map((item) => item.libraryItemId).toSet(), {
      'source:movies:movie',
      'other:movies:movie',
    });
  });

  test(
    'large group paging and one-save many-group membership stay bounded',
    () async {
      final fixture = await _OrganizationFixture.create();
      addTearDown(fixture.dispose);
      const itemCount = 5000;
      await fixture.database.commitInitialSource(
        const SourceDefinition(
          id: 'source',
          name: 'Source',
          serverUrl: 'https://provider.example',
          username: 'user',
          password: 'secret',
          credentialKey: 'source-key',
        ),
        [
          const ImportedStage(
            kind: SourceMediaKind.live,
            categories: [],
            items: [],
          ),
          ImportedStage(
            kind: SourceMediaKind.movies,
            categories: const [],
            items: List.generate(
              itemCount,
              (index) => ImportedCatalogItem(
                providerKey: 'item-$index',
                title: 'Item ${index.toString().padLeft(4, '0')}',
                categoryKey: null,
                playbackRef: '{"providerId":"item-$index","kind":"movies"}',
              ),
            ),
          ),
          const ImportedStage(
            kind: SourceMediaKind.series,
            categories: [],
            items: [],
          ),
        ],
      );
      final raw = sqlite3.open(fixture.path);
      raw.execute('BEGIN');
      final now = DateTime.utc(2026, 8, 18).toIso8601String();
      final insertGroup = raw.prepare('''INSERT INTO custom_groups
         (id, name, home_ordinal, created_at, updated_at, directory_ordinal)
         VALUES (?, ?, NULL, ?, ?, ?)''');
      for (var index = 0; index < 199; index++) {
        insertGroup.execute(['group-$index', 'Group $index', now, now, index]);
      }
      insertGroup.close();
      final insertItem = raw.prepare('''INSERT INTO custom_group_items
         (custom_group_id, library_item_id, ordinal) VALUES (?, ?, ?)''');
      for (var index = 0; index < itemCount; index++) {
        insertItem.execute(['group-0', 'source:movies:item-$index', index]);
      }
      insertItem.close();
      raw.execute('COMMIT');
      raw.close();
      expect(
        (await fixture.database.createCustomGroup('Group 200')).outcome,
        PersonalLibraryMutationOutcome.limitReached,
      );
      final directory = await fixture.database.loadPersonalLibraryDirectory(
        limit: 200,
      );
      expect(directory, hasLength(200));
      expect(
        directory.where(
          (entry) => entry.kind == PersonalLibraryDirectoryKind.customGroup,
        ),
        hasLength(199),
      );

      final first = await fixture.database.loadCustomGroupLibraryPage(
        customGroupId: 'group-0',
        limit: 100,
      );
      final second = await fixture.database.loadCustomGroupLibraryPage(
        customGroupId: 'group-0',
        cursor: first.nextCursor,
        limit: 100,
      );
      expect(first.items, hasLength(100));
      expect(second.items, hasLength(100));
      expect(
        first.items.last.libraryItemId,
        isNot(second.items.first.libraryItemId),
      );

      var heartbeats = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => heartbeats += 1,
      );
      addTearDown(timer.cancel);
      final result = await fixture.database
          .saveItemOrganization(
            libraryItemId: 'source:movies:item-0',
            favorite: true,
            customGroupIds: {
              for (var index = 0; index < 199; index++) 'group-$index',
            },
          )
          .timeout(const Duration(seconds: 30));
      timer.cancel();
      expect(result.outcome, PersonalLibraryMutationOutcome.changed);
      expect(heartbeats, greaterThan(0));
      final organized = await fixture.database.loadItemOrganization(
        'source:movies:item-0',
      );
      expect(
        organized!.groups.where((group) => group.selected),
        hasLength(199),
      );
    },
  );
}

class _OrganizationFixture {
  _OrganizationFixture(this.directory, this.path)
    : database = SourceCatalogDatabase(databasePath: path);

  final Directory directory;
  final String path;
  final SourceCatalogDatabase database;

  static const stages = [
    ImportedStage(
      kind: SourceMediaKind.live,
      categories: [],
      items: [
        ImportedCatalogItem(
          providerKey: 'channel',
          title: 'Channel',
          categoryKey: null,
          playbackRef: '{"providerId":"channel","kind":"live"}',
        ),
      ],
    ),
    ImportedStage(
      kind: SourceMediaKind.movies,
      categories: [],
      items: [
        ImportedCatalogItem(
          providerKey: 'movie',
          title: 'Movie',
          categoryKey: null,
          playbackRef: '{"providerId":"movie","kind":"movies"}',
        ),
      ],
    ),
    ImportedStage(
      kind: SourceMediaKind.series,
      categories: [],
      items: [
        ImportedCatalogItem(
          providerKey: 'show',
          title: 'Show',
          categoryKey: null,
          playbackRef: '{"providerId":"show","kind":"series"}',
        ),
      ],
    ),
  ];

  static Future<_OrganizationFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'wabbit-organization-',
    );
    return _OrganizationFixture(directory, '${directory.path}/catalog.sqlite');
  }

  Future<void> seed() => database.commitInitialSource(
    const SourceDefinition(
      id: 'source',
      name: 'Source',
      serverUrl: 'https://provider.example',
      username: 'user',
      password: 'secret',
      credentialKey: 'source-key',
    ),
    stages,
  );

  Future<void> dispose() => directory.delete(recursive: true);
}
