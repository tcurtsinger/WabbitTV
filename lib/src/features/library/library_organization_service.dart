import '../sources/source_catalog_database.dart';
import '../sources/source_models.dart';

abstract interface class LibraryOrganizationPort {
  Future<List<PersonalLibraryDirectoryEntry>> loadDirectory({int limit = 200});

  Future<List<PersonalLibraryDirectoryEntry>> loadPinned({int limit = 24});

  Future<CustomGroupLibraryPage> loadGroupItems({
    required String groupId,
    CustomGroupPageCursor? cursor,
    int limit = 100,
  });

  Future<PersonalLibraryOrganization?> loadItem(String libraryItemId);

  Future<PersonalLibraryMutationResult> saveItem({
    required String libraryItemId,
    required bool favorite,
    required Set<String> customGroupIds,
  });

  Future<PersonalLibraryMutationResult> createGroup(String name);

  Future<PersonalLibraryMutationResult> renameGroup({
    required String groupId,
    required String name,
  });

  Future<PersonalLibraryMutationResult> deleteGroup(String groupId);

  Future<PersonalLibraryMutationResult> moveGroup({
    required String groupId,
    required PersonalLibraryMoveDirection direction,
  });

  Future<PersonalLibraryMutationResult> setPinned({
    required PersonalLibraryCollectionRef collection,
    required bool pinned,
  });

  Future<PersonalLibraryMutationResult> movePinned({
    required PersonalLibraryCollectionRef collection,
    required PersonalLibraryMoveDirection direction,
  });

  Future<PersonalLibraryMutationResult> moveGroupItem({
    required String groupId,
    required String libraryItemId,
    required PersonalLibraryMoveDirection direction,
  });

  Future<PersonalLibraryMutationResult> removeGroupItem({
    required String groupId,
    required String libraryItemId,
  });
}

class DatabaseLibraryOrganizationPort implements LibraryOrganizationPort {
  const DatabaseLibraryOrganizationPort(this.database);

  final SourceCatalogDatabase database;

  @override
  Future<List<PersonalLibraryDirectoryEntry>> loadDirectory({
    int limit = 200,
  }) => database.loadPersonalLibraryDirectory(limit: limit);

  @override
  Future<List<PersonalLibraryDirectoryEntry>> loadPinned({int limit = 24}) =>
      database.loadPinnedPersonalLibraryDirectory(limit: limit);

  @override
  Future<CustomGroupLibraryPage> loadGroupItems({
    required String groupId,
    CustomGroupPageCursor? cursor,
    int limit = 100,
  }) => database.loadCustomGroupLibraryPage(
    customGroupId: groupId,
    cursor: cursor,
    limit: limit,
  );

  @override
  Future<PersonalLibraryOrganization?> loadItem(String libraryItemId) =>
      database.loadItemOrganization(libraryItemId);

  @override
  Future<PersonalLibraryMutationResult> saveItem({
    required String libraryItemId,
    required bool favorite,
    required Set<String> customGroupIds,
  }) => database.saveItemOrganization(
    libraryItemId: libraryItemId,
    favorite: favorite,
    customGroupIds: customGroupIds,
  );

  @override
  Future<PersonalLibraryMutationResult> createGroup(String name) =>
      database.createCustomGroup(name);

  @override
  Future<PersonalLibraryMutationResult> renameGroup({
    required String groupId,
    required String name,
  }) => database.renameCustomGroup(customGroupId: groupId, name: name);

  @override
  Future<PersonalLibraryMutationResult> deleteGroup(String groupId) =>
      database.deleteCustomGroup(groupId);

  @override
  Future<PersonalLibraryMutationResult> moveGroup({
    required String groupId,
    required PersonalLibraryMoveDirection direction,
  }) => database.moveCustomGroup(customGroupId: groupId, direction: direction);

  @override
  Future<PersonalLibraryMutationResult> setPinned({
    required PersonalLibraryCollectionRef collection,
    required bool pinned,
  }) => database.setPersonalCollectionPinned(
    collection: collection,
    pinned: pinned,
  );

  @override
  Future<PersonalLibraryMutationResult> movePinned({
    required PersonalLibraryCollectionRef collection,
    required PersonalLibraryMoveDirection direction,
  }) => database.movePinnedPersonalCollection(
    collection: collection,
    direction: direction,
  );

  @override
  Future<PersonalLibraryMutationResult> moveGroupItem({
    required String groupId,
    required String libraryItemId,
    required PersonalLibraryMoveDirection direction,
  }) => database.moveCustomGroupItem(
    customGroupId: groupId,
    libraryItemId: libraryItemId,
    direction: direction,
  );

  @override
  Future<PersonalLibraryMutationResult> removeGroupItem({
    required String groupId,
    required String libraryItemId,
  }) => database.removeCustomGroupItem(
    customGroupId: groupId,
    libraryItemId: libraryItemId,
  );
}
