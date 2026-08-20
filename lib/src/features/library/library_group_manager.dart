import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sources/source_models.dart';
import 'library_organization_service.dart';

const _graphite = Color(0xFF111212);
const _surface = Color(0xFF191A1A);
const _raised = Color(0xFF222321);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);

class LibraryGroupManagementRequest {
  const LibraryGroupManagementRequest.create() : group = null;

  const LibraryGroupManagementRequest.manage(this.group);

  final PersonalLibraryDirectoryEntry? group;
  bool get creating => group == null;
}

class LibraryGroupManagerPane extends StatefulWidget {
  const LibraryGroupManagerPane({
    super.key,
    required this.request,
    required this.port,
    required this.onClose,
    required this.onChanged,
    required this.onBusyChanged,
  });

  final LibraryGroupManagementRequest request;
  final LibraryOrganizationPort port;
  final VoidCallback onClose;
  final VoidCallback onChanged;
  final ValueChanged<bool> onBusyChanged;

  @override
  State<LibraryGroupManagerPane> createState() =>
      _LibraryGroupManagerPaneState();
}

class _LibraryGroupManagerPaneState extends State<LibraryGroupManagerPane> {
  static const _pageSize = 100;

  final TextEditingController _name = TextEditingController();
  final FocusNode _nameFocus = FocusNode(debugLabel: 'group manager name');
  final FocusNode _primaryFocus = FocusNode(
    debugLabel: 'group manager primary',
  );
  final FocusNode _secondaryFocus = FocusNode(
    debugLabel: 'group manager secondary',
  );
  final FocusNode _moveGroupUpFocus = FocusNode(
    debugLabel: 'group manager move group up',
  );
  final FocusNode _moveGroupDownFocus = FocusNode(
    debugLabel: 'group manager move group down',
  );
  final FocusNode _moveShelfUpFocus = FocusNode(
    debugLabel: 'group manager move shelf up',
  );
  final FocusNode _moveShelfDownFocus = FocusNode(
    debugLabel: 'group manager move shelf down',
  );
  final FocusNode _itemUpFocus = FocusNode(debugLabel: 'group manager item up');
  final FocusNode _itemDownFocus = FocusNode(
    debugLabel: 'group manager item down',
  );
  final FocusNode _itemRemoveFocus = FocusNode(
    debugLabel: 'group manager item remove',
  );
  final FocusNode _keyboardFirstFocus = FocusNode(
    debugLabel: 'group keyboard A',
  );
  final ScrollController _itemScroll = ScrollController();
  final Map<String, FocusNode> _mountedItemNodes = {};

  PersonalLibraryDirectoryEntry? _group;
  List<PersonalLibraryItem> _items = const [];
  CustomGroupPageCursor? _nextCursor;
  String? _selectedItemId;
  String? _message;
  Future<void>? _activeLoad;
  bool _loading = false;
  bool _loadingMore = false;
  bool _initialItemLoadFailed = false;
  bool _postCommitRefreshFailed = false;
  bool _busy = false;
  bool _editingName = false;
  bool _keyboardOpen = false;
  bool _confirmDelete = false;
  bool _itemOrder = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _group = widget.request.group;
    _name.text = _group?.name ?? '';
    _editingName = widget.request.creating;
    if (widget.request.creating) {
      _focusAfterBuild(_nameFocus);
    } else {
      if (_group!.kind == PersonalLibraryDirectoryKind.customGroup) {
        unawaited(_loadItems(reset: true));
      }
      _focusAfterBuild(_primaryFocus);
    }
  }

  @override
  void dispose() {
    widget.onBusyChanged(false);
    _name.dispose();
    _nameFocus.dispose();
    _primaryFocus.dispose();
    _secondaryFocus.dispose();
    _moveGroupUpFocus.dispose();
    _moveGroupDownFocus.dispose();
    _moveShelfUpFocus.dispose();
    _moveShelfDownFocus.dispose();
    _itemUpFocus.dispose();
    _itemDownFocus.dispose();
    _itemRemoveFocus.dispose();
    _keyboardFirstFocus.dispose();
    _itemScroll.dispose();
    super.dispose();
  }

  void _focusAfterBuild(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && node.canRequestFocus) node.requestFocus();
    });
  }

  void _setBusy(bool value) {
    if (_busy == value) return;
    setState(() => _busy = value);
    widget.onBusyChanged(value);
  }

  void _close() {
    if (_busy) return;
    if (_keyboardOpen) {
      setState(() => _keyboardOpen = false);
      _focusAfterBuild(_nameFocus);
      return;
    }
    if (_confirmDelete) {
      _cancelDelete();
      return;
    }
    if (_editingName && !widget.request.creating) {
      setState(() {
        _editingName = false;
        _name.text = _group!.name;
        _message = null;
      });
      _focusAfterBuild(_primaryFocus);
      return;
    }
    widget.onClose();
  }

  void _cancelDelete() {
    setState(() => _confirmDelete = false);
    _focusAfterBuild(_secondaryFocus);
  }

  Future<void> _loadItems({
    required bool reset,
    bool clearMessage = true,
  }) async {
    final pending = _activeLoad;
    if (pending != null) {
      if (!reset) {
        await pending;
        return;
      }
      await pending;
      if (!mounted) return;
    }
    final load = _performItemLoad(reset: reset, clearMessage: clearMessage);
    _activeLoad = load;
    try {
      await load;
    } finally {
      if (identical(_activeLoad, load)) _activeLoad = null;
    }
  }

  Future<void> _performItemLoad({
    required bool reset,
    required bool clearMessage,
  }) async {
    final group = _group;
    if (group == null) return;
    final request = ++_request;
    setState(() {
      if (reset) {
        _loading = true;
        _initialItemLoadFailed = false;
        if (clearMessage) _message = null;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final page = await widget.port.loadGroupItems(
        groupId: group.collectionId!,
        cursor: reset ? null : _nextCursor,
        limit: _pageSize,
      );
      if (!mounted || request != _request) return;
      final next = reset ? page.items : [..._items, ...page.items];
      setState(() {
        _items = List.unmodifiable(next);
        _nextCursor = page.nextCursor;
        _selectedItemId = next.isEmpty
            ? null
            : next.any((item) => item.libraryItemId == _selectedItemId)
            ? _selectedItemId
            : next.first.libraryItemId;
        _loading = false;
        _loadingMore = false;
        _initialItemLoadFailed = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (reset) {
          _initialItemLoadFailed = true;
        } else {
          _message = 'Could not load more items. Try again.';
        }
      });
    }
  }

  Future<void> _createOrRename() async {
    if (_busy) return;
    _setBusy(true);
    try {
      final result = widget.request.creating
          ? await widget.port.createGroup(_name.text)
          : await widget.port.renameGroup(
              groupId: _group!.collectionId!,
              name: _name.text,
            );
      if (!mounted) return;
      if (result.succeeded) {
        final updated = result.collection;
        if (updated != null) _group = updated;
        var refreshed = true;
        if (!widget.request.creating &&
            updated == null &&
            result.outcome == PersonalLibraryMutationOutcome.changed) {
          refreshed = await _refreshGroupAfterCommit();
          if (!mounted) return;
        }
        if (result.outcome == PersonalLibraryMutationOutcome.changed) {
          widget.onChanged();
        }
        if (widget.request.creating) {
          widget.onBusyChanged(false);
          setState(() => _busy = false);
          widget.onClose();
          return;
        }
        setState(() {
          _editingName = false;
          _postCommitRefreshFailed = !refreshed;
          _message = !refreshed
              ? 'The name was saved locally; this view could not refresh.'
              : result.outcome == PersonalLibraryMutationOutcome.unchanged
              ? 'Name unchanged.'
              : 'Group renamed.';
        });
      } else {
        setState(
          () => _message = switch (result.outcome) {
            PersonalLibraryMutationOutcome.invalidName =>
              'Use a group name between 1 and 80 characters.',
            PersonalLibraryMutationOutcome.duplicateName =>
              'A group with that name already exists.',
            PersonalLibraryMutationOutcome.limitReached =>
              'The local group limit has been reached.',
            PersonalLibraryMutationOutcome.missingGroup =>
              'This group is no longer available.',
            _ => 'The group was not changed. Try again.',
          },
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'The group was not changed. Try again.');
      }
    } finally {
      if (mounted && _busy) {
        _setBusy(false);
        _focusAfterBuild(_editingName ? _nameFocus : _primaryFocus);
      }
    }
  }

  Future<PersonalLibraryMutationResult?> _mutate(
    Future<PersonalLibraryMutationResult> Function() operation, {
    required String changedMessage,
    FocusNode? restoreFocus,
    bool refreshGroup = true,
    Future<void> Function()? afterChanged,
  }) async {
    if (_busy) return null;
    _setBusy(true);
    try {
      final pendingLoad = _activeLoad;
      if (pendingLoad != null) await pendingLoad;
      if (!mounted) return null;
      final result = await operation();
      if (!mounted) return null;
      if (!result.succeeded) {
        setState(() {
          _postCommitRefreshFailed = false;
          _message = 'The local change was not saved. Try again.';
        });
        return result;
      }
      if (result.outcome == PersonalLibraryMutationOutcome.unchanged) {
        setState(() {
          _postCommitRefreshFailed = false;
          _message = 'Already in that position or state.';
        });
        return result;
      }
      if (result.collection != null) _group = result.collection;
      widget.onChanged();
      final refreshed = !refreshGroup || await _refreshGroupAfterCommit();
      if (!mounted) return null;
      setState(() {
        _postCommitRefreshFailed = !refreshed;
        _message = refreshed
            ? changedMessage
            : 'The change was saved locally; this view could not refresh.';
      });
      await afterChanged?.call();
      return result;
    } catch (_) {
      if (mounted) {
        setState(() {
          _postCommitRefreshFailed = false;
          _message = 'The local change was not saved. Try again.';
        });
      }
      return null;
    } finally {
      if (mounted && _busy) {
        _setBusy(false);
        if (restoreFocus != null) _focusAfterBuild(restoreFocus);
      }
    }
  }

  Future<void> _retryCommittedRead() async {
    if (_busy) return;
    _setBusy(true);
    try {
      final refreshed = await _refreshGroupAfterCommit();
      if (!mounted) return;
      setState(() {
        _postCommitRefreshFailed = !refreshed;
        _message = refreshed
            ? 'View refreshed. The local change remains saved.'
            : 'The change is saved locally; this view still could not refresh.';
      });
    } finally {
      if (mounted && _busy) {
        _setBusy(false);
        _focusAfterBuild(_primaryFocus);
      }
    }
  }

  Future<void> _delete() async {
    final group = _group!;
    await _mutate(
      () => widget.port.deleteGroup(group.collectionId!),
      changedMessage: 'Group removed. Its items remain in Wabbit.',
      refreshGroup: false,
    );
    if (!mounted || _message?.startsWith('Group removed') != true) return;
    widget.onClose();
  }

  Future<bool> _refreshGroupAfterCommit() async {
    final current = _group;
    if (current == null) return true;
    final key = current.reference.key;
    try {
      final directory = await widget.port.loadDirectory(limit: 200);
      final refreshed = directory
          .where((entry) => entry.reference.key == key)
          .firstOrNull;
      if (refreshed != null) _group = refreshed;
      return refreshed != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _mutateSelectedItem(
    Future<PersonalLibraryMutationResult> Function(String id) operation,
    String message, {
    bool preserveIdentity = true,
  }) async {
    final id = _selectedItemId;
    if (id == null) return;
    var loadedCount = _items.length;
    final priorIndex = _items.indexWhere((item) => item.libraryItemId == id);
    final result = await _mutate(
      () async {
        loadedCount = _items.length;
        return operation(id);
      },
      changedMessage: message,
      afterChanged: () async {
        await _reloadLoadedItemWindow(
          loadedCount,
          selectedId: preserveIdentity ? id : null,
        );
        if (!mounted || _items.isEmpty) return;
        final retainedIndex = _items.indexWhere(
          (item) => item.libraryItemId == id,
        );
        final targetIndex = retainedIndex >= 0
            ? retainedIndex
            : priorIndex.clamp(0, _items.length - 1);
        setState(() => _selectedItemId = _items[targetIndex].libraryItemId);
        _requestItemFocus(targetIndex);
      },
    );
    if (!mounted ||
        result?.outcome != PersonalLibraryMutationOutcome.unchanged) {
      return;
    }
    _requestItemFocus(priorIndex);
  }

  Future<void> _reloadLoadedItemWindow(
    int desiredCount, {
    String? selectedId,
  }) async {
    await _loadItems(reset: true, clearMessage: false);
    while (mounted &&
        !_initialItemLoadFailed &&
        _nextCursor != null &&
        _items.length < desiredCount) {
      await _loadItems(reset: false, clearMessage: false);
    }
    final selectedLoaded =
        selectedId == null ||
        _items.any((item) => item.libraryItemId == selectedId);
    if (mounted &&
        !_initialItemLoadFailed &&
        !selectedLoaded &&
        _nextCursor != null) {
      // A one-step move may cross the prior window boundary. Fetch exactly
      // one more bounded page to recover that identity, never the full group.
      await _loadItems(reset: false, clearMessage: false);
    }
  }

  void _registerItemNode(String id, FocusNode node) {
    _mountedItemNodes[id] = node;
  }

  void _unregisterItemNode(String id, FocusNode node) {
    if (identical(_mountedItemNodes[id], node)) {
      _mountedItemNodes.remove(id);
    }
  }

  void _requestItemFocus(int index) {
    if (index < 0 || index >= _items.length) return;
    final id = _items[index].libraryItemId;
    void request() {
      final node = _mountedItemNodes[id];
      if (mounted && node != null && node.canRequestFocus) {
        node.requestFocus();
      }
    }

    if (_itemScroll.hasClients) {
      final position = _itemScroll.position;
      final centered = index * 56.0 - position.viewportDimension / 2 + 28;
      _itemScroll.jumpTo(centered.clamp(0.0, position.maxScrollExtent));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => request());
  }

  Future<void> _moveItemFocus(int index, int delta) async {
    var target = index + delta;
    if (target < 0) return;
    if (target >= _items.length && delta > 0 && _nextCursor != null) {
      await _loadItems(reset: false);
      if (!mounted) return;
    }
    if (_items.isEmpty) return;
    target = target.clamp(0, _items.length - 1);
    setState(() => _selectedItemId = _items[target].libraryItemId);
    _requestItemFocus(target);
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): _close,
      const SingleActivator(LogicalKeyboardKey.browserBack): _close,
    },
    child: Material(
      color: _graphite,
      child: SafeArea(
        left: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const Divider(height: 1, color: _line),
            Expanded(
              child: widget.request.creating || _editingName
                  ? _nameEditor()
                  : _manageBody(),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 10, 14),
    child: Row(
      children: [
        Expanded(
          child: Text(
            widget.request.creating
                ? 'Create group'
                : _group?.kind == PersonalLibraryDirectoryKind.favorites
                ? 'Manage Favorites'
                : 'Manage group',
            style: const TextStyle(
              color: _warmWhite,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          tooltip: _busy ? 'Wait for the local save' : 'Close',
          onPressed: _busy ? null : _close,
          icon: const Icon(Icons.close, color: _warmWhite),
        ),
      ],
    ),
  );

  Widget _nameEditor() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        widget.request.creating ? 'Name your group' : 'Rename ${_group!.name}',
        style: const TextStyle(
          color: _warmWhite,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Groups may contain Live, Movies, and Series together.',
        style: TextStyle(color: _quietText, fontSize: 14),
      ),
      const SizedBox(height: 18),
      Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent ||
              event.logicalKey != LogicalKeyboardKey.arrowDown) {
            return KeyEventResult.ignored;
          }
          if (!_keyboardOpen) setState(() => _keyboardOpen = true);
          _focusAfterBuild(_keyboardFirstFocus);
          return KeyEventResult.handled;
        },
        child: TextField(
          key: const ValueKey('group-name-field'),
          controller: _name,
          focusNode: _nameFocus,
          enabled: !_busy,
          maxLength: 80,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(color: _warmWhite),
          decoration: InputDecoration(
            labelText: 'Group name',
            labelStyle: const TextStyle(color: _quietText),
            filled: true,
            fillColor: _surface,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: _line, width: 2),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: _amber, width: 2),
            ),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _ManagerAction(
            label: _keyboardOpen ? 'Hide TV keyboard' : 'TV keyboard',
            enabled: !_busy,
            onPressed: () {
              final opening = !_keyboardOpen;
              setState(() => _keyboardOpen = opening);
              _focusAfterBuild(opening ? _keyboardFirstFocus : _nameFocus);
            },
          ),
          _ManagerAction(label: 'Cancel', enabled: !_busy, onPressed: _close),
          _ManagerAction(
            label: _busy
                ? 'Saving…'
                : widget.request.creating
                ? 'Create'
                : 'Save name',
            enabled: !_busy && _name.text.trim().isNotEmpty,
            primary: true,
            onPressed: _createOrRename,
          ),
        ],
      ),
      if (_message != null) ...[
        const SizedBox(height: 14),
        _LiveMessage(_message!),
      ],
      if (_keyboardOpen) ...[
        const SizedBox(height: 18),
        _TvNameKeyboard(
          firstFocusNode: _keyboardFirstFocus,
          onText: (text) {
            _name.text += text;
            _name.selection = TextSelection.collapsed(
              offset: _name.text.length,
            );
            setState(() {});
          },
          onBackspace: () {
            if (_name.text.isEmpty) return;
            _name.text = _name.text.substring(0, _name.text.length - 1);
            _name.selection = TextSelection.collapsed(
              offset: _name.text.length,
            );
            setState(() {});
          },
          onClear: () => setState(_name.clear),
          onDone: () {
            setState(() => _keyboardOpen = false);
            _focusAfterBuild(_nameFocus);
          },
        ),
      ],
    ],
  );

  Widget _manageBody() {
    final group = _group!;
    if (group.kind == PersonalLibraryDirectoryKind.favorites) {
      return _manageFavoritesBody(group);
    }
    if (_confirmDelete) return _deleteConfirmation(group);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactItemToolbar = constraints.maxWidth < 600;
        final itemToolbarHeight = compactItemToolbar ? 109.0 : 61.0;
        const ledgerReserve = 56.0;
        final headerMaxHeight =
            (constraints.maxHeight -
                    (_itemOrder ? itemToolbarHeight : 0) -
                    ledgerReserve -
                    1)
                .clamp(0.0, 310.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: headerMaxHeight),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _warmWhite,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${group.itemCount} items · ${group.isPinned ? 'Pinned to Home' : 'Not pinned'}',
                      style: const TextStyle(color: _quietText, fontSize: 13),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _ManagerAction(
                          focusNode: _primaryFocus,
                          label: 'Rename',
                          enabled: !_busy,
                          onPressed: () => setState(() => _editingName = true),
                        ),
                        _ManagerAction(
                          label: group.isPinned ? 'Unpin Home' : 'Pin to Home',
                          enabled: !_busy,
                          onPressed: () => _mutate(
                            () => widget.port.setPinned(
                              collection: group.reference,
                              pinned: !group.isPinned,
                            ),
                            changedMessage: group.isPinned
                                ? 'Group removed from Home. Its items are unchanged.'
                                : 'Group pinned to Home.',
                          ),
                        ),
                        _ManagerAction(
                          focusNode: _secondaryFocus,
                          label: 'Delete',
                          enabled: !_busy,
                          onPressed: () {
                            setState(() => _confirmDelete = true);
                            _focusAfterBuild(_primaryFocus);
                          },
                        ),
                        _ManagerAction(
                          label: _itemOrder ? 'Done ordering' : 'Order items',
                          enabled: !_busy && _items.isNotEmpty,
                          onPressed: () =>
                              setState(() => _itemOrder = !_itemOrder),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _ManagerAction(
                          focusNode: _moveGroupUpFocus,
                          label: 'Group up',
                          enabled: !_busy,
                          onPressed: () => _mutate(
                            () => widget.port.moveGroup(
                              groupId: group.collectionId!,
                              direction: PersonalLibraryMoveDirection.up,
                            ),
                            changedMessage: 'Group moved up.',
                            restoreFocus: _moveGroupUpFocus,
                          ),
                        ),
                        _ManagerAction(
                          focusNode: _moveGroupDownFocus,
                          label: 'Group down',
                          enabled: !_busy,
                          onPressed: () => _mutate(
                            () => widget.port.moveGroup(
                              groupId: group.collectionId!,
                              direction: PersonalLibraryMoveDirection.down,
                            ),
                            changedMessage: 'Group moved down.',
                            restoreFocus: _moveGroupDownFocus,
                          ),
                        ),
                        if (group.isPinned) ...[
                          _ManagerAction(
                            focusNode: _moveShelfUpFocus,
                            label: 'Home shelf up',
                            enabled: !_busy,
                            onPressed: () => _mutate(
                              () => widget.port.movePinned(
                                collection: group.reference,
                                direction: PersonalLibraryMoveDirection.up,
                              ),
                              changedMessage: 'Home shelf moved up.',
                              restoreFocus: _moveShelfUpFocus,
                            ),
                          ),
                          _ManagerAction(
                            focusNode: _moveShelfDownFocus,
                            label: 'Home shelf down',
                            enabled: !_busy,
                            onPressed: () => _mutate(
                              () => widget.port.movePinned(
                                collection: group.reference,
                                direction: PersonalLibraryMoveDirection.down,
                              ),
                              changedMessage: 'Home shelf moved down.',
                              restoreFocus: _moveShelfDownFocus,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (_message != null) ...[
                      const SizedBox(height: 12),
                      _LiveMessage(_message!),
                    ],
                    if (_postCommitRefreshFailed) ...[
                      const SizedBox(height: 8),
                      _ManagerAction(
                        label: _busy ? 'Refreshing…' : 'Retry view',
                        enabled: !_busy,
                        onPressed: _retryCommittedRead,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: _line),
            if (_itemOrder && _selectedItemId != null)
              SizedBox(
                height: itemToolbarHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                  child: _itemOrderActions(group, compact: compactItemToolbar),
                ),
              ),
            Expanded(child: _itemLedger(group)),
          ],
        );
      },
    );
  }

  Widget _itemOrderActions(
    PersonalLibraryDirectoryEntry group, {
    required bool compact,
  }) {
    final moveUp = _ManagerAction(
      focusNode: _itemUpFocus,
      label: 'Move item up',
      enabled: !_busy,
      onPressed: () => _mutateSelectedItem(
        (id) => widget.port.moveGroupItem(
          groupId: group.collectionId!,
          libraryItemId: id,
          direction: PersonalLibraryMoveDirection.up,
        ),
        'Item moved up.',
      ),
    );
    final moveDown = _ManagerAction(
      focusNode: _itemDownFocus,
      label: 'Move item down',
      enabled: !_busy,
      onPressed: () => _mutateSelectedItem(
        (id) => widget.port.moveGroupItem(
          groupId: group.collectionId!,
          libraryItemId: id,
          direction: PersonalLibraryMoveDirection.down,
        ),
        'Item moved down.',
      ),
    );
    final remove = _ManagerAction(
      focusNode: _itemRemoveFocus,
      label: 'Remove from group',
      enabled: !_busy,
      onPressed: () => _mutateSelectedItem(
        (id) => widget.port.removeGroupItem(
          groupId: group.collectionId!,
          libraryItemId: id,
        ),
        'Item removed from this group. It remains in Wabbit.',
        preserveIdentity: false,
      ),
    );
    if (!compact) {
      return Row(
        children: [
          Expanded(child: moveUp),
          const SizedBox(width: 8),
          Expanded(child: moveDown),
          const SizedBox(width: 8),
          Expanded(child: remove),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: moveUp),
            const SizedBox(width: 8),
            Expanded(child: moveDown),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(child: remove),
      ],
    );
  }

  Widget _manageFavoritesBody(
    PersonalLibraryDirectoryEntry favorites,
  ) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Text(
        'Favorites',
        style: TextStyle(
          color: _warmWhite,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        '${favorites.itemCount} items · newest saved first',
        style: const TextStyle(color: _quietText, fontSize: 14),
      ),
      const SizedBox(height: 8),
      const Text(
        'Pin Favorites to Home or change its place among pinned shelves. Favorite item order is automatic.',
        style: TextStyle(color: _quietText, fontSize: 14, height: 1.4),
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _ManagerAction(
            focusNode: _primaryFocus,
            label: favorites.isPinned ? 'Unpin Home' : 'Pin to Home',
            enabled: !_busy,
            onPressed: () => _mutate(
              () => widget.port.setPinned(
                collection: favorites.reference,
                pinned: !favorites.isPinned,
              ),
              changedMessage: favorites.isPinned
                  ? 'Favorites removed from Home. Saved items are unchanged.'
                  : 'Favorites pinned to Home.',
              restoreFocus: _primaryFocus,
            ),
          ),
          if (favorites.isPinned) ...[
            _ManagerAction(
              focusNode: _moveShelfUpFocus,
              label: 'Home shelf up',
              enabled: !_busy,
              onPressed: () => _mutate(
                () => widget.port.movePinned(
                  collection: favorites.reference,
                  direction: PersonalLibraryMoveDirection.up,
                ),
                changedMessage: 'Favorites shelf moved up.',
                restoreFocus: _moveShelfUpFocus,
              ),
            ),
            _ManagerAction(
              focusNode: _moveShelfDownFocus,
              label: 'Home shelf down',
              enabled: !_busy,
              onPressed: () => _mutate(
                () => widget.port.movePinned(
                  collection: favorites.reference,
                  direction: PersonalLibraryMoveDirection.down,
                ),
                changedMessage: 'Favorites shelf moved down.',
                restoreFocus: _moveShelfDownFocus,
              ),
            ),
          ],
        ],
      ),
      if (_message != null) ...[
        const SizedBox(height: 16),
        _LiveMessage(_message!),
      ],
      if (_postCommitRefreshFailed) ...[
        const SizedBox(height: 8),
        _ManagerAction(
          label: _busy ? 'Refreshing…' : 'Retry view',
          enabled: !_busy,
          onPressed: _retryCommittedRead,
        ),
      ],
    ],
  );

  Widget _itemLedger(PersonalLibraryDirectoryEntry group) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: _amber),
      );
    }
    if (_initialItemLoadFailed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Could not load this local group.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _quietText, fontSize: 14),
              ),
              const SizedBox(height: 12),
              _ManagerAction(
                label: 'Retry items',
                enabled: !_busy,
                onPressed: () => _loadItems(reset: true),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'This group is empty. Organize an item to add it here.',
            style: TextStyle(color: _quietText, fontSize: 14),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _itemScroll,
      itemExtent: 56,
      itemCount: _items.length + (_nextCursor != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _items.length) {
          return Center(
            child: _ManagerAction(
              label: _loadingMore ? 'Loading…' : 'Load more',
              enabled: !_busy && !_loadingMore,
              onPressed: () => _loadItems(reset: false),
            ),
          );
        }
        final item = _items[index];
        final selected = item.libraryItemId == _selectedItemId;
        return _GroupManagerItemRow(
          key: ValueKey('group manager item ${item.libraryItemId}'),
          item: item,
          selected: selected,
          itemOrder: _itemOrder,
          onRegister: (node) => _registerItemNode(item.libraryItemId, node),
          onUnregister: (node) => _unregisterItemNode(item.libraryItemId, node),
          onFocused: () {
            if (_selectedItemId != item.libraryItemId) {
              setState(() => _selectedItemId = item.libraryItemId);
            }
          },
          onMove: (delta) => _moveItemFocus(index, delta),
          onMoveToActions: () => _itemUpFocus.requestFocus(),
        );
      },
    );
  }

  Widget _deleteConfirmation(PersonalLibraryDirectoryEntry group) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Delete ${group.name}?',
          style: const TextStyle(
            color: _warmWhite,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'The group will be removed. Its items remain in Wabbit and in their sources.',
          style: TextStyle(color: _quietText, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: _ManagerAction(
                focusNode: _primaryFocus,
                label: 'Cancel',
                enabled: !_busy,
                primary: true,
                onPressed: _cancelDelete,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ManagerAction(
                focusNode: _secondaryFocus,
                label: _busy ? 'Deleting…' : 'Delete group',
                enabled: !_busy,
                onPressed: _delete,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _GroupManagerItemRow extends StatefulWidget {
  const _GroupManagerItemRow({
    super.key,
    required this.item,
    required this.selected,
    required this.itemOrder,
    required this.onRegister,
    required this.onUnregister,
    required this.onFocused,
    required this.onMove,
    required this.onMoveToActions,
  });

  final PersonalLibraryItem item;
  final bool selected;
  final bool itemOrder;
  final ValueChanged<FocusNode> onRegister;
  final ValueChanged<FocusNode> onUnregister;
  final VoidCallback onFocused;
  final ValueChanged<int> onMove;
  final VoidCallback onMoveToActions;

  @override
  State<_GroupManagerItemRow> createState() => _GroupManagerItemRowState();
}

class _GroupManagerItemRowState extends State<_GroupManagerItemRow> {
  late final FocusNode _focusNode;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      debugLabel: 'group manager item ${widget.item.libraryItemId}',
    );
    widget.onRegister(_focusNode);
  }

  @override
  void dispose() {
    widget.onUnregister(_focusNode);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    onFocusChange: (focused) {
      if (_focused != focused) setState(() => _focused = focused);
      if (focused) widget.onFocused();
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
        case LogicalKeyboardKey.arrowRight:
          if (!widget.itemOrder) return KeyEventResult.ignored;
          widget.onMoveToActions();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
          widget.onFocused();
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    },
    child: Semantics(
      button: true,
      selected: widget.selected,
      label:
          '${widget.item.title}, ${_groupItemKindLabel(widget.item.kind)}${widget.item.isAvailable ? '' : ', unavailable'}',
      child: InkWell(
        onTap: () {
          _focusNode.requestFocus();
          widget.onFocused();
        },
        child: Container(
          key: ValueKey('group-manager-item-${widget.item.libraryItemId}'),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _focused || widget.selected ? _raised : Colors.transparent,
            border: Border.all(
              color: _focused ? _amber : Colors.transparent,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(
                switch (widget.item.kind) {
                  SourceMediaKind.live => Icons.live_tv_outlined,
                  SourceMediaKind.movies => Icons.movie_outlined,
                  SourceMediaKind.series => Icons.tv_outlined,
                },
                color: widget.item.isAvailable ? _quietText : _line,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.item.isAvailable ? _warmWhite : _quietText,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                widget.item.isAvailable
                    ? _groupItemKindLabel(widget.item.kind)
                    : 'UNAVAILABLE',
                style: const TextStyle(
                  color: _quietText,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (widget.itemOrder) ...[
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right, color: _quietText, size: 20),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

String _groupItemKindLabel(SourceMediaKind kind) => switch (kind) {
  SourceMediaKind.live => 'LIVE',
  SourceMediaKind.movies => 'MOVIE',
  SourceMediaKind.series => 'SERIES',
};

class _ManagerAction extends StatelessWidget {
  const _ManagerAction({
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.focusNode,
    this.primary = false,
    this.onKeyEvent,
  });

  final String label;
  final bool enabled;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final bool primary;
  final KeyEventResult Function(KeyEvent event)? onKeyEvent;

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton(
      focusNode: focusNode,
      onFocusChange: (focused) {
        if (!focused) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          Scrollable.ensureVisible(
            context,
            duration: const Duration(milliseconds: 120),
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          );
        });
      },
      onPressed: enabled ? onPressed : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: primary ? _graphite : _warmWhite,
        backgroundColor: primary && enabled ? _amber : _raised,
        disabledForegroundColor: _quietText,
        side: BorderSide(color: primary && enabled ? _amber : _line, width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        minimumSize: const Size(108, 40),
      ),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    final handler = onKeyEvent;
    if (handler == null) return button;
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) => handler(event),
      child: button,
    );
  }
}

class _LiveMessage extends StatelessWidget {
  const _LiveMessage(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(message, style: const TextStyle(color: _amber, fontSize: 13)),
  );
}

class _TvNameKeyboard extends StatefulWidget {
  const _TvNameKeyboard({
    required this.firstFocusNode,
    required this.onText,
    required this.onBackspace,
    required this.onClear,
    required this.onDone,
  });

  final FocusNode firstFocusNode;
  final ValueChanged<String> onText;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onDone;

  static const _keys = <String>[
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
  ];

  @override
  State<_TvNameKeyboard> createState() => _TvNameKeyboardState();
}

class _TvNameKeyboardState extends State<_TvNameKeyboard> {
  late final List<FocusNode> _extraNodes = List.generate(
    39,
    (index) => FocusNode(debugLabel: 'group keyboard ${index + 1}'),
  );

  FocusNode _nodeAt(int index) =>
      index == 0 ? widget.firstFocusNode : _extraNodes[index - 1];

  @override
  void dispose() {
    for (final node in _extraNodes) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handleDirection(int index, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    int? target;
    if (index < 36) {
      final row = index ~/ 6;
      final column = index % 6;
      if (key == LogicalKeyboardKey.arrowLeft && column > 0) {
        target = index - 1;
      } else if (key == LogicalKeyboardKey.arrowRight && column < 5) {
        target = index + 1;
      } else if (key == LogicalKeyboardKey.arrowUp && row > 0) {
        target = index - 6;
      } else if (key == LogicalKeyboardKey.arrowDown) {
        if (row < 5) {
          target = index + 6;
        } else {
          target = switch (column) {
            0 || 1 => 36,
            2 => 37,
            3 => 38,
            _ => 39,
          };
        }
      }
    } else {
      if (key == LogicalKeyboardKey.arrowLeft && index > 36) {
        target = index - 1;
      } else if (key == LogicalKeyboardKey.arrowRight && index < 39) {
        target = index + 1;
      } else if (key == LogicalKeyboardKey.arrowUp) {
        target = switch (index) {
          36 => 30,
          37 => 32,
          38 => 33,
          _ => 35,
        };
      }
    }
    if (target == null) return KeyEventResult.ignored;
    _nodeAt(target).requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 6,
            mainAxisExtent: 32,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemCount: _TvNameKeyboard._keys.length,
          itemBuilder: (context, index) => _ManagerAction(
            focusNode: _nodeAt(index),
            label: _TvNameKeyboard._keys[index],
            enabled: true,
            onPressed: () => widget.onText(_TvNameKeyboard._keys[index]),
            onKeyEvent: (event) => _handleDirection(index, event),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _ManagerAction(
              focusNode: _nodeAt(36),
              label: 'Space',
              enabled: true,
              onPressed: () => widget.onText(' '),
              onKeyEvent: (event) => _handleDirection(36, event),
            ),
            _ManagerAction(
              focusNode: _nodeAt(37),
              label: 'Back',
              enabled: true,
              onPressed: widget.onBackspace,
              onKeyEvent: (event) => _handleDirection(37, event),
            ),
            _ManagerAction(
              focusNode: _nodeAt(38),
              label: 'Clear',
              enabled: true,
              onPressed: widget.onClear,
              onKeyEvent: (event) => _handleDirection(38, event),
            ),
            _ManagerAction(
              focusNode: _nodeAt(39),
              label: 'Done',
              enabled: true,
              primary: true,
              onPressed: widget.onDone,
              onKeyEvent: (event) => _handleDirection(39, event),
            ),
          ],
        ),
      ],
    ),
  );
}
