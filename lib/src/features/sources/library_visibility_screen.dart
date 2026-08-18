import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';

import 'source_models.dart';

const _graphite = Color(0xFF111212),
    _surface = Color(0xFF191A1A),
    _raised = Color(0xFF222321),
    _line = Color(0xFF343534),
    _warmWhite = Color(0xFFF4F0E7),
    _quietText = Color(0xFFAAA8A2),
    _amber = Color(0xFFFFB347),
    _amberInk = Color(0xFF17120A);

/// Credential-free local identity for a provider category. A null group id is
/// the truthful local Uncategorized grouping, never an invented provider key.
class LibraryVisibilityCategoryRef {
  const LibraryVisibilityCategoryRef.group(this.sourceGroupId)
    : assert(sourceGroupId != null);
  const LibraryVisibilityCategoryRef.uncategorized() : sourceGroupId = null;
  final String? sourceGroupId;
  @override
  bool operator ==(Object other) =>
      other is LibraryVisibilityCategoryRef &&
      other.sourceGroupId == sourceGroupId;
  @override
  int get hashCode => sourceGroupId.hashCode;
}

/// Bounded directory data, safe for source-management UI and test fixtures.
class LibraryVisibilityCategory {
  const LibraryVisibilityCategory({
    required this.ref,
    required this.name,
    required this.availableItemCount,
    required this.hidden,
  });
  final LibraryVisibilityCategoryRef ref;
  final String name;
  final int availableItemCount;
  final bool hidden;
}

class LibraryVisibilityItem {
  const LibraryVisibilityItem({
    required this.catalogItemId,
    required this.title,
    required this.kind,
    required this.hidden,
  });
  final String catalogItemId;
  final String title;
  final SourceMediaKind kind;
  final bool hidden;
}

/// Opaque cursor preserves bounded virtual item pages.
class LibraryVisibilityItemPage {
  const LibraryVisibilityItemPage({
    required this.items,
    required this.nextCursor,
  });
  final List<LibraryVisibilityItem> items;
  final String? nextCursor;
}

/// Local-only persistence seam. Implementations must not call a provider.
abstract interface class LibraryVisibilityPort {
  Future<List<LibraryVisibilityCategory>> loadCategories({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hiddenOnly,
  });
  Future<LibraryVisibilityItemPage> loadItems({
    required String sourceId,
    required SourceMediaKind kind,
    required LibraryVisibilityCategoryRef category,
    required bool hiddenOnly,
    String? cursor,
    int limit,
  });
  Future<void> setCategoryHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required LibraryVisibilityCategoryRef category,
    required bool hidden,
  });

  /// Sets every provider-backed category for the selected source and kind.
  /// This deliberately excludes Uncategorized and never changes item flags.
  Future<int> setAllCategoriesHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hidden,
  });
  Future<void> setItemHidden({
    required String sourceId,
    required String catalogItemId,
    required bool hidden,
  });
}

/// Source-management continuation: an in-shell directory and item ledger.
class LibraryVisibilityScreen extends StatefulWidget {
  const LibraryVisibilityScreen({
    super.key,
    required this.sourceId,
    required this.sourceName,
    required this.port,
    required this.initialFocus,
    required this.onContentFocus,
    required this.onBack,
    this.onBusyChanged,
  });
  final String sourceId;
  final String sourceName;
  final LibraryVisibilityPort port;
  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onBack;
  final ValueChanged<bool>? onBusyChanged;
  @override
  State<LibraryVisibilityScreen> createState() =>
      _LibraryVisibilityScreenState();
}

class _LibraryVisibilityScreenState extends State<LibraryVisibilityScreen> {
  static const _pageSize = 100;
  final _categoryScroll = ScrollController(), _itemScroll = ScrollController();
  final _hiddenFocus = FocusNode(debugLabel: 'library visibility hidden only');
  final _emptyRecoveryFocus = FocusNode(
    debugLabel: 'library visibility empty recovery',
  );
  final _categoryActionFocus = FocusNode(
    debugLabel: 'library visibility category action',
  );
  final _bulkHideFocus = FocusNode(debugLabel: 'library visibility hide all');
  final _bulkRestoreFocus = FocusNode(
    debugLabel: 'library visibility restore all',
  );
  final _bulkCancelFocus = FocusNode(
    debugLabel: 'library visibility bulk cancel',
  );
  final _bulkConfirmFocus = FocusNode(
    debugLabel: 'library visibility bulk confirm',
  );
  final _bulkRetryFocus = FocusNode(
    debugLabel: 'library visibility bulk retry',
  );
  final _launcherFocus = FocusNode(
    debugLabel: 'library visibility directory launcher',
  );
  final _retryFocus = FocusNode(debugLabel: 'library visibility retry');
  final _kindFocus = {
    for (final k in SourceMediaKind.values)
      k: FocusNode(debugLabel: 'library visibility ${k.name}'),
  };
  final Map<String, FocusNode> _mountedCategoryFocus = {};
  final Map<String, FocusNode> _mountedItemFocus = {};
  SourceMediaKind _kind = SourceMediaKind.live;
  bool _hiddenOnly = false,
      _loading = true,
      _loadingItems = false,
      _loadingMore = false,
      _directoryOpen = false,
      _initialLoadFailed = false,
      _itemLoadFailed = false,
      _isNarrow = false;
  bool _bulkConfirming = false, _bulkSaving = false;
  bool? _bulkFailureHidden;
  _BulkFailureStage? _bulkFailureStage;
  String? _failure, _nextCursor;
  List<LibraryVisibilityCategory> _categories = const [];
  List<LibraryVisibilityCategory> _allCategories = const [];
  List<LibraryVisibilityItem> _items = const [];
  LibraryVisibilityCategory? _selected;
  _VisibilitySnapshot? _lastUsableSnapshot;
  int _generation = 0;
  int _itemRequest = 0;
  int _bulkRequest = 0;

  @override
  void initState() {
    super.initState();
    _itemScroll.addListener(_loadMoreIfNeeded);
    _attachHeaderFocusListeners();
    unawaited(_loadDirectory());
  }

  @override
  void didUpdateWidget(covariant LibraryVisibilityScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialFocus != widget.initialFocus) {
      oldWidget.initialFocus.removeListener(_reportEntryFocus);
      widget.initialFocus.addListener(_reportEntryFocus);
    }
  }

  @override
  void dispose() {
    _categoryScroll.dispose();
    _itemScroll.dispose();
    widget.initialFocus.removeListener(_reportEntryFocus);
    for (final node in [
      _hiddenFocus,
      _emptyRecoveryFocus,
      _categoryActionFocus,
      _bulkHideFocus,
      _bulkRestoreFocus,
      _bulkCancelFocus,
      _bulkConfirmFocus,
      _bulkRetryFocus,
      _launcherFocus,
      _retryFocus,
      ..._kindFocus.values,
    ]) {
      node.removeListener(_reportOwnedFocus);
    }
    _hiddenFocus.dispose();
    _emptyRecoveryFocus.dispose();
    _categoryActionFocus.dispose();
    _bulkHideFocus.dispose();
    _bulkRestoreFocus.dispose();
    _bulkCancelFocus.dispose();
    _bulkConfirmFocus.dispose();
    _bulkRetryFocus.dispose();
    _launcherFocus.dispose();
    _retryFocus.dispose();
    for (final n in _kindFocus.values) {
      n.dispose();
    }
    super.dispose();
  }

  String _categoryKey(LibraryVisibilityCategoryRef ref) =>
      ref.sourceGroupId ?? '__uncategorized__';

  void _mountCategory(LibraryVisibilityCategoryRef ref, FocusNode node) =>
      _mountedCategoryFocus[_categoryKey(ref)] = node;

  void _unmountCategory(LibraryVisibilityCategoryRef ref, FocusNode node) {
    final key = _categoryKey(ref);
    if (identical(_mountedCategoryFocus[key], node)) {
      _mountedCategoryFocus.remove(key);
    }
  }

  void _mountItem(String id, FocusNode node) => _mountedItemFocus[id] = node;

  void _unmountItem(String id, FocusNode node) {
    if (identical(_mountedItemFocus[id], node)) {
      _mountedItemFocus.remove(id);
    }
  }

  void _focused(FocusNode node) {
    if (node.hasFocus) widget.onContentFocus(node);
  }

  void _attachHeaderFocusListeners() {
    widget.initialFocus.addListener(_reportEntryFocus);
    for (final node in [
      _hiddenFocus,
      _emptyRecoveryFocus,
      _categoryActionFocus,
      _bulkHideFocus,
      _bulkRestoreFocus,
      _bulkCancelFocus,
      _bulkConfirmFocus,
      _bulkRetryFocus,
      _launcherFocus,
      _retryFocus,
      ..._kindFocus.values,
    ]) {
      node.addListener(_reportOwnedFocus);
    }
  }

  void _reportEntryFocus() => _focused(widget.initialFocus);

  void _reportOwnedFocus() {
    for (final node in [
      _hiddenFocus,
      _emptyRecoveryFocus,
      _categoryActionFocus,
      _bulkHideFocus,
      _bulkRestoreFocus,
      _bulkCancelFocus,
      _bulkConfirmFocus,
      _bulkRetryFocus,
      _launcherFocus,
      _retryFocus,
      ..._kindFocus.values,
    ]) {
      if (node.hasFocus) {
        _focused(node);
        return;
      }
    }
  }

  Future<_DirectoryLoadResult> _loadDirectory({int? fallbackIndex}) async {
    final generation = ++_generation;
    // Hidden-only is intentionally a recovery filter. The directory still
    // needs the complete local category state to truthfully describe the bulk
    // action for this source and media kind.
    setState(() {
      _loading = _categories.isEmpty;
      _failure = null;
      _initialLoadFailed = false;
    });
    final previous = _selected?.ref;
    try {
      final categories = await widget.port.loadCategories(
        sourceId: widget.sourceId,
        kind: _kind,
        hiddenOnly: _hiddenOnly,
      );
      if (!mounted || generation != _generation) {
        return _DirectoryLoadResult.superseded;
      }
      final allCategoriesRequest = _hiddenOnly
          ? widget.port.loadCategories(
              sourceId: widget.sourceId,
              kind: _kind,
              hiddenOnly: false,
            )
          : null;
      final allCategories = allCategoriesRequest == null
          ? categories
          : await allCategoriesRequest;
      if (!mounted || generation != _generation) {
        return _DirectoryLoadResult.superseded;
      }
      final selected =
          categories.where((c) => c.ref == previous).firstOrNull ??
          (categories.isEmpty
              ? null
              : categories[(fallbackIndex ?? 0).clamp(
                  0,
                  categories.length - 1,
                )]);
      setState(() {
        _categories = categories;
        _allCategories = allCategories;
        _selected = selected;
        _loading = false;
        _items = const [];
        _nextCursor = null;
        _itemLoadFailed = false;
      });
      if (selected != null) {
        final itemResult = await _loadItems(reset: true);
        if (!mounted || generation != _generation) {
          return _DirectoryLoadResult.superseded;
        }
        return switch (itemResult) {
          _ItemLoadResult.success => _DirectoryLoadResult.success,
          _ItemLoadResult.failed => _DirectoryLoadResult.failed,
          _ItemLoadResult.superseded => _DirectoryLoadResult.superseded,
        };
      }
      _rememberUsableView();
      return _DirectoryLoadResult.success;
    } catch (_) {
      if (!mounted || generation != _generation) {
        return _DirectoryLoadResult.superseded;
      }
      setState(() {
        _loading = false;
        _initialLoadFailed = _categories.isEmpty;
        _failure = _initialLoadFailed
            ? null
            : 'Visibility could not be updated. Showing your last local view.';
      });
      return _DirectoryLoadResult.failed;
    }
  }

  Future<_ItemLoadResult> _loadItems({required bool reset}) async {
    final category = _selected;
    if (category == null || (!reset && _loadingMore)) {
      return _ItemLoadResult.superseded;
    }
    final generation = _generation;
    final request = reset ? ++_itemRequest : _itemRequest;
    setState(() {
      if (reset) {
        _loadingItems = _items.isEmpty;
        _failure = null;
        _itemLoadFailed = false;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final page = await widget.port.loadItems(
        sourceId: widget.sourceId,
        kind: _kind,
        category: category.ref,
        hiddenOnly: _hiddenOnly,
        cursor: reset ? null : _nextCursor,
        limit: _pageSize,
      );
      if (!mounted ||
          generation != _generation ||
          request != _itemRequest ||
          _selected?.ref != category.ref) {
        return _ItemLoadResult.superseded;
      }
      setState(() {
        _items = reset ? page.items : [..._items, ...page.items];
        _nextCursor = page.nextCursor;
        _loadingItems = false;
        _loadingMore = false;
        _itemLoadFailed = false;
      });
      _rememberUsableView();
      return _ItemLoadResult.success;
    } catch (_) {
      if (!mounted ||
          generation != _generation ||
          request != _itemRequest ||
          _selected?.ref != category.ref) {
        return _ItemLoadResult.superseded;
      }
      setState(() {
        _loadingItems = false;
        _loadingMore = false;
        _itemLoadFailed = reset && _items.isEmpty;
        _failure = _itemLoadFailed ? null : 'Could not load more items. Your last local view is still available.';
      });
      return _ItemLoadResult.failed;
    }
  }

  void _loadMoreIfNeeded() {
    if (!_itemScroll.hasClients ||
        _loadingItems ||
        _loadingMore ||
        _nextCursor == null ||
        _itemScroll.position.extentAfter > 240) {
      return;
    }
    unawaited(_loadItems(reset: false));
  }

  Future<void> _setKind(SourceMediaKind kind) async {
    if (_kind == kind) return;
    if (_bulkSaving) {
      _announceBulkWait();
      return;
    }
    final snapshot = _snapshotForMutation();
    _bulkRequest++;
    setState(() {
      _kind = kind;
      _categories = const [];
      _allCategories = const [];
      _selected = null;
      _items = const [];
      _nextCursor = null;
      _bulkConfirming = false;
      _bulkFailureHidden = null;
      _bulkFailureStage = null;
    });
    if (await _loadDirectory() == _DirectoryLoadResult.failed) {
      _restoreSnapshot(snapshot);
    }
  }

  Future<void> _setHiddenOnly() async {
    if (_bulkSaving) {
      _announceBulkWait();
      return;
    }
    final snapshot = _snapshotForMutation();
    _bulkRequest++;
    setState(() {
      _hiddenOnly = !_hiddenOnly;
      _items = const [];
      _nextCursor = null;
      _bulkConfirming = false;
      _bulkFailureHidden = null;
      _bulkFailureStage = null;
    });
    if (await _loadDirectory() == _DirectoryLoadResult.failed) {
      _restoreSnapshot(snapshot);
    }
  }

  Future<void> _showAllFromEmpty() async {
    await _setHiddenOnly();
    if (mounted && !_hiddenOnly) {
      _hiddenFocus.requestFocus();
    }
  }

  _VisibilitySnapshot _snapshotForMutation() =>
      (_loading || _loadingItems) && _lastUsableSnapshot != null
      ? _lastUsableSnapshot!
      : _snapshot();

  _VisibilitySnapshot _snapshot() => _VisibilitySnapshot(
    kind: _kind,
    hiddenOnly: _hiddenOnly,
    categories: _categories,
    allCategories: _allCategories,
    selected: _selected,
    items: _items,
    nextCursor: _nextCursor,
    itemLoadFailed: _itemLoadFailed,
  );

  void _rememberUsableView() => _lastUsableSnapshot = _snapshot();

  void _restoreSnapshot(_VisibilitySnapshot snapshot) {
    if (!mounted) return;
    setState(() {
      _kind = snapshot.kind;
      _hiddenOnly = snapshot.hiddenOnly;
      _categories = snapshot.categories;
      _allCategories = snapshot.allCategories;
      _selected = snapshot.selected;
      _items = snapshot.items;
      _nextCursor = snapshot.nextCursor;
      _itemLoadFailed = snapshot.itemLoadFailed;
      _loading = false;
      _loadingItems = false;
      _loadingMore = false;
      _initialLoadFailed = false;
      _failure =
          'Visibility could not be updated. Showing your last local view.';
    });
    _lastUsableSnapshot = snapshot;
  }

  Future<void> _selectCategory(LibraryVisibilityCategory category) async {
    final leftOverlay = _directoryOpen;
    if (_bulkSaving && leftOverlay) {
      _announceBulkWait();
      return;
    }
    if (leftOverlay) {
      setState(() => _directoryOpen = false);
    }
    if (_selected?.ref == category.ref) {
      if (leftOverlay) _focusCategoryActionOrFirstItem();
      return;
    }
    setState(() {
      _selected = category;
      _items = const [];
      _nextCursor = null;
      _failure = null;
    });
    final loaded = await _loadItems(reset: true);
    if (leftOverlay && loaded != _ItemLoadResult.superseded) {
      _focusCategoryActionOrFirstItem();
    }
  }

  Future<void> _toggleCategory() async {
    if (_bulkSaving) {
      _announceBulkWait();
      return;
    }
    final category = _selected;
    if (category == null || category.ref.sourceGroupId == null) return;
    final generation = _generation;
    final kind = _kind;
    final categoryRef = category.ref;
    final previousIndex = _categories.indexWhere(
      (current) => current.ref == categoryRef,
    );
    try {
      await widget.port.setCategoryHidden(
        sourceId: widget.sourceId,
        kind: kind,
        category: categoryRef,
        hidden: !category.hidden,
      );
      if (!mounted || generation != _generation || kind != _kind) return;
      _announce(
        '${category.name} ${category.hidden ? 'restored' : 'hidden'} locally.',
      );
      if (_hiddenOnly && category.hidden) {
        final result = await _loadDirectory(fallbackIndex: previousIndex);
        if (!mounted || result != _DirectoryLoadResult.success) return;
        _focusAfterFilteredCategoryChange(previousIndex, categoryRef);
      } else {
        LibraryVisibilityCategory updated(LibraryVisibilityCategory current) =>
            current.ref == categoryRef
            ? LibraryVisibilityCategory(
                ref: current.ref,
                name: current.name,
                availableItemCount: current.availableItemCount,
                hidden: !category.hidden,
              )
            : current;
        final selectedRef = _selected?.ref;
        setState(() {
          _categories = [for (final c in _categories) updated(c)];
          _allCategories = [for (final c in _allCategories) updated(c)];
          _selected = _categories
              .where((c) => c.ref == selectedRef)
              .firstOrNull;
        });
        _rememberUsableView();
        if (_selected?.ref == categoryRef) {
          _categoryActionFocus.requestFocus();
        }
      }
    } catch (_) {
      if (!mounted || generation != _generation || kind != _kind) return;
      setState(
        () => _failure =
            'Visibility could not be saved. No local change was made.',
      );
      _categoryActionFocus.requestFocus();
    }
  }

  List<LibraryVisibilityCategory> get _providerCategories => _allCategories
      .where((category) => category.ref.sourceGroupId != null)
      .toList(growable: false);

  int get _bulkHiddenCount =>
      _providerCategories.where((category) => category.hidden).length;

  bool get _canHideAll =>
      !_bulkSaving && _providerCategories.any((category) => !category.hidden);

  bool get _canRestoreAll =>
      !_bulkSaving && _providerCategories.any((category) => category.hidden);

  void _requestHideAll() {
    if (!_canHideAll || _bulkConfirming || _bulkFailureHidden != null) return;
    setState(() {
      _bulkConfirming = true;
      _bulkFailureStage = null;
      _failure = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _bulkConfirming) _bulkCancelFocus.requestFocus();
    });
  }

  void _cancelBulkPrompt({bool focusAction = true}) {
    final failed = _bulkFailureHidden;
    final savedLocally = _bulkFailureStage == _BulkFailureStage.refresh;
    final normalizeFullView = savedLocally && _hiddenOnly;
    final selectedRef = _selected?.ref;
    setState(() {
      if (normalizeFullView) {
        _hiddenOnly = false;
        _categories = _allCategories;
        _selected = _categories
            .where((category) => category.ref == selectedRef)
            .firstOrNull;
        _selected ??= _categories.firstOrNull;
        _items = const [];
        _nextCursor = null;
        _itemLoadFailed = false;
      }
      _bulkConfirming = false;
      _bulkFailureHidden = null;
      _bulkFailureStage = null;
    });
    if (normalizeFullView) {
      if (_selected == null) {
        _rememberUsableView();
      } else {
        unawaited(_loadItems(reset: true));
      }
    }
    if (!focusAction) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (savedLocally ? !(failed ?? false) : (failed ?? true))
          ? _bulkHideFocus.requestFocus()
          : _bulkRestoreFocus.requestFocus();
    });
  }

  Future<void> _setAllCategoriesHidden(bool hidden) async {
    if (_bulkSaving || _providerCategories.isEmpty) return;
    if (hidden && !_canHideAll) return;
    if (!hidden && !_canRestoreAll) return;
    final request = ++_bulkRequest;
    final generation = _generation;
    final kind = _kind;
    final selectedIndex = _categories.indexWhere(
      (category) => category.ref == _selected?.ref,
    );
    setState(() {
      _bulkSaving = true;
      _bulkConfirming = false;
      _bulkFailureHidden = null;
      _bulkFailureStage = null;
      _failure = null;
    });
    widget.onBusyChanged?.call(true);
    try {
      await widget.port.setAllCategoriesHidden(
        sourceId: widget.sourceId,
        kind: kind,
        hidden: hidden,
      );
      if (!mounted ||
          request != _bulkRequest ||
          generation != _generation ||
          kind != _kind) {
        return;
      }
    } catch (_) {
      if (!mounted ||
          request != _bulkRequest ||
          generation != _generation ||
          kind != _kind) {
        return;
      }
      setState(() {
        _bulkSaving = false;
        _bulkConfirming = false;
        _bulkFailureHidden = hidden;
        _bulkFailureStage = _BulkFailureStage.write;
      });
      widget.onBusyChanged?.call(false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && request == _bulkRequest) _bulkRetryFocus.requestFocus();
      });
      return;
    }

    _applyBulkFlagsLocally(hidden);
    if (!_hiddenOnly) {
      _finishBulkSuccess(hidden, request, kind);
      return;
    }
    await _refreshFilteredCategoriesAfterBulk(
      hidden: hidden,
      request: request,
      generation: generation,
      kind: kind,
      fallbackIndex: selectedIndex,
    );
  }

  void _retryBulk() {
    final hidden = _bulkFailureHidden;
    if (hidden == null) return;
    if (_bulkFailureStage == _BulkFailureStage.refresh) {
      unawaited(_retryBulkRefresh(hidden));
    } else {
      unawaited(_setAllCategoriesHidden(hidden));
    }
  }

  void _applyBulkFlagsLocally(bool hidden) {
    LibraryVisibilityCategory updated(LibraryVisibilityCategory category) =>
        category.ref.sourceGroupId == null
        ? category
        : LibraryVisibilityCategory(
            ref: category.ref,
            name: category.name,
            availableItemCount: category.availableItemCount,
            hidden: hidden,
          );
    final selectedRef = _selected?.ref;
    setState(() {
      _allCategories = [
        for (final category in _allCategories) updated(category),
      ];
      _categories = [for (final category in _categories) updated(category)];
      _selected = _categories
          .where((category) => category.ref == selectedRef)
          .firstOrNull;
    });
    _rememberUsableView();
  }

  Future<void> _retryBulkRefresh(bool hidden) async {
    if (_bulkSaving) return;
    final request = ++_bulkRequest;
    final generation = _generation;
    final kind = _kind;
    final selectedIndex = _categories.indexWhere(
      (category) => category.ref == _selected?.ref,
    );
    setState(() {
      _bulkSaving = true;
      _bulkFailureHidden = null;
      _bulkFailureStage = null;
    });
    widget.onBusyChanged?.call(true);
    await _refreshFilteredCategoriesAfterBulk(
      hidden: hidden,
      request: request,
      generation: generation,
      kind: kind,
      fallbackIndex: selectedIndex,
    );
  }

  Future<void> _refreshFilteredCategoriesAfterBulk({
    required bool hidden,
    required int request,
    required int generation,
    required SourceMediaKind kind,
    required int fallbackIndex,
  }) async {
    final previousRef = _selected?.ref;
    try {
      final categories = await widget.port.loadCategories(
        sourceId: widget.sourceId,
        kind: kind,
        hiddenOnly: true,
      );
      if (!mounted ||
          request != _bulkRequest ||
          generation != _generation ||
          kind != _kind) {
        return;
      }
      final selected = categories
          .where((category) => category.ref == previousRef)
          .firstOrNull;
      if (selected != null) {
        setState(() {
          _categories = categories;
          _selected = selected;
        });
        _rememberUsableView();
        _finishBulkSuccess(hidden, request, kind);
        return;
      }
      final fallback = categories.isEmpty
          ? null
          : categories[fallbackIndex.clamp(0, categories.length - 1)];
      setState(() {
        _categories = categories;
        _selected = fallback;
        _items = const [];
        _nextCursor = null;
        _itemLoadFailed = false;
      });
      if (fallback != null) {
        final itemResult = await _loadItems(reset: true);
        if (!mounted ||
            request != _bulkRequest ||
            generation != _generation ||
            kind != _kind ||
            itemResult == _ItemLoadResult.superseded) {
          return;
        }
      } else {
        _rememberUsableView();
      }
      _finishBulkSuccess(hidden, request, kind);
    } catch (_) {
      if (!mounted ||
          request != _bulkRequest ||
          generation != _generation ||
          kind != _kind) {
        return;
      }
      setState(() {
        _bulkSaving = false;
        _bulkFailureHidden = hidden;
        _bulkFailureStage = _BulkFailureStage.refresh;
      });
      widget.onBusyChanged?.call(false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && request == _bulkRequest) _bulkRetryFocus.requestFocus();
      });
    }
  }

  void _finishBulkSuccess(bool hidden, int request, SourceMediaKind kind) {
    if (!mounted || request != _bulkRequest || kind != _kind) return;
    setState(() {
      _bulkSaving = false;
      _bulkFailureHidden = null;
      _bulkFailureStage = null;
    });
    widget.onBusyChanged?.call(false);
    _announce(
      hidden
          ? 'All ${kind.label} categories hidden locally. Individual item choices stay unchanged.'
          : 'All ${kind.label} categories restored locally. Individual item choices stay unchanged.',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && request == _bulkRequest && kind == _kind) {
        if (_hiddenOnly && _categories.isEmpty) {
          _emptyRecoveryFocus.requestFocus();
        } else {
          (hidden ? _bulkRestoreFocus : _bulkHideFocus).requestFocus();
        }
      }
    });
  }

  void _announceBulkWait() =>
      _announce('Please wait while category visibility is updated.');

  Future<void> _toggleItem(LibraryVisibilityItem item) async {
    if (_bulkSaving) {
      _announceBulkWait();
      return;
    }
    final previousIndex = _items.indexWhere(
      (current) => current.catalogItemId == item.catalogItemId,
    );
    final previousCategoryIndex = _categories.indexWhere(
      (category) => category.ref == _selected?.ref,
    );
    try {
      await widget.port.setItemHidden(
        sourceId: widget.sourceId,
        catalogItemId: item.catalogItemId,
        hidden: !item.hidden,
      );
      if (!mounted) return;
      _announce(
        '${item.title} ${item.hidden ? 'restored' : 'hidden'} locally.',
      );
      if (_hiddenOnly && item.hidden) {
        final result = await _loadDirectory(
          fallbackIndex: previousCategoryIndex,
        );
        if (!mounted || result != _DirectoryLoadResult.success) return;
        _focusAfterFilteredItemChange(previousIndex);
      } else {
        setState(() {
          _items = [
            for (final current in _items)
              if (current.catalogItemId == item.catalogItemId)
                LibraryVisibilityItem(
                  catalogItemId: current.catalogItemId,
                  title: current.title,
                  kind: current.kind,
                  hidden: !current.hidden,
                )
              else
                current,
          ];
        });
        _rememberUsableView();
        _requestItemFocus(item.catalogItemId);
      }
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _failure =
            'Visibility could not be saved. No local change was made.',
      );
      _requestItemFocus(item.catalogItemId);
    }
  }

  void _announce(String text) => SemanticsService.sendAnnouncement(
    View.of(context),
    text,
    Directionality.of(context),
  );

  void _focusAfterFilteredCategoryChange(
    int previousIndex,
    LibraryVisibilityCategoryRef changedCategory,
  ) {
    if (_categories.isEmpty) {
      _hiddenFocus.requestFocus();
      return;
    }
    final category =
        _selected ??
        _categories[previousIndex.clamp(0, _categories.length - 1)];
    if (category.ref == changedCategory && category.ref.sourceGroupId != null) {
      _categoryActionFocus.requestFocus();
    } else {
      _requestCategoryFocus(category.ref);
    }
  }

  void _focusAfterFilteredItemChange(int previousIndex) {
    if (_items.isNotEmpty) {
      final index = previousIndex.clamp(0, _items.length - 1);
      _requestItemFocusAt(index);
      return;
    }
    final category = _selected;
    if (category?.ref.sourceGroupId != null) {
      _categoryActionFocus.requestFocus();
    } else if (category != null) {
      _requestCategoryFocus(category.ref);
    } else if (_categories.isNotEmpty) {
      _requestCategoryFocus(_categories.first.ref);
    } else {
      _hiddenFocus.requestFocus();
    }
  }

  void _moveCategory(int index, int amount) {
    if (amount < 0 && index == 0 && _providerCategories.isNotEmpty) {
      _focusBulkAction();
      return;
    }
    final to = (index + amount).clamp(0, _categories.length - 1);
    if (to == index) return;
    _requestCategoryFocusAt(to);
  }

  void _moveItem(int index, int amount) {
    if (amount > 0 && index == _items.length - 1 && _nextCursor != null) {
      unawaited(_loadNextPageAndFocus());
      return;
    }
    final to = (index + amount).clamp(0, _items.length - 1);
    if (to == index) return;
    _requestItemFocusAt(to);
  }

  Future<void> _loadNextPageAndFocus() async {
    if (_loadingMore) return;
    final firstNewIndex = _items.length;
    if (await _loadItems(reset: false) != _ItemLoadResult.success || !mounted) {
      return;
    }
    if (_items.length > firstNewIndex) {
      _requestItemFocusAt(firstNewIndex);
    }
  }

  void _requestCategoryFocus(LibraryVisibilityCategoryRef ref) {
    final index = _categories.indexWhere((category) => category.ref == ref);
    if (index >= 0) _requestCategoryFocusAt(index);
  }

  void _requestCategoryFocusAt(int index) {
    if (index < 0 || index >= _categories.length) return;
    final ref = _categories[index].ref;
    final key = _categoryKey(ref);
    if (_categoryScroll.hasClients) {
      _categoryScroll.jumpTo(
        (index * 58.0).clamp(0, _categoryScroll.position.maxScrollExtent),
      );
    }
    final mountedNode = _mountedCategoryFocus[key];
    if (mountedNode != null) {
      mountedNode.requestFocus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mountedCategoryFocus[key]?.requestFocus();
    });
  }

  void _requestItemFocus(String id) {
    final index = _items.indexWhere((item) => item.catalogItemId == id);
    if (index >= 0) _requestItemFocusAt(index);
  }

  void _requestItemFocusAt(int index) {
    if (index < 0 || index >= _items.length) return;
    final id = _items[index].catalogItemId;
    if (_itemScroll.hasClients) {
      _itemScroll.jumpTo(
        (index * 60.0).clamp(0, _itemScroll.position.maxScrollExtent),
      );
    }
    final mountedNode = _mountedItemFocus[id];
    if (mountedNode != null) {
      mountedNode.requestFocus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mountedItemFocus[id]?.requestFocus();
    });
  }

  void _back() {
    if (_bulkSaving) {
      _announceBulkWait();
      return;
    }
    if (_bulkConfirming || _bulkFailureHidden != null) {
      _cancelBulkPrompt();
      return;
    }
    if (_directoryOpen) {
      setState(() => _directoryOpen = false);
      _launcherFocus.requestFocus();
      return;
    }
    final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
    if (label.startsWith('library visibility item ') && _selected != null) {
      _focusSelectedCategory();
      return;
    }
    widget.onBack();
  }

  void _focusCategoryActionOrFirstItem() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_initialLoadFailed || _itemLoadFailed) {
        _retryFocus.requestFocus();
        return;
      }
      final category = _selected;
      if (category?.ref.sourceGroupId != null) {
        _categoryActionFocus.requestFocus();
      } else if (_items.isNotEmpty) {
        _requestItemFocusAt(0);
      }
    });
  }

  void _focusFirstItem() {
    if (_itemLoadFailed) {
      _retryFocus.requestFocus();
      return;
    }
    if (_items.isNotEmpty) {
      _requestItemFocusAt(0);
    }
  }

  void _focusSelectedCategory() {
    final category = _selected;
    if (category == null) return;
    if (_isNarrow && !_directoryOpen) {
      setState(() => _directoryOpen = true);
    }
    _requestCategoryFocus(category.ref);
  }

  void _enterLedgerFromCategory() {
    if (_bulkSaving && _directoryOpen) {
      _announceBulkWait();
      return;
    }
    if (_directoryOpen) setState(() => _directoryOpen = false);
    _focusCategoryActionOrFirstItem();
  }

  void _toggleDirectoryFromLauncher() {
    if (_bulkSaving) {
      _announceBulkWait();
      return;
    }
    if (_directoryOpen) {
      setState(() => _directoryOpen = false);
      _launcherFocus.requestFocus();
      return;
    }
    _openDirectoryAndFocusFirst();
  }

  void _openDirectoryAndFocusFirst() {
    if (!_directoryOpen) setState(() => _directoryOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_providerCategories.isNotEmpty) {
        _focusBulkAction();
      } else if (_categories.isNotEmpty) {
        _requestCategoryFocusAt(0);
      }
    });
  }

  void _focusActivePane() {
    if (_initialLoadFailed || _itemLoadFailed) {
      _retryFocus.requestFocus();
      return;
    }
    if (_isNarrow) {
      _launcherFocus.requestFocus();
    } else if (_hiddenOnly && _categories.isEmpty) {
      _emptyRecoveryFocus.requestFocus();
    } else if (_providerCategories.isNotEmpty) {
      _focusBulkAction();
    } else if (_selected != null) {
      _requestCategoryFocus(_selected!.ref);
    }
  }

  void _focusBulkAction() {
    if (_bulkConfirming) {
      _bulkCancelFocus.requestFocus();
      return;
    }
    if (_bulkFailureHidden != null) {
      _bulkRetryFocus.requestFocus();
      return;
    }
    if (_canHideAll) {
      _bulkHideFocus.requestFocus();
    } else if (_canRestoreAll) {
      _bulkRestoreFocus.requestFocus();
    } else if (_categories.isNotEmpty) {
      _requestCategoryFocusAt(0);
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): _back,
      const SingleActivator(LogicalKeyboardKey.browserBack): _back,
    },
    child: FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: ColoredBox(
        color: _graphite,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 780;
            _isNarrow = narrow;
            return SafeArea(
              left: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 22, 32, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Header(
                      sourceName: widget.sourceName,
                      kind: _kind,
                      hiddenOnly: _hiddenOnly,
                      backFocus: widget.initialFocus,
                      hiddenFocus: _hiddenFocus,
                      kindFocus: _kindFocus,
                      narrow: narrow,
                      launcherFocus: _launcherFocus,
                      directoryOpen: _directoryOpen,
                      onBack: _back,
                      onToggleHidden: _setHiddenOnly,
                      onKind: _setKind,
                      onToggleDirectory: _toggleDirectoryFromLauncher,
                      onEnterDirectory: _openDirectoryAndFocusFirst,
                      onActivePane: _focusActivePane,
                    ),
                    const SizedBox(height: 22),
                    if (_failure != null) ...[
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _failure!,
                          key: const ValueKey('visibility-recovery'),
                          style: const TextStyle(color: _amber, fontSize: 14),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    Expanded(
                      child: _loading
                          ? const _VisibilitySkeleton()
                          : _initialLoadFailed
                          ? _InitialLoadFailure(
                              focusNode: _retryFocus,
                              onRetry: _loadDirectory,
                              onUp: _kindFocus[_kind]!.requestFocus,
                            )
                          : _categories.isEmpty
                          ? _EmptyVisibility(
                              hiddenOnly: _hiddenOnly,
                              focusNode: _emptyRecoveryFocus,
                              onClear: _hiddenOnly ? _showAllFromEmpty : null,
                            )
                          : _VisibilityBody(
                              narrow: narrow,
                              directoryOpen: _directoryOpen,
                              directory: _CategoryDirectory(
                                categories: _categories,
                                sourceName: widget.sourceName,
                                kind: _kind,
                                providerCategoryCount:
                                    _providerCategories.length,
                                hiddenCategoryCount: _bulkHiddenCount,
                                selected: _selected,
                                controller: _categoryScroll,
                                hideAllFocus: _bulkHideFocus,
                                restoreAllFocus: _bulkRestoreFocus,
                                cancelFocus: _bulkCancelFocus,
                                confirmFocus: _bulkConfirmFocus,
                                retryFocus: _bulkRetryFocus,
                                confirming: _bulkConfirming,
                                saving: _bulkSaving,
                                failedHidden: _bulkFailureHidden,
                                failureSavedLocally:
                                    _bulkFailureStage ==
                                    _BulkFailureStage.refresh,
                                canHideAll: _canHideAll,
                                canRestoreAll: _canRestoreAll,
                                onRequestHideAll: _requestHideAll,
                                onConfirmHideAll: () =>
                                    unawaited(_setAllCategoriesHidden(true)),
                                onRestoreAll: () =>
                                    unawaited(_setAllCategoriesHidden(false)),
                                onCancelBulk: _cancelBulkPrompt,
                                onRetryBulk: _retryBulk,
                                onNodeMounted: _mountCategory,
                                onNodeUnmounted: _unmountCategory,
                                onFocused: _focused,
                                onSelect: _selectCategory,
                                onMove: _moveCategory,
                                onFocusFirst: () => _requestCategoryFocusAt(0),
                                onUpFromFirst: _focusBulkAction,
                                onRight: _enterLedgerFromCategory,
                              ),
                              ledger: _ItemLedger(
                                category: _selected!,
                                items: _items,
                                loading: _loadingItems,
                                loadingMore: _loadingMore,
                                nextCursor: _nextCursor,
                                hiddenOnly: _hiddenOnly,
                                controller: _itemScroll,
                                categoryActionFocus: _categoryActionFocus,
                                retryFocus: _retryFocus,
                                onItemNodeMounted: _mountItem,
                                onItemNodeUnmounted: _unmountItem,
                                onFocused: _focused,
                                onToggleCategory: _toggleCategory,
                                onToggleItem: _toggleItem,
                                onMove: _moveItem,
                                onLeft: _focusSelectedCategory,
                                onCategoryActionRight: _focusFirstItem,
                                onRetry: () =>
                                    _loadItems(reset: _items.isEmpty),
                                onRetryUp: _kindFocus[_kind]!.requestFocus,
                                initialLoadFailed: _itemLoadFailed,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.sourceName,
    required this.kind,
    required this.hiddenOnly,
    required this.backFocus,
    required this.hiddenFocus,
    required this.kindFocus,
    required this.narrow,
    required this.launcherFocus,
    required this.directoryOpen,
    required this.onBack,
    required this.onToggleHidden,
    required this.onKind,
    required this.onToggleDirectory,
    required this.onEnterDirectory,
    required this.onActivePane,
  });
  final String sourceName;
  final SourceMediaKind kind;
  final bool hiddenOnly, narrow, directoryOpen;
  final FocusNode backFocus, hiddenFocus, launcherFocus;
  final Map<SourceMediaKind, FocusNode> kindFocus;
  final VoidCallback onBack,
      onToggleHidden,
      onToggleDirectory,
      onEnterDirectory,
      onActivePane;
  final ValueChanged<SourceMediaKind> onKind;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          _QuietAction(
            label: 'Back',
            focusNode: backFocus,
            onPressed: onBack,
            onRight: hiddenFocus.requestFocus,
            onDown: kindFocus[kind]!.requestFocus,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Manage visibility',
                  style: TextStyle(
                    color: _warmWhite,
                    fontSize: 31,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.7,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '$sourceName · Local visibility only',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _quietText, fontSize: 14),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _QuietAction(
            label: hiddenOnly ? 'Hidden only: on' : 'Hidden only',
            focusNode: hiddenFocus,
            onPressed: onToggleHidden,
            onLeft: backFocus.requestFocus,
            onDown: kindFocus[kind]!.requestFocus,
          ),
        ],
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var index = 0; index < SourceMediaKind.values.length; index++)
            _KindAction(
              kind: SourceMediaKind.values[index],
              selected: SourceMediaKind.values[index] == kind,
              focusNode: kindFocus[SourceMediaKind.values[index]]!,
              onPressed: () => onKind(SourceMediaKind.values[index]),
              onUp: hiddenFocus.requestFocus,
              onLeft: index == 0
                  ? hiddenFocus.requestFocus
                  : kindFocus[SourceMediaKind.values[index - 1]]!.requestFocus,
              onRight: index == SourceMediaKind.values.length - 1
                  ? onActivePane
                  : kindFocus[SourceMediaKind.values[index + 1]]!.requestFocus,
              onDown: onActivePane,
            ),
          if (narrow)
            _QuietAction(
              label: directoryOpen ? 'Close categories' : 'Provider categories',
              focusNode: launcherFocus,
              onPressed: onToggleDirectory,
              onUp: kindFocus[kind]!.requestFocus,
              onDown: onEnterDirectory,
            ),
        ],
      ),
    ],
  );
}

class _VisibilityBody extends StatelessWidget {
  const _VisibilityBody({
    required this.narrow,
    required this.directoryOpen,
    required this.directory,
    required this.ledger,
  });
  final bool narrow, directoryOpen;
  final Widget directory, ledger;
  @override
  Widget build(BuildContext context) => !narrow
      ? Row(
          children: [
            SizedBox(width: 300, child: directory),
            const SizedBox(width: 20),
            Expanded(child: ledger),
          ],
        )
      : Stack(
          children: [
            ledger,
            if (directoryOpen)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: _graphite),
                  child: directory,
                ),
              ),
          ],
        );
}

class _CategoryDirectory extends StatelessWidget {
  const _CategoryDirectory({
    required this.categories,
    required this.sourceName,
    required this.kind,
    required this.providerCategoryCount,
    required this.hiddenCategoryCount,
    required this.selected,
    required this.controller,
    required this.hideAllFocus,
    required this.restoreAllFocus,
    required this.cancelFocus,
    required this.confirmFocus,
    required this.retryFocus,
    required this.confirming,
    required this.saving,
    required this.failedHidden,
    required this.failureSavedLocally,
    required this.canHideAll,
    required this.canRestoreAll,
    required this.onRequestHideAll,
    required this.onConfirmHideAll,
    required this.onRestoreAll,
    required this.onCancelBulk,
    required this.onRetryBulk,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onFocused,
    required this.onSelect,
    required this.onMove,
    required this.onFocusFirst,
    required this.onUpFromFirst,
    required this.onRight,
  });

  final List<LibraryVisibilityCategory> categories;
  final String sourceName;
  final SourceMediaKind kind;
  final int providerCategoryCount, hiddenCategoryCount;
  final LibraryVisibilityCategory? selected;
  final ScrollController controller;
  final FocusNode hideAllFocus,
      restoreAllFocus,
      cancelFocus,
      confirmFocus,
      retryFocus;
  final bool confirming, saving, canHideAll, canRestoreAll;
  final bool failureSavedLocally;
  final bool? failedHidden;
  final VoidCallback onRequestHideAll,
      onConfirmHideAll,
      onRestoreAll,
      onCancelBulk,
      onRetryBulk,
      onFocusFirst,
      onUpFromFirst,
      onRight;
  final void Function(LibraryVisibilityCategoryRef, FocusNode) onNodeMounted;
  final void Function(LibraryVisibilityCategoryRef, FocusNode) onNodeUnmounted;
  final ValueChanged<FocusNode> onFocused;
  final ValueChanged<LibraryVisibilityCategory> onSelect;
  final void Function(int, int) onMove;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: _CategoryToolbar(
            providerCategoryCount: providerCategoryCount,
            hiddenCategoryCount: hiddenCategoryCount,
            sourceName: sourceName,
            kind: kind,
            confirming: confirming,
            saving: saving,
            failedHidden: failedHidden,
            failureSavedLocally: failureSavedLocally,
            canHideAll: canHideAll,
            canRestoreAll: canRestoreAll,
            hideAllFocus: hideAllFocus,
            restoreAllFocus: restoreAllFocus,
            cancelFocus: cancelFocus,
            confirmFocus: confirmFocus,
            retryFocus: retryFocus,
            onRequestHideAll: onRequestHideAll,
            onConfirmHideAll: onConfirmHideAll,
            onRestoreAll: onRestoreAll,
            onCancel: onCancelBulk,
            onRetry: onRetryBulk,
            onDown: () {
              if (categories.isNotEmpty) onFocusFirst();
            },
            onRight: onRight,
          ),
        ),
        const Divider(height: 1, color: _line),
        Expanded(
          child: ListView.builder(
            controller: controller,
            itemExtent: 58,
            itemCount: categories.length,
            itemBuilder: (_, index) {
              final category = categories[index];
              return _CategoryRow(
                key: ValueKey(_categoryIdentity(category.ref)),
                category: category,
                selected: category.ref == selected?.ref,
                onNodeMounted: (node) => onNodeMounted(category.ref, node),
                onNodeUnmounted: (node) => onNodeUnmounted(category.ref, node),
                onFocused: onFocused,
                onSelect: () => onSelect(category),
                onMove: (delta) => onMove(index, delta),
                onUpFromFirst: index == 0 ? onUpFromFirst : null,
                onRight: onRight,
              );
            },
          ),
        ),
      ],
    ),
  );
}

class _CategoryToolbar extends StatelessWidget {
  const _CategoryToolbar({
    required this.providerCategoryCount,
    required this.hiddenCategoryCount,
    required this.sourceName,
    required this.kind,
    required this.confirming,
    required this.saving,
    required this.failedHidden,
    required this.failureSavedLocally,
    required this.canHideAll,
    required this.canRestoreAll,
    required this.hideAllFocus,
    required this.restoreAllFocus,
    required this.cancelFocus,
    required this.confirmFocus,
    required this.retryFocus,
    required this.onRequestHideAll,
    required this.onConfirmHideAll,
    required this.onRestoreAll,
    required this.onCancel,
    required this.onRetry,
    required this.onDown,
    required this.onRight,
  });
  final int providerCategoryCount, hiddenCategoryCount;
  final String sourceName;
  final SourceMediaKind kind;
  final bool confirming, saving, canHideAll, canRestoreAll;
  final bool failureSavedLocally;
  final bool? failedHidden;
  final FocusNode hideAllFocus,
      restoreAllFocus,
      cancelFocus,
      confirmFocus,
      retryFocus;
  final VoidCallback onRequestHideAll,
      onConfirmHideAll,
      onRestoreAll,
      onCancel,
      onRetry,
      onDown,
      onRight;

  @override
  Widget build(BuildContext context) {
    const heading = Text(
      'Provider categories',
      style: TextStyle(
        color: _warmWhite,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    );
    if (providerCategoryCount == 0) {
      return heading;
    }
    final includedCategoryCount = providerCategoryCount - hiddenCategoryCount;
    final summary = Text(
      hiddenCategoryCount == 0
          ? 'All ${_formatCount(providerCategoryCount)} categories included'
          : hiddenCategoryCount == providerCategoryCount
          ? 'All ${_formatCount(providerCategoryCount)} categories hidden'
          : '${_formatCount(includedCategoryCount)} included · ${_formatCount(hiddenCategoryCount)} hidden',
      style: const TextStyle(color: _quietText, fontSize: 12),
    );
    if (saving) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading,
          const SizedBox(height: 4),
          summary,
          const SizedBox(height: 10),
          SizedBox(
            key: const ValueKey('visibility-bulk-action-slot'),
            height: 40,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Semantics(
                liveRegion: true,
                child: const Text(
                  'Updating categories…',
                  style: TextStyle(color: _quietText, fontSize: 14),
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (failedHidden case final hidden?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading,
          const SizedBox(height: 4),
          summary,
          const SizedBox(height: 10),
          Semantics(
            liveRegion: true,
            child: Text(
              failureSavedLocally
                  ? 'Category visibility was saved locally; this view could not refresh'
                  : 'Category visibility was not changed',
              style: TextStyle(color: _amber, fontSize: 14),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            key: const ValueKey('visibility-bulk-action-slot'),
            height: 40,
            child: Row(
              children: [
                Expanded(
                  child: _BulkAction(
                    key: const ValueKey('visibility-bulk-retry'),
                    label: 'Retry',
                    focusNode: retryFocus,
                    onPressed: onRetry,
                    primary: hidden,
                    onRight: cancelFocus.requestFocus,
                    onDown: onDown,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _BulkAction(
                    key: const ValueKey('visibility-bulk-cancel'),
                    label: 'Cancel',
                    focusNode: cancelFocus,
                    onPressed: onCancel,
                    onLeft: retryFocus.requestFocus,
                    onRight: onRight,
                    onDown: onDown,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    if (confirming) {
      final confirmation =
          'Hide all ${_formatCount(providerCategoryCount)} ${kind.label} categories from $sourceName? Individual item choices stay unchanged.';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading,
          const SizedBox(height: 4),
          Semantics(
            key: const ValueKey('visibility-bulk-confirmation-message'),
            liveRegion: true,
            label: confirmation,
            child: ExcludeSemantics(
              child: Text(
                confirmation,
                style: const TextStyle(color: _warmWhite, fontSize: 14),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            key: const ValueKey('visibility-bulk-action-slot'),
            height: 40,
            child: Row(
              children: [
                Expanded(
                  child: _BulkAction(
                    key: const ValueKey('visibility-bulk-cancel'),
                    label: 'Cancel',
                    focusNode: cancelFocus,
                    semanticHint:
                        'Cancel hiding all ${_formatCount(providerCategoryCount)} ${kind.label} categories from $sourceName. Individual item choices stay unchanged.',
                    onPressed: onCancel,
                    onRight: confirmFocus.requestFocus,
                    onDown: onDown,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _BulkAction(
                    key: const ValueKey('visibility-bulk-confirm-hide'),
                    label: 'Hide ${_formatCount(providerCategoryCount)}',
                    focusNode: confirmFocus,
                    semanticHint:
                        'Hide all ${_formatCount(providerCategoryCount)} ${kind.label} categories from $sourceName. Individual item choices stay unchanged.',
                    onPressed: onConfirmHideAll,
                    primary: true,
                    onLeft: cancelFocus.requestFocus,
                    onRight: onRight,
                    onDown: onDown,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading,
        const SizedBox(height: 4),
        summary,
        const SizedBox(height: 10),
        SizedBox(
          key: const ValueKey('visibility-bulk-action-slot'),
          height: 40,
          child: Row(
            children: [
              Expanded(
                child: _BulkAction(
                  key: const ValueKey('visibility-bulk-hide'),
                  label: 'Hide all',
                  focusNode: hideAllFocus,
                  enabled: canHideAll,
                  semanticHint: canHideAll
                      ? 'Hide all provider categories for ${kind.label}. Individual item choices stay unchanged.'
                      : 'All provider categories are already hidden.',
                  onPressed: onRequestHideAll,
                  onRight: canRestoreAll
                      ? restoreAllFocus.requestFocus
                      : onRight,
                  onDown: onDown,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _BulkAction(
                  key: const ValueKey('visibility-bulk-restore'),
                  label: 'Restore all',
                  focusNode: restoreAllFocus,
                  enabled: canRestoreAll,
                  semanticHint: canRestoreAll
                      ? 'Restore all provider categories for ${kind.label}. Individual item choices stay unchanged.'
                      : 'All provider categories are already included.',
                  onPressed: onRestoreAll,
                  onLeft: canHideAll ? hideAllFocus.requestFocus : null,
                  onRight: onRight,
                  onDown: onDown,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BulkAction extends StatelessWidget {
  const _BulkAction({
    super.key,
    required this.label,
    required this.focusNode,
    required this.onPressed,
    this.enabled = true,
    this.primary = false,
    this.semanticHint,
    this.onLeft,
    this.onRight,
    this.onDown,
  });
  final String label;
  final FocusNode focusNode;
  final VoidCallback onPressed;
  final bool enabled, primary;
  final String? semanticHint;
  final VoidCallback? onLeft, onRight, onDown;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: enabled,
    hint: semanticHint,
    child: _DirectionalShortcuts(
      onActivate: enabled ? onPressed : () {},
      onLeft: onLeft,
      onRight: onRight,
      onDown: onDown,
      child: SizedBox(
        height: 40,
        child: primary
            ? FilledButton(
                focusNode: focusNode,
                onPressed: enabled ? onPressed : null,
                style: FilledButton.styleFrom(
                  backgroundColor: _amber,
                  foregroundColor: _amberInk,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ).copyWith(side: _buttonSide(primary: true)),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            : OutlinedButton(
                focusNode: focusNode,
                onPressed: enabled ? onPressed : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: _warmWhite,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ).copyWith(side: _buttonSide()),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
      ),
    ),
  );
}

class _CategoryRow extends StatefulWidget {
  const _CategoryRow({
    super.key,
    required this.category,
    required this.selected,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onFocused,
    required this.onSelect,
    required this.onMove,
    this.onUpFromFirst,
    required this.onRight,
  });
  final LibraryVisibilityCategory category;
  final bool selected;
  final ValueChanged<FocusNode> onNodeMounted;
  final ValueChanged<FocusNode> onNodeUnmounted;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onSelect, onRight;
  final VoidCallback? onUpFromFirst;
  final ValueChanged<int> onMove;
  @override
  State<_CategoryRow> createState() => _CategoryRowState();
}

class _CategoryRowState extends State<_CategoryRow> {
  bool focused = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      debugLabel:
          'library visibility category ${_categoryIdentity(widget.category.ref)}',
    );
    widget.onNodeMounted(_focusNode);
  }

  @override
  void dispose() {
    widget.onNodeUnmounted(_focusNode);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    onFocusChange: (value) {
      setState(() => focused = value);
      if (value) widget.onFocused(_focusNode);
    },
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
          if (widget.onUpFromFirst case final callback?) {
            callback();
          } else {
            widget.onMove(-1);
          }
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          widget.onMove(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowRight:
          widget.onRight();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
          widget.onSelect();
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    },
    child: Semantics(
      button: true,
      selected: widget.selected,
      label:
          '${widget.category.name}, ${_formatCount(widget.category.availableItemCount)} items, ${widget.category.hidden ? 'Hidden' : 'Included'}',
      child: InkWell(
        onTap: () {
          _focusNode.requestFocus();
          widget.onSelect();
        },
        child: Container(
          key: ValueKey(
            'visibility-category-${widget.category.ref.sourceGroupId ?? 'uncategorized'}',
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: widget.selected ? _raised : Colors.transparent,
            border: Border.all(
              color: focused ? _amber : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.category.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.selected ? _warmWhite : _quietText,
                    fontSize: 15,
                    fontWeight: widget.selected
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatCount(widget.category.availableItemCount),
                style: const TextStyle(color: _quietText, fontSize: 12),
              ),
              const SizedBox(width: 8),
              Text(
                widget.category.hidden ? 'Hidden' : 'Included',
                style: TextStyle(
                  color: widget.category.hidden ? _amber : _quietText,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ItemLedger extends StatelessWidget {
  const _ItemLedger({
    required this.category,
    required this.items,
    required this.loading,
    required this.loadingMore,
    required this.nextCursor,
    required this.hiddenOnly,
    required this.controller,
    required this.categoryActionFocus,
    required this.retryFocus,
    required this.onItemNodeMounted,
    required this.onItemNodeUnmounted,
    required this.onFocused,
    required this.onToggleCategory,
    required this.onToggleItem,
    required this.onMove,
    required this.onLeft,
    required this.onCategoryActionRight,
    required this.onRetry,
    required this.onRetryUp,
    required this.initialLoadFailed,
  });
  final LibraryVisibilityCategory category;
  final List<LibraryVisibilityItem> items;
  final bool loading, loadingMore, hiddenOnly;
  final String? nextCursor;
  final ScrollController controller;
  final FocusNode categoryActionFocus;
  final FocusNode retryFocus;
  final void Function(String, FocusNode) onItemNodeMounted;
  final void Function(String, FocusNode) onItemNodeUnmounted;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onToggleCategory,
      onLeft,
      onCategoryActionRight,
      onRetry,
      onRetryUp;
  final ValueChanged<LibraryVisibilityItem> onToggleItem;
  final void Function(int, int) onMove;
  final bool initialLoadFailed;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      category.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _warmWhite,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${_formatCount(category.availableItemCount)} available · ${category.hidden ? 'Hidden' : 'Included'}',
                      style: const TextStyle(color: _quietText, fontSize: 14),
                    ),
                  ],
                ),
              ),
              if (category.ref.sourceGroupId != null) ...[
                const SizedBox(width: 12),
                _VisibilityAction(
                  label: category.hidden ? 'Restore category' : 'Hide category',
                  focusNode: categoryActionFocus,
                  onPressed: onToggleCategory,
                  primary: !category.hidden,
                  onLeft: onLeft,
                  onRight: onCategoryActionRight,
                  onDown: onCategoryActionRight,
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1, color: _line),
        Expanded(
          child: loading
              ? const _LedgerSkeleton()
              : initialLoadFailed
              ? _InlineItemFailure(
                  focusNode: retryFocus,
                  onRetry: onRetry,
                  onUp: onRetryUp,
                  onLeft: onLeft,
                )
              : items.isEmpty
              ? _NoItems(hiddenOnly: hiddenOnly)
              : ListView.builder(
                  controller: controller,
                  itemExtent: 60,
                  itemCount:
                      items.length +
                      (loadingMore
                          ? 4
                          : nextCursor == null
                          ? 0
                          : 1),
                  itemBuilder: (_, index) {
                    if (index >= items.length) {
                      return loadingMore
                          ? const _ItemSkeleton()
                          : _LoadMore(onRetry: onRetry);
                    }
                    final item = items[index];
                    return _ItemRow(
                      key: ValueKey(item.catalogItemId),
                      item: item,
                      onNodeMounted: (node) =>
                          onItemNodeMounted(item.catalogItemId, node),
                      onNodeUnmounted: (node) =>
                          onItemNodeUnmounted(item.catalogItemId, node),
                      onFocused: onFocused,
                      onToggle: () => onToggleItem(item),
                      onMove: (delta) => onMove(index, delta),
                      onLeft: onLeft,
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class _ItemRow extends StatefulWidget {
  const _ItemRow({
    super.key,
    required this.item,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onFocused,
    required this.onToggle,
    required this.onMove,
    required this.onLeft,
  });
  final LibraryVisibilityItem item;
  final ValueChanged<FocusNode> onNodeMounted;
  final ValueChanged<FocusNode> onNodeUnmounted;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onToggle, onLeft;
  final ValueChanged<int> onMove;
  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  bool focused = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      debugLabel: 'library visibility item ${widget.item.catalogItemId}',
    );
    widget.onNodeMounted(_focusNode);
  }

  @override
  void dispose() {
    widget.onNodeUnmounted(_focusNode);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    onFocusChange: (value) {
      setState(() => focused = value);
      if (value) widget.onFocused(_focusNode);
    },
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
          widget.onMove(-1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          widget.onMove(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowLeft:
          widget.onLeft();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
          widget.onToggle();
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    },
    child: Semantics(
      button: true,
      label:
          '${widget.item.title}, ${widget.item.kind.label}, ${widget.item.hidden ? 'Hidden. Restore item' : 'Included. Hide item'}',
      child: InkWell(
        onTap: () {
          _focusNode.requestFocus();
          widget.onToggle();
        },
        child: Container(
          key: ValueKey('visibility-item-${widget.item.catalogItemId}'),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: focused ? _raised : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: focused ? _amber : Colors.transparent,
                width: 2,
              ),
              right: BorderSide(
                color: focused ? _amber : Colors.transparent,
                width: 2,
              ),
              bottom: BorderSide(color: focused ? _amber : _line, width: 2),
              top: BorderSide(
                color: focused ? _amber : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                switch (widget.item.kind) {
                  SourceMediaKind.live => Icons.live_tv_outlined,
                  SourceMediaKind.movies => Icons.movie_outlined,
                  SourceMediaKind.series => Icons.tv_outlined,
                },
                size: 18,
                color: _quietText,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _warmWhite,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                widget.item.kind.label,
                style: const TextStyle(color: _quietText, fontSize: 12),
              ),
              const SizedBox(width: 16),
              Text(
                widget.item.hidden ? 'Hidden' : 'Included',
                style: TextStyle(
                  color: widget.item.hidden ? _amber : _quietText,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _VisibilityAction extends StatelessWidget {
  const _VisibilityAction({
    required this.label,
    required this.focusNode,
    required this.onPressed,
    required this.primary,
    this.onLeft,
    this.onRight,
    this.onDown,
  });
  final String label;
  final FocusNode focusNode;
  final VoidCallback onPressed;
  final bool primary;
  final VoidCallback? onLeft, onRight, onDown;
  @override
  Widget build(BuildContext context) => _DirectionalShortcuts(
    onActivate: onPressed,
    onLeft: onLeft,
    onRight: onRight,
    onDown: onDown,
    child: SizedBox(
      height: 44,
      child: primary
          ? FilledButton(
              key: ValueKey('visibility-action-$label'),
              focusNode: focusNode,
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: _amber,
                foregroundColor: _amberInk,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ).copyWith(side: _buttonSide(primary: true)),
              child: Text(label),
            )
          : OutlinedButton(
              key: ValueKey('visibility-action-$label'),
              focusNode: focusNode,
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: _warmWhite,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ).copyWith(side: _buttonSide()),
              child: Text(label),
            ),
    ),
  );
}

class _QuietAction extends StatelessWidget {
  const _QuietAction({
    required this.label,
    required this.focusNode,
    required this.onPressed,
    this.onLeft,
    this.onRight,
    this.onUp,
    this.onDown,
  });
  final String label;
  final FocusNode focusNode;
  final VoidCallback onPressed;
  final VoidCallback? onLeft, onRight, onUp, onDown;
  @override
  Widget build(BuildContext context) => _DirectionalShortcuts(
    onActivate: onPressed,
    onLeft: onLeft,
    onRight: onRight,
    onUp: onUp,
    onDown: onDown,
    child: OutlinedButton(
      key: ValueKey('visibility-action-$label'),
      focusNode: focusNode,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: _warmWhite,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ).copyWith(side: _buttonSide()),
      child: Text(label),
    ),
  );
}

class _KindAction extends StatelessWidget {
  const _KindAction({
    required this.kind,
    required this.selected,
    required this.focusNode,
    required this.onPressed,
    required this.onLeft,
    required this.onRight,
    required this.onUp,
    required this.onDown,
  });
  final SourceMediaKind kind;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onPressed;
  final VoidCallback onLeft, onRight, onUp, onDown;
  @override
  Widget build(BuildContext context) => _DirectionalShortcuts(
    onActivate: onPressed,
    onLeft: onLeft,
    onRight: onRight,
    onUp: onUp,
    onDown: onDown,
    child: OutlinedButton(
      key: ValueKey('visibility-kind-${kind.name}'),
      focusNode: focusNode,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? _amberInk : _warmWhite,
        backgroundColor: selected ? _amber : _surface,
        minimumSize: const Size(104, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ).copyWith(side: _buttonSide(primary: selected)),
      child: Text(kind.label),
    ),
  );
}

class _DirectionalShortcuts extends StatelessWidget {
  const _DirectionalShortcuts({
    required this.child,
    required this.onActivate,
    this.onLeft,
    this.onRight,
    this.onUp,
    this.onDown,
  });

  final Widget child;
  final VoidCallback onActivate;
  final VoidCallback? onLeft, onRight, onUp, onDown;

  @override
  Widget build(BuildContext context) {
    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.select): onActivate,
    };
    if (onLeft case final callback?) {
      bindings[const SingleActivator(LogicalKeyboardKey.arrowLeft)] = callback;
    }
    if (onRight case final callback?) {
      bindings[const SingleActivator(LogicalKeyboardKey.arrowRight)] = callback;
    }
    if (onUp case final callback?) {
      bindings[const SingleActivator(LogicalKeyboardKey.arrowUp)] = callback;
    }
    if (onDown case final callback?) {
      bindings[const SingleActivator(LogicalKeyboardKey.arrowDown)] = callback;
    }
    return CallbackShortcuts(bindings: bindings, child: child);
  }
}

WidgetStateProperty<BorderSide> _buttonSide({bool primary = false}) =>
    WidgetStateProperty.resolveWith(
      (states) => BorderSide(
        color: states.contains(WidgetState.focused)
            ? (primary ? _warmWhite : _amber)
            : (primary ? _amber : _line),
        width: 2,
      ),
    );

class _VisibilitySkeleton extends StatelessWidget {
  const _VisibilitySkeleton();
  @override
  Widget build(BuildContext context) => const Row(
    children: [
      SizedBox(width: 300, child: _SkeletonPanel()),
      SizedBox(width: 20),
      Expanded(child: _SkeletonPanel()),
    ],
  );
}

class _SkeletonPanel extends StatelessWidget {
  const _SkeletonPanel();
  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey('visibility-skeleton'),
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 7,
      itemExtent: 60,
      itemBuilder: (_, _) => const _ItemSkeleton(),
    ),
  );
}

class _LedgerSkeleton extends StatelessWidget {
  const _LedgerSkeleton();
  @override
  Widget build(BuildContext context) => ListView.builder(
    physics: const NeverScrollableScrollPhysics(),
    itemCount: 7,
    itemExtent: 60,
    itemBuilder: (_, _) => const _ItemSkeleton(),
  );
}

class _ItemSkeleton extends StatelessWidget {
  const _ItemSkeleton();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    child: Container(color: _raised),
  );
}

class _LoadMore extends StatelessWidget {
  const _LoadMore({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: TextButton(onPressed: onRetry, child: const Text('Load more')),
  );
}

class _NoItems extends StatelessWidget {
  const _NoItems({required this.hiddenOnly});
  final bool hiddenOnly;
  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      hiddenOnly
          ? 'No hidden items in this category.'
          : 'No available items in this category.',
      style: const TextStyle(color: _quietText, fontSize: 16),
    ),
  );
}

class _InlineItemFailure extends StatelessWidget {
  const _InlineItemFailure({
    required this.focusNode,
    required this.onRetry,
    required this.onUp,
    required this.onLeft,
  });

  final FocusNode focusNode;
  final VoidCallback onRetry, onUp, onLeft;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Items could not be loaded',
          style: TextStyle(
            color: _warmWhite,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Try this local category again.',
          style: TextStyle(color: _quietText, fontSize: 14),
        ),
        const SizedBox(height: 16),
        _QuietAction(
          label: 'Retry items',
          focusNode: focusNode,
          onPressed: onRetry,
          onUp: onUp,
          onLeft: onLeft,
        ),
      ],
    ),
  );
}

class _InitialLoadFailure extends StatelessWidget {
  const _InitialLoadFailure({
    required this.focusNode,
    required this.onRetry,
    required this.onUp,
  });

  final FocusNode focusNode;
  final VoidCallback onRetry, onUp;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Visibility could not be loaded',
          style: TextStyle(
            color: _warmWhite,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Try again. Your local visibility preferences are unchanged.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _quietText, fontSize: 16),
        ),
        const SizedBox(height: 18),
        _QuietAction(
          label: 'Retry',
          focusNode: focusNode,
          onPressed: onRetry,
          onUp: onUp,
        ),
      ],
    ),
  );
}

class _EmptyVisibility extends StatelessWidget {
  const _EmptyVisibility({
    required this.hiddenOnly,
    required this.focusNode,
    required this.onClear,
  });
  final bool hiddenOnly;
  final FocusNode focusNode;
  final VoidCallback? onClear;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          hiddenOnly ? 'Nothing is hidden' : 'No provider categories',
          style: const TextStyle(
            color: _warmWhite,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          hiddenOnly
              ? 'Turn off Hidden only to return to your full local library.'
              : 'This source has no imported categories or items yet.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: _quietText, fontSize: 16),
        ),
        if (onClear != null) ...[
          const SizedBox(height: 18),
          _QuietAction(
            label: 'Show all entries',
            focusNode: focusNode,
            onPressed: onClear!,
          ),
        ],
      ],
    ),
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

enum _DirectoryLoadResult { success, failed, superseded }

enum _ItemLoadResult { success, failed, superseded }

enum _BulkFailureStage { write, refresh }

class _VisibilitySnapshot {
  const _VisibilitySnapshot({
    required this.kind,
    required this.hiddenOnly,
    required this.categories,
    required this.allCategories,
    required this.selected,
    required this.items,
    required this.nextCursor,
    required this.itemLoadFailed,
  });

  final SourceMediaKind kind;
  final bool hiddenOnly;
  final List<LibraryVisibilityCategory> categories;
  final List<LibraryVisibilityCategory> allCategories;
  final LibraryVisibilityCategory? selected;
  final List<LibraryVisibilityItem> items;
  final String? nextCursor;
  final bool itemLoadFailed;
}

String _categoryIdentity(LibraryVisibilityCategoryRef ref) =>
    ref.sourceGroupId ?? '__uncategorized__';

String _formatCount(int value) => value.toString().replaceAllMapped(
  RegExp(r'(?<!^)(?=(?:\d{3})+$)'),
  (_) => ',',
);
