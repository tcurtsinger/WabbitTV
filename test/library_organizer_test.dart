import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/library/library_organization_service.dart';
import 'package:wabbit_tv/src/features/library/library_organizer.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  testWidgets('one Save replaces Favorite and several group memberships', (
    tester,
  ) async {
    final port = _Port();
    var saved = 0;
    final busy = <bool>[];
    await tester.pumpWidget(
      _host(port, onSaved: () => saved += 1, onBusy: busy.add),
    );
    await tester.pumpAndSettle();

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library organizer favorite',
    );
    await tester.tap(find.text('Favorite'));
    await tester.pump();
    await tester.tap(find.text('Evening News'));
    await tester.pump();
    await tester.tap(find.text('Family Room'));
    await tester.pump();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(port.saveCalls, 1);
    expect(port.savedFavorite, isTrue);
    expect(port.savedGroups, {'news', 'family'});
    expect(busy, [true, false]);
    expect(saved, 1);
  });

  testWidgets('Back discards edits and returns without a write', (
    tester,
  ) async {
    final port = _Port();
    var closed = 0;
    await tester.pumpWidget(_host(port, onClose: () => closed += 1));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Favorite'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(closed, 1);
    expect(port.saveCalls, 0);
  });

  testWidgets('failed save keeps choices and offers the same Save retry', (
    tester,
  ) async {
    final port = _Port()..nextSaveFails = true;
    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Favorite'));
    await tester.pump();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('try again'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(port.saveCalls, 2);
    expect(port.savedFavorite, isTrue);
  });

  testWidgets('pending save blocks dismissal at constrained width', (
    tester,
  ) async {
    final port = _Port()..saveGate = Completer<PersonalLibraryMutationResult>();
    var closed = 0;
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(port, onClose: () => closed += 1));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Favorite'));
    await tester.pump();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 0);
    expect(tester.takeException(), isNull);

    port.saveGate!.complete(
      const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.changed,
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('failure Retry ArrowUp remains in recovery controls', (
    tester,
  ) async {
    final port = _Port()..loadFails = true;
    var closed = 0;
    await tester.pumpWidget(_host(port, onClose: () => closed += 1));
    await tester.pumpAndSettle();

    expect(find.text('Organization unavailable'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library organizer retry',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(closed, 0);
    expect(find.text('Organization unavailable'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library organizer retry',
    );
  });

  testWidgets('remote focus reaches the last of 199 supported groups', (
    tester,
  ) async {
    final port = _Port(groupCount: 199);
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();

    for (var index = 0; index < 199; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'library organizer group group-198',
    );
    expect(find.text('Group 198'), findsOneWidget);
  });
}

Widget _host(
  _Port port, {
  VoidCallback? onClose,
  VoidCallback? onSaved,
  ValueChanged<bool>? onBusy,
}) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: Scaffold(
    body: Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: 360,
        child: LibraryOrganizerPane(
          request: const LibraryOrganizerRequest(
            libraryItemId: 'item',
            title: 'Evening Signal',
            kind: SourceMediaKind.live,
          ),
          port: port,
          onClose: onClose ?? () {},
          onSaved: onSaved ?? () {},
          onBusyChanged: onBusy ?? (_) {},
        ),
      ),
    ),
  ),
);

class _Port implements LibraryOrganizationPort {
  _Port({this.groupCount = 2});

  final int groupCount;
  int saveCalls = 0;
  bool? savedFavorite;
  Set<String>? savedGroups;
  bool nextSaveFails = false;
  bool loadFails = false;
  Completer<PersonalLibraryMutationResult>? saveGate;

  @override
  Future<PersonalLibraryOrganization?> loadItem(String libraryItemId) async {
    if (loadFails) throw StateError('local read failed');
    return PersonalLibraryOrganization(
      libraryItemId: 'item',
      isFavorite: false,
      groups: groupCount == 2
          ? const [
              PersonalLibraryGroupChoice(
                groupId: 'news',
                name: 'Evening News',
                selected: false,
              ),
              PersonalLibraryGroupChoice(
                groupId: 'family',
                name: 'Family Room',
                selected: false,
              ),
            ]
          : [
              for (var index = 0; index < groupCount; index++)
                PersonalLibraryGroupChoice(
                  groupId: 'group-$index',
                  name: 'Group $index',
                  selected: false,
                ),
            ],
    );
  }

  @override
  Future<PersonalLibraryMutationResult> saveItem({
    required String libraryItemId,
    required bool favorite,
    required Set<String> customGroupIds,
  }) async {
    saveCalls += 1;
    savedFavorite = favorite;
    savedGroups = Set.of(customGroupIds);
    final gate = saveGate;
    if (gate != null) return gate.future;
    if (nextSaveFails) {
      nextSaveFails = false;
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.missingGroup,
      );
    }
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
    );
  }

  @override
  Future<PersonalLibraryMutationResult> createGroup(String name) =>
      throw UnimplementedError();
  @override
  Future<PersonalLibraryMutationResult> deleteGroup(String groupId) =>
      throw UnimplementedError();
  @override
  Future<List<PersonalLibraryDirectoryEntry>> loadDirectory({
    int limit = 200,
  }) => throw UnimplementedError();
  @override
  Future<CustomGroupLibraryPage> loadGroupItems({
    required String groupId,
    CustomGroupPageCursor? cursor,
    int limit = 100,
  }) => throw UnimplementedError();
  @override
  Future<List<PersonalLibraryDirectoryEntry>> loadPinned({int limit = 24}) =>
      throw UnimplementedError();
  @override
  Future<PersonalLibraryMutationResult> moveGroup({
    required String groupId,
    required PersonalLibraryMoveDirection direction,
  }) => throw UnimplementedError();
  @override
  Future<PersonalLibraryMutationResult> moveGroupItem({
    required String groupId,
    required String libraryItemId,
    required PersonalLibraryMoveDirection direction,
  }) => throw UnimplementedError();
  @override
  Future<PersonalLibraryMutationResult> movePinned({
    required PersonalLibraryCollectionRef collection,
    required PersonalLibraryMoveDirection direction,
  }) => throw UnimplementedError();
  @override
  Future<PersonalLibraryMutationResult> removeGroupItem({
    required String groupId,
    required String libraryItemId,
  }) => throw UnimplementedError();
  @override
  Future<PersonalLibraryMutationResult> renameGroup({
    required String groupId,
    required String name,
  }) => throw UnimplementedError();
  @override
  Future<PersonalLibraryMutationResult> setPinned({
    required PersonalLibraryCollectionRef collection,
    required bool pinned,
  }) => throw UnimplementedError();
}
