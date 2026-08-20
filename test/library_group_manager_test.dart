import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/library/library_group_manager.dart';
import 'package:wabbit_tv/src/features/library/library_organization_service.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  testWidgets('creates a Unicode mixed-media group from one local save', (
    tester,
  ) async {
    final port = _GroupPort();
    var changed = 0;
    var closed = 0;
    await tester.pumpWidget(
      _host(
        port,
        const LibraryGroupManagementRequest.create(),
        onChanged: () => changed += 1,
        onClose: () => closed += 1,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('group-name-field')),
      'Café 世界',
    );
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(port.createdName, 'Café 世界');
    expect(changed, 1);
    expect(closed, 1);
  });

  testWidgets('TV keyboard names a group and Done returns to the field', (
    tester,
  ) async {
    final port = _GroupPort();
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(port, const LibraryGroupManagementRequest.create()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('TV keyboard'));
    await tester.pump();
    await tester.tap(find.text('A').first);
    await tester.tap(find.text('B').first);
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Done'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Done'));
    await tester.pump();

    expect(find.text('AB'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'group manager name',
    );
  });

  testWidgets('physical D-pad opens TV keyboard and Done returns to field', (
    tester,
  ) async {
    final port = _GroupPort();
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(port, const LibraryGroupManagementRequest.create()),
    );
    await tester.pumpAndSettle();

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'group manager name',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'group keyboard A');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('A'), findsWidgets);

    for (var row = 0; row < 6; row++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    for (var column = 0; column < 3; column++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'group manager name',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('manages pin, group order, item order, and membership locally', (
    tester,
  ) async {
    final port = _GroupPort();
    await tester.binding.setSurfaceSize(const Size(900, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(port, _manageRequest()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pin to Home'));
    await tester.pumpAndSettle();
    expect(port.pinned, isTrue);
    expect(find.text('Unpin Home'), findsOneWidget);

    await tester.tap(find.text('Group down'));
    await tester.pumpAndSettle();
    expect(port.groupMove, PersonalLibraryMoveDirection.down);

    await tester.tap(find.text('Order items'));
    await tester.pump();
    await tester.ensureVisible(find.text('Movie One'));
    await tester.tap(find.text('Movie One'));
    await tester.pump();
    await tester.tap(find.text('Move item down'));
    await tester.pumpAndSettle();
    expect(port.itemMove, ('movie', PersonalLibraryMoveDirection.down));

    await tester.ensureVisible(find.text('Remove from group'));
    await tester.tap(find.text('Remove from group'));
    await tester.pumpAndSettle();
    expect(port.removedItem, 'movie');
  });

  testWidgets('delete defaults to Cancel and explains catalog retention', (
    tester,
  ) async {
    final port = _GroupPort();
    var closed = 0;
    await tester.pumpWidget(
      _host(port, _manageRequest(), onClose: () => closed += 1),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete'));
    await tester.pump();
    expect(find.text('Delete Family Room?'), findsOneWidget);
    expect(find.textContaining('items remain in Wabbit'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      isNot('group manager secondary'),
    );

    await tester.tap(find.text('Delete group'));
    await tester.pumpAndSettle();
    expect(port.deleted, 'family');
    expect(closed, 1);
  });

  testWidgets('Delete Cancel restores the Delete launcher focus', (
    tester,
  ) async {
    final port = _GroupPort();
    await tester.pumpWidget(_host(port, _manageRequest()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(find.text('Manage group'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'group manager secondary',
    );
  });

  testWidgets('initial item failure is truthful and Retry only reloads items', (
    tester,
  ) async {
    final port = _GroupPort()..groupLoadFailures = 1;
    await tester.pumpWidget(_host(port, _manageRequest()));
    await tester.pumpAndSettle();

    expect(find.text('Could not load this local group.'), findsOneWidget);
    expect(find.text('Retry items'), findsOneWidget);
    expect(find.textContaining('group is empty'), findsNothing);

    await tester.tap(find.text('Retry items'));
    await tester.pumpAndSettle();

    expect(port.loadGroupItemsCalls, 2);
    expect(find.text('Movie One'), findsOneWidget);
  });

  testWidgets('Favorites joins the same pinned Home shelf order', (
    tester,
  ) async {
    final port = _GroupPort();
    await tester.pumpWidget(
      _host(
        port,
        const LibraryGroupManagementRequest.manage(
          PersonalLibraryDirectoryEntry(
            kind: PersonalLibraryDirectoryKind.favorites,
            collectionId: null,
            name: 'Favorites',
            itemCount: 12,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Manage Favorites'), findsOneWidget);
    expect(find.textContaining('newest saved first'), findsOneWidget);
    await tester.tap(find.text('Pin to Home'));
    await tester.pumpAndSettle();
    expect(port.lastPinnedCollection?.key, 'favorites');
    expect(find.text('Home shelf up'), findsOneWidget);
  });

  testWidgets('pending mutation blocks Back at 600x713', (tester) async {
    final port = _GroupPort()
      ..pinGate = Completer<PersonalLibraryMutationResult>();
    var closed = 0;
    final busy = <bool>[];
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        port,
        _manageRequest(),
        onClose: () => closed += 1,
        onBusy: busy.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pin to Home'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 0);

    port.pinGate!.complete(
      const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.changed,
      ),
    );
    await tester.pumpAndSettle();
    expect(busy, [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'remote item focus crosses the viewport and loads the next bounded page',
    (tester) async {
      final port = _GroupPort()
        ..items = List.generate(16, _item)
        ..pageChunkSize = 12;
      await tester.binding.setSurfaceSize(const Size(600, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(port, _manageRequest()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Item 00'));
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'group manager item item-00',
      );

      for (var index = 1; index < 16; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }

      expect(port.loadGroupItemsCalls, 2);
      expect(find.text('Item 15'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'group manager item item-15',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('management controls and item ledger fit a short TV pane', (
    tester,
  ) async {
    final port = _GroupPort();
    await tester.binding.setSurfaceSize(const Size(600, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(port, _manageRequest()));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Order items'));
    await tester.tap(find.text('Order items'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Movie One'));

    expect(find.text('Move item up'), findsOneWidget);
    expect(find.text('Movie One'), findsOneWidget);
    final paneRect = tester.getRect(find.byType(LibraryGroupManagerPane));
    final moveUpRect = tester.getRect(find.text('Move item up'));
    final removeRect = tester.getRect(find.text('Remove from group'));
    expect(removeRect.top, greaterThan(moveUpRect.top));
    expect(removeRect.left, greaterThanOrEqualTo(paneRect.left));
    expect(removeRect.right, lessThanOrEqualTo(paneRect.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('deep-page reorder preserves loaded window and selected item', (
    tester,
  ) async {
    final port = _GroupPort()..items = List.generate(150, _item);
    await tester.binding.setSurfaceSize(const Size(900, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(port, _manageRequest()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Order items'));
    await tester.pump();
    final ledger = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.text('Load more'),
      800,
      scrollable: ledger,
    );
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Item 125'),
      500,
      scrollable: ledger,
    );
    await tester.tap(find.text('Item 125'));
    await tester.pump();
    await tester.tap(find.text('Move item up'));
    await tester.pumpAndSettle();

    expect(port.loadGroupItemsCalls, 4);
    expect(port.itemMove, ('item-125', PersonalLibraryMoveDirection.up));
    expect(find.text('Item 125'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'group manager item item-125',
    );
  });

  testWidgets(
    'moving last loaded row down fetches one page and restores exact identity',
    (tester) async {
      final port = _GroupPort()..items = List.generate(150, _item);
      await tester.binding.setSurfaceSize(const Size(900, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(port, _manageRequest()));
      await tester.pumpAndSettle();

      expect(port.loadGroupItemsCalls, 1);
      await tester.tap(find.text('Order items'));
      await tester.pump();
      final ledger = find.byType(Scrollable).last;
      await tester.scrollUntilVisible(
        find.text('Item 99'),
        800,
        scrollable: ledger,
      );
      await tester.tap(find.text('Item 99'));
      await tester.pump();
      await tester.tap(find.text('Move item down'));
      await tester.pumpAndSettle();

      expect(port.itemMove, ('item-99', PersonalLibraryMoveDirection.down));
      expect(port.loadGroupItemsCalls, 3);
      expect(find.text('Item 99'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'group manager item item-99',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'load-more is serialized before mutation and cannot append stale',
    (tester) async {
      final loadGate = Completer<void>();
      final port = _GroupPort()
        ..items = List.generate(150, _item)
        ..gateGroupLoadCall = 2
        ..groupLoadGate = loadGate;
      await tester.binding.setSurfaceSize(const Size(900, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(port, _manageRequest()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Order items'));
      await tester.pump();
      final ledger = find.byType(Scrollable).last;
      await tester.scrollUntilVisible(
        find.text('Item 99'),
        800,
        scrollable: ledger,
      );
      await tester.tap(find.text('Item 99'));
      await tester.scrollUntilVisible(
        find.text('Load more'),
        400,
        scrollable: ledger,
      );
      await tester.tap(find.text('Load more'));
      await tester.pump();
      expect(port.loadGroupItemsCalls, 2);

      await tester.tap(find.text('Move item down'));
      await tester.pump();
      expect(port.itemMove, isNull);

      loadGate.complete();
      await tester.pumpAndSettle();

      expect(port.itemMove, ('item-99', PersonalLibraryMoveDirection.down));
      expect(port.loadGroupItemsCalls, 4);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'group manager item item-99',
      );
      expect(find.text('Item 99'), findsOneWidget);
    },
  );

  testWidgets('post-commit Retry view repeats only the failed read', (
    tester,
  ) async {
    final port = _GroupPort()..directoryFailures = 1;
    await tester.pumpWidget(_host(port, _manageRequest()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Group down'));
    await tester.pumpAndSettle();

    expect(port.groupMoveCalls, 1);
    expect(find.textContaining('saved locally'), findsOneWidget);
    expect(find.text('Retry view'), findsOneWidget);

    await tester.ensureVisible(find.text('Retry view'));
    await tester.tap(find.text('Retry view'));
    await tester.pumpAndSettle();

    expect(port.groupMoveCalls, 1);
    expect(port.loadDirectoryCalls, 2);
    expect(find.textContaining('View refreshed'), findsOneWidget);
    expect(find.text('Retry view'), findsNothing);
  });

  testWidgets('unchanged move does not claim that the group moved', (
    tester,
  ) async {
    final port = _GroupPort()
      ..groupMoveOutcome = PersonalLibraryMutationOutcome.unchanged;
    await tester.pumpWidget(_host(port, _manageRequest()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Group down'));
    await tester.pumpAndSettle();

    expect(find.text('Group moved down.'), findsNothing);
    expect(find.text('Already in that position or state.'), findsOneWidget);
  });
}

LibraryGroupManagementRequest _manageRequest() =>
    const LibraryGroupManagementRequest.manage(
      PersonalLibraryDirectoryEntry(
        kind: PersonalLibraryDirectoryKind.customGroup,
        collectionId: 'family',
        name: 'Family Room',
        itemCount: 2,
        directoryOrdinal: 0,
      ),
    );

Widget _host(
  _GroupPort port,
  LibraryGroupManagementRequest request, {
  VoidCallback? onClose,
  VoidCallback? onChanged,
  ValueChanged<bool>? onBusy,
}) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: Scaffold(
    body: Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: 460,
        child: LibraryGroupManagerPane(
          request: request,
          port: port,
          onClose: onClose ?? () {},
          onChanged: onChanged ?? () {},
          onBusyChanged: onBusy ?? (_) {},
        ),
      ),
    ),
  ),
);

class _GroupPort implements LibraryOrganizationPort {
  String? createdName;
  String? deleted;
  bool pinned = false;
  PersonalLibraryCollectionRef? lastPinnedCollection;
  PersonalLibraryMoveDirection? groupMove;
  int groupMoveCalls = 0;
  PersonalLibraryMutationOutcome groupMoveOutcome =
      PersonalLibraryMutationOutcome.changed;
  (String, PersonalLibraryMoveDirection)? itemMove;
  String? removedItem;
  Completer<PersonalLibraryMutationResult>? pinGate;
  int? pageChunkSize;
  int loadGroupItemsCalls = 0;
  int groupLoadFailures = 0;
  int? gateGroupLoadCall;
  Completer<void>? groupLoadGate;
  int directoryFailures = 0;
  int loadDirectoryCalls = 0;
  List<PersonalLibraryItem> items = const [
    PersonalLibraryItem(
      libraryItemId: 'movie',
      kind: SourceMediaKind.movies,
      title: 'Movie One',
      artworkLocator: null,
      catalogItemId: 'catalog-movie',
      sourceId: 'source',
      sourceDisplayName: 'Strong',
      playbackRef: '{}',
    ),
    PersonalLibraryItem(
      libraryItemId: 'series',
      kind: SourceMediaKind.series,
      title: 'Series Two',
      artworkLocator: null,
      catalogItemId: 'catalog-series',
      sourceId: 'source',
      sourceDisplayName: 'Strong',
      playbackRef: '{}',
    ),
  ];

  PersonalLibraryDirectoryEntry get group => PersonalLibraryDirectoryEntry(
    kind: PersonalLibraryDirectoryKind.customGroup,
    collectionId: 'family',
    name: 'Family Room',
    itemCount: items.length,
    directoryOrdinal: 0,
    homeOrdinal: pinned ? 0 : null,
  );

  @override
  Future<PersonalLibraryMutationResult> createGroup(String name) async {
    createdName = name;
    return PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
      collection: PersonalLibraryDirectoryEntry(
        kind: PersonalLibraryDirectoryKind.customGroup,
        collectionId: 'new',
        name: name,
        itemCount: 0,
        directoryOrdinal: 1,
      ),
    );
  }

  @override
  Future<List<PersonalLibraryDirectoryEntry>> loadDirectory({
    int limit = 200,
  }) async {
    loadDirectoryCalls += 1;
    if (directoryFailures > 0) {
      directoryFailures -= 1;
      throw StateError('directory unavailable');
    }
    return [
      PersonalLibraryDirectoryEntry(
        kind: PersonalLibraryDirectoryKind.favorites,
        collectionId: null,
        name: 'Favorites',
        itemCount: 12,
        homeOrdinal: lastPinnedCollection?.key == 'favorites' && pinned
            ? 0
            : null,
      ),
      group,
    ];
  }

  @override
  Future<CustomGroupLibraryPage> loadGroupItems({
    required String groupId,
    CustomGroupPageCursor? cursor,
    int limit = 100,
  }) async {
    loadGroupItemsCalls += 1;
    if (groupLoadFailures > 0) {
      groupLoadFailures -= 1;
      throw StateError('group items unavailable');
    }
    if (loadGroupItemsCalls == gateGroupLoadCall) {
      await groupLoadGate?.future;
    }
    final start = cursor == null ? 0 : cursor.ordinal + 1;
    final requested = pageChunkSize ?? limit;
    final end = (start + requested).clamp(0, items.length);
    final pageItems = items.sublist(start, end);
    return CustomGroupLibraryPage(
      items: pageItems,
      nextCursor: end < items.length
          ? CustomGroupPageCursor(
              ordinal: end - 1,
              libraryItemId: items[end - 1].libraryItemId,
            )
          : null,
    );
  }

  @override
  Future<PersonalLibraryMutationResult> setPinned({
    required PersonalLibraryCollectionRef collection,
    required bool pinned,
  }) async {
    final gate = pinGate;
    if (gate != null) await gate.future;
    this.pinned = pinned;
    lastPinnedCollection = collection;
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
    );
  }

  @override
  Future<PersonalLibraryMutationResult> moveGroup({
    required String groupId,
    required PersonalLibraryMoveDirection direction,
  }) async {
    groupMove = direction;
    groupMoveCalls += 1;
    return PersonalLibraryMutationResult(groupMoveOutcome);
  }

  @override
  Future<PersonalLibraryMutationResult> moveGroupItem({
    required String groupId,
    required String libraryItemId,
    required PersonalLibraryMoveDirection direction,
  }) async {
    itemMove = (libraryItemId, direction);
    final index = items.indexWhere(
      (item) => item.libraryItemId == libraryItemId,
    );
    final target = direction == PersonalLibraryMoveDirection.up
        ? index - 1
        : index + 1;
    if (index < 0 || target < 0 || target >= items.length) {
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.unchanged,
      );
    }
    final reordered = [...items];
    final displaced = reordered[target];
    reordered[target] = reordered[index];
    reordered[index] = displaced;
    items = reordered;
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
    );
  }

  @override
  Future<PersonalLibraryMutationResult> removeGroupItem({
    required String groupId,
    required String libraryItemId,
  }) async {
    removedItem = libraryItemId;
    items = items.where((item) => item.libraryItemId != libraryItemId).toList();
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
    );
  }

  @override
  Future<PersonalLibraryMutationResult> deleteGroup(String groupId) async {
    deleted = groupId;
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
    );
  }

  @override
  Future<PersonalLibraryMutationResult> renameGroup({
    required String groupId,
    required String name,
  }) async => const PersonalLibraryMutationResult(
    PersonalLibraryMutationOutcome.changed,
  );

  @override
  Future<List<PersonalLibraryDirectoryEntry>> loadPinned({
    int limit = 24,
  }) async => pinned ? [group] : const [];
  @override
  Future<PersonalLibraryOrganization?> loadItem(String libraryItemId) =>
      throw UnimplementedError();
  @override
  Future<PersonalLibraryMutationResult> movePinned({
    required PersonalLibraryCollectionRef collection,
    required PersonalLibraryMoveDirection direction,
  }) async => const PersonalLibraryMutationResult(
    PersonalLibraryMutationOutcome.changed,
  );
  @override
  Future<PersonalLibraryMutationResult> saveItem({
    required String libraryItemId,
    required bool favorite,
    required Set<String> customGroupIds,
  }) => throw UnimplementedError();
}

PersonalLibraryItem _item(int index) => PersonalLibraryItem(
  libraryItemId: 'item-${index.toString().padLeft(2, '0')}',
  kind: index.isEven ? SourceMediaKind.movies : SourceMediaKind.series,
  title: 'Item ${index.toString().padLeft(2, '0')}',
  artworkLocator: null,
  catalogItemId: 'catalog-$index',
  sourceId: 'source',
  sourceDisplayName: 'Strong',
  playbackRef: '{}',
);
