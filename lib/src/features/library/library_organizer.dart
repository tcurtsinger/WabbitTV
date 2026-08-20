import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../artwork/artwork_loader.dart';
import '../artwork/source_artwork.dart';
import '../sources/source_models.dart';
import 'library_organization_service.dart';

// THESIS: personal organization is one deliberate secondary action, not row
// chrome; the approved organizer drawer preserves the dense viewing ledger.
// OWN-WORLD: Quiet Broadcast graphite, warm white, quiet metadata, compact
// seams, and one precise amber focus edge with no modal or storefront layer.
// STORY: inspect the selected item, choose Favorite and several groups, Save.
// FIRST VIEWPORT: ledger remains dominant; a 320 px right drawer owns changes.
// FORM: A — Direct Organizer Drawer; phase4-library-organization-a.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md

const _graphite = Color(0xFF111212);
const _raised = Color(0xFF222321);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);

class LibraryOrganizerRequest {
  const LibraryOrganizerRequest({
    required this.libraryItemId,
    required this.title,
    required this.kind,
    this.artworkLocator,
  });

  final String libraryItemId;
  final String title;
  final SourceMediaKind kind;
  final String? artworkLocator;
}

class LibraryOrganizerPane extends StatefulWidget {
  const LibraryOrganizerPane({
    super.key,
    required this.request,
    required this.port,
    required this.onClose,
    required this.onSaved,
    required this.onBusyChanged,
    this.artworkLoader,
  });

  final LibraryOrganizerRequest request;
  final LibraryOrganizationPort port;
  final VoidCallback onClose;
  final VoidCallback onSaved;
  final ValueChanged<bool> onBusyChanged;
  final ArtworkProvider? artworkLoader;

  @override
  State<LibraryOrganizerPane> createState() => _LibraryOrganizerPaneState();
}

class _LibraryOrganizerPaneState extends State<LibraryOrganizerPane> {
  final FocusNode _favoriteFocus = FocusNode(
    debugLabel: 'library organizer favorite',
  );
  final FocusNode _retryFocus = FocusNode(
    debugLabel: 'library organizer retry',
  );
  final FocusNode _cancelFocus = FocusNode(
    debugLabel: 'library organizer cancel',
  );
  final FocusNode _saveFocus = FocusNode(debugLabel: 'library organizer save');
  final ScrollController _groupsScroll = ScrollController();
  final Map<String, FocusNode> _groupFocus = {};
  PersonalLibraryOrganization? _loaded;
  bool _favorite = false;
  Set<String> _selectedGroups = {};
  bool _loading = true;
  bool _saving = false;
  bool _failed = false;
  String? _recovery;
  int _request = 0;

  bool get _dirty {
    final loaded = _loaded;
    if (loaded == null) return false;
    final original = loaded.groups
        .where((group) => group.selected)
        .map((group) => group.groupId)
        .toSet();
    return _favorite != loaded.isFavorite ||
        original.length != _selectedGroups.length ||
        !original.containsAll(_selectedGroups);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LibraryOrganizerPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request.libraryItemId != widget.request.libraryItemId) {
      _disposeGroupNodes();
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    widget.onBusyChanged(false);
    _disposeGroupNodes();
    _favoriteFocus.dispose();
    _retryFocus.dispose();
    _cancelFocus.dispose();
    _saveFocus.dispose();
    _groupsScroll.dispose();
    super.dispose();
  }

  void _disposeGroupNodes() {
    for (final node in _groupFocus.values) {
      node.dispose();
    }
    _groupFocus.clear();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _failed = false;
      _recovery = null;
    });
    try {
      final loaded = await widget.port.loadItem(widget.request.libraryItemId);
      if (!mounted || request != _request) return;
      if (loaded == null) {
        setState(() {
          _loading = false;
          _failed = true;
          _recovery = 'This item is no longer available in the local library.';
        });
        _focusAfterBuild(_retryFocus);
        return;
      }
      _disposeGroupNodes();
      for (final group in loaded.groups) {
        _groupFocus[group.groupId] = FocusNode(
          debugLabel: 'library organizer group ${group.groupId}',
        );
      }
      setState(() {
        _loaded = loaded;
        _favorite = loaded.isFavorite;
        _selectedGroups = loaded.groups
            .where((group) => group.selected)
            .map((group) => group.groupId)
            .toSet();
        _loading = false;
      });
      _focusAfterBuild(_favoriteFocus);
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _failed = true;
        _recovery = 'Could not load local organization. Try again.';
      });
      _focusAfterBuild(_retryFocus);
    }
  }

  void _focusAfterBuild(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && node.canRequestFocus) node.requestFocus();
    });
  }

  void _close() {
    if (_saving) return;
    widget.onClose();
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    setState(() {
      _saving = true;
      _recovery = null;
    });
    widget.onBusyChanged(true);
    try {
      final result = await widget.port.saveItem(
        libraryItemId: widget.request.libraryItemId,
        favorite: _favorite,
        customGroupIds: _selectedGroups,
      );
      if (!mounted) return;
      if (result.succeeded) {
        widget.onBusyChanged(false);
        setState(() => _saving = false);
        widget.onSaved();
        return;
      }
      setState(() {
        _saving = false;
        _recovery = switch (result.outcome) {
          PersonalLibraryMutationOutcome.missingItem =>
            'This item is no longer available in the local library.',
          PersonalLibraryMutationOutcome.missingGroup =>
            'A selected group is no longer available. Reload and try again.',
          _ => 'Organization was not changed. Try again.',
        };
      });
      widget.onBusyChanged(false);
      _focusAfterBuild(_saveFocus);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _recovery = 'Organization was not changed. Try again.';
      });
      widget.onBusyChanged(false);
      _focusAfterBuild(_saveFocus);
    }
  }

  void _toggleFavorite() {
    if (_saving) return;
    setState(() => _favorite = !_favorite);
  }

  void _toggleGroup(String id) {
    if (_saving) return;
    setState(() {
      if (!_selectedGroups.add(id)) _selectedGroups.remove(id);
    });
  }

  void _focusGroup(int index) {
    final groups = _loaded?.groups ?? const <PersonalLibraryGroupChoice>[];
    if (index < 0 || index >= groups.length) return;
    final node = _groupFocus[groups[index].groupId];
    if (node == null) return;
    if (_groupsScroll.hasClients) {
      final position = _groupsScroll.position;
      final centered = index * 48.0 - position.viewportDimension / 2 + 24;
      _groupsScroll.jumpTo(centered.clamp(0.0, position.maxScrollExtent));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && node.canRequestFocus) node.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): _close,
      const SingleActivator(LogicalKeyboardKey.browserBack): _close,
    },
    child: FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: Material(
        color: _graphite,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: _line)),
          ),
          child: SafeArea(
            left: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                const Divider(height: 1, color: _line),
                _itemSummary(),
                const Divider(height: 1, color: _line),
                Expanded(child: _body()),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 10, 14),
    child: Row(
      children: [
        const Expanded(
          child: Text(
            'Organize item',
            style: TextStyle(
              color: _warmWhite,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          tooltip: _saving ? 'Wait for the local save' : 'Close organizer',
          onPressed: _saving ? null : _close,
          icon: const Icon(Icons.close, color: _warmWhite),
        ),
      ],
    ),
  );

  Widget _itemSummary() => Padding(
    padding: const EdgeInsets.all(20),
    child: Row(
      children: [
        SourceArtwork(
          locator: widget.request.artworkLocator,
          kind: widget.request.kind,
          loader: widget.artworkLoader,
          focused: true,
          width: 80,
          height: 56,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.request.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _warmWhite,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.request.kind.label.toUpperCase(),
                style: const TextStyle(
                  color: _quietText,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _body() {
    if (_loading) return const _OrganizerLoading();
    if (_failed || _loaded == null) {
      return _OrganizerFailure(
        message: _recovery ?? 'Could not load local organization.',
        retryFocus: _retryFocus,
        onRetry: _load,
      );
    }
    final groups = _loaded!.groups;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _OrganizerCheckRow(
          key: const ValueKey('organizer-favorite'),
          focusNode: _favoriteFocus,
          label: 'Favorite',
          checked: _favorite,
          enabled: !_saving,
          onToggle: _toggleFavorite,
          onUp: null,
          onDown: groups.isEmpty
              ? () => _cancelFocus.requestFocus()
              : () => _focusGroup(0),
        ),
        const Divider(height: 1, color: _line),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: Text(
            'Add to groups',
            style: TextStyle(
              color: _warmWhite,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Text(
            'Select one or more groups',
            style: TextStyle(color: _quietText, fontSize: 13),
          ),
        ),
        Expanded(
          child: groups.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Text(
                    'Create a custom group in My Library to add this item.',
                    style: TextStyle(color: _quietText, fontSize: 14),
                  ),
                )
              : ListView.builder(
                  controller: _groupsScroll,
                  itemExtent: 48,
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    final group = groups[index];
                    return _OrganizerCheckRow(
                      key: ValueKey('organizer-group-${group.groupId}'),
                      focusNode: _groupFocus[group.groupId]!,
                      label: group.name,
                      checked: _selectedGroups.contains(group.groupId),
                      enabled: !_saving,
                      onToggle: () => _toggleGroup(group.groupId),
                      onUp: index == 0
                          ? () => _favoriteFocus.requestFocus()
                          : () => _focusGroup(index - 1),
                      onDown: index + 1 == groups.length
                          ? () => _cancelFocus.requestFocus()
                          : () => _focusGroup(index + 1),
                    );
                  },
                ),
        ),
        if (_recovery != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                _recovery!,
                style: const TextStyle(color: _amber, fontSize: 13),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Expanded(
                child: _OrganizerAction(
                  key: const ValueKey('organizer-cancel'),
                  focusNode: _cancelFocus,
                  label: 'Cancel',
                  enabled: !_saving,
                  onPressed: _close,
                  onLeft: null,
                  onRight: () => _saveFocus.requestFocus(),
                  onUp: groups.isEmpty
                      ? () => _favoriteFocus.requestFocus()
                      : () => _focusGroup(groups.length - 1),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _OrganizerAction(
                  key: const ValueKey('organizer-save'),
                  focusNode: _saveFocus,
                  label: _saving ? 'Saving…' : 'Save',
                  enabled: !_saving && _dirty,
                  primary: true,
                  onPressed: _save,
                  onLeft: () => _cancelFocus.requestFocus(),
                  onRight: null,
                  onUp: groups.isEmpty
                      ? () => _favoriteFocus.requestFocus()
                      : () => _focusGroup(groups.length - 1),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OrganizerCheckRow extends StatefulWidget {
  const _OrganizerCheckRow({
    super.key,
    required this.focusNode,
    required this.label,
    required this.checked,
    required this.enabled,
    required this.onToggle,
    required this.onUp,
    required this.onDown,
  });

  final FocusNode focusNode;
  final String label;
  final bool checked;
  final bool enabled;
  final VoidCallback onToggle;
  final VoidCallback? onUp;
  final VoidCallback onDown;

  @override
  State<_OrganizerCheckRow> createState() => _OrganizerCheckRowState();
}

class _OrganizerCheckRowState extends State<_OrganizerCheckRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    canRequestFocus: widget.enabled,
    onFocusChange: (focused) => setState(() => _focused = focused),
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
          widget.onUp?.call();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          widget.onDown();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
        case LogicalKeyboardKey.space:
          if (widget.enabled) widget.onToggle();
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    },
    child: Semantics(
      button: true,
      checked: widget.checked,
      enabled: widget.enabled,
      label: widget.label,
      child: InkWell(
        onTap: widget.enabled
            ? () {
                widget.focusNode.requestFocus();
                widget.onToggle();
              }
            : null,
        child: Container(
          height: 48,
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _focused ? _raised : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused ? _amber : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Icon(
                widget.checked
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
                color: widget.checked ? _amber : _quietText,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _warmWhite, fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _OrganizerAction extends StatefulWidget {
  const _OrganizerAction({
    super.key,
    required this.focusNode,
    required this.label,
    required this.enabled,
    required this.onPressed,
    required this.onLeft,
    required this.onRight,
    required this.onUp,
    this.primary = false,
  });

  final FocusNode focusNode;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;
  final VoidCallback? onLeft;
  final VoidCallback? onRight;
  final VoidCallback onUp;
  final bool primary;

  @override
  State<_OrganizerAction> createState() => _OrganizerActionState();
}

class _OrganizerActionState extends State<_OrganizerAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    canRequestFocus: widget.enabled,
    onFocusChange: (focused) => setState(() => _focused = focused),
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowLeft:
          widget.onLeft?.call();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowRight:
          widget.onRight?.call();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          widget.onUp();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
          if (widget.enabled) widget.onPressed();
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    },
    child: Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      child: InkWell(
        onTap: widget.enabled
            ? () {
                widget.focusNode.requestFocus();
                widget.onPressed();
              }
            : null,
        child: Container(
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.primary && widget.enabled ? _amber : _raised,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused
                  ? _warmWhite
                  : widget.primary && widget.enabled
                  ? _amber
                  : _line,
              width: 2,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.primary && widget.enabled
                  ? _graphite
                  : widget.enabled
                  ? _warmWhite
                  : _quietText,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ),
  );
}

class _OrganizerLoading extends StatelessWidget {
  const _OrganizerLoading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _OrganizerSkeleton(width: 180),
        SizedBox(height: 12),
        _OrganizerSkeleton(width: double.infinity),
        SizedBox(height: 8),
        _OrganizerSkeleton(width: double.infinity),
      ],
    ),
  );
}

class _OrganizerSkeleton extends StatelessWidget {
  const _OrganizerSkeleton({required this.width});
  final double width;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      width: width,
      height: 40,
      decoration: BoxDecoration(
        color: _raised,
        borderRadius: BorderRadius.circular(6),
      ),
    ),
  );
}

class _OrganizerFailure extends StatelessWidget {
  const _OrganizerFailure({
    required this.message,
    required this.retryFocus,
    required this.onRetry,
  });

  final String message;
  final FocusNode retryFocus;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Organization unavailable',
          style: TextStyle(
            color: _warmWhite,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(message, style: const TextStyle(color: _quietText, fontSize: 14)),
        const SizedBox(height: 18),
        Row(
          children: [
            SizedBox(
              width: 120,
              child: _OrganizerAction(
                focusNode: retryFocus,
                label: 'Retry',
                enabled: true,
                onPressed: onRetry,
                onLeft: null,
                onRight: null,
                onUp: retryFocus.requestFocus,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
