import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'source_models.dart';

const _graphite = Color(0xFF111212);
const _surface = Color(0xFF191A1A);
const _raised = Color(0xFF222321);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);
const _amberInk = Color(0xFF17120A);

void _noopManageVisibility(SourceRosterEntry _) {}

enum SourceManagementLoadState { loading, ready, failed }

class _DirectoryMoveIntent extends Intent {
  const _DirectoryMoveIntent(this.direction);
  final int direction;
}

abstract class SourceManagementPort {
  /// Reads a bounded, credential-free roster from durable local storage.
  Future<List<SourceRosterEntry>> loadRoster();

  Future<void> refresh(String sourceId);
  Future<void> setEnabled(String sourceId, bool enabled);

  /// Changes only the local display name. It does not refresh the source.
  Future<void> rename(String sourceId, String name);

  /// Opens the connector editor. Completion means the editor has closed; a
  /// saved edit refreshes immediately, while Cancel leaves the source intact.
  Future<void> editAndRefresh(String sourceId);

  /// Removes credentials and this source's catalog contribution only.
  Future<void> remove(String sourceId);
}

class SourceManagementController extends ChangeNotifier {
  SourceManagementController({
    List<SourceRosterEntry> entries = const [],
    this.port,
  }) : entries = List<SourceRosterEntry>.of(entries) {
    selectedId = this.entries.firstOrNull?.id;
  }

  final SourceManagementPort? port;
  final List<SourceRosterEntry> entries;

  SourceManagementLoadState state = SourceManagementLoadState.ready;
  String? selectedId;
  String? failedSourceId;
  String? recovery;
  bool refreshing = false;
  bool _working = false;
  Future<void>? _load;

  bool get isEmpty => entries.isEmpty;
  bool get isWorking => _working;
  SourceRosterEntry? get selected =>
      entries.where((entry) => entry.id == selectedId).firstOrNull ??
      entries.firstOrNull;

  /// Called when the management surface enters the shell. Production callers
  /// always replace the fixture snapshot with the durable roster.
  Future<void> initialize() => _reload(initial: true);

  Future<void> retryLoad() => _reload(initial: entries.isEmpty);

  /// Test/fixture seam only. Runtime action results always use [_reload].
  void replaceEntries(List<SourceRosterEntry> replacement) {
    _applyEntries(replacement);
    state = SourceManagementLoadState.ready;
    notifyListeners();
  }

  void select(String id) {
    if (!entries.any((entry) => entry.id == id)) return;
    selectedId = id;
    failedSourceId = null;
    recovery = null;
    notifyListeners();
  }

  Future<void> refresh() async {
    final source = selected;
    if (source == null || !_beginAction()) return;
    refreshing = true;
    failedSourceId = null;
    recovery = null;
    notifyListeners();
    try {
      await _requirePort().refresh(source.id);
      await _reload(reportFailure: true);
    } catch (_) {
      failedSourceId = source.id;
      recovery =
          'Refresh failed. Your previous local catalog is still available.';
    } finally {
      refreshing = false;
      _working = false;
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    final source = selected;
    if (source == null || !_beginAction()) return;
    recovery = null;
    notifyListeners();
    try {
      await _requirePort().setEnabled(source.id, !source.enabled);
      await _reload(reportFailure: true);
    } catch (_) {
      recovery =
          'That source could not be updated. Your local catalog is unchanged.';
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<void> rename(String name) async {
    final source = selected;
    final normalized = name.trim();
    if (source == null || normalized.isEmpty || !_beginAction()) return;
    recovery = null;
    notifyListeners();
    try {
      await _requirePort().rename(source.id, normalized);
      await _reload(reportFailure: true);
    } catch (_) {
      recovery =
          'That source could not be renamed. Your local catalog is unchanged.';
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<void> edit() async {
    final source = selected;
    if (source == null || !_beginAction()) return;
    recovery = null;
    notifyListeners();
    try {
      await _requirePort().editAndRefresh(source.id);
      await _reload(reportFailure: true);
    } catch (_) {
      recovery =
          'That source could not be updated. Your local catalog is unchanged.';
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<void> removeSelected() async {
    final source = selected;
    if (source == null || !_beginAction()) return;
    recovery = null;
    notifyListeners();
    try {
      await _requirePort().remove(source.id);
      await _reload(reportFailure: true);
    } catch (_) {
      recovery =
          'That source could not be removed. Your local catalog is unchanged.';
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  bool _beginAction() {
    if (!_working) {
      _working = true;
      return true;
    }
    recovery = 'Another source action is already in progress.';
    notifyListeners();
    return false;
  }

  SourceManagementPort _requirePort() {
    final current = port;
    if (current == null) throw StateError('Source management is unavailable.');
    return current;
  }

  Future<void> _reload({bool initial = false, bool reportFailure = false}) {
    final current = port;
    if (current == null) return Future<void>.value();
    final pending = _load;
    if (pending != null) return pending;
    if (initial && entries.isEmpty) {
      state = SourceManagementLoadState.loading;
      notifyListeners();
    }
    final future = _loadRoster(current, reportFailure: reportFailure);
    _load = future;
    return future;
  }

  Future<void> _loadRoster(
    SourceManagementPort current, {
    required bool reportFailure,
  }) async {
    try {
      final roster = await current.loadRoster();
      _applyEntries(roster);
      state = SourceManagementLoadState.ready;
    } catch (_) {
      if (entries.isEmpty) {
        state = SourceManagementLoadState.failed;
      } else {
        // A transient local read failure must not erase the usable directory
        // the user was just managing. Keep the last roster and let the next
        // maintenance action retry normally.
        state = SourceManagementLoadState.ready;
        recovery ??=
            'Sources could not be updated. Showing your last local catalog.';
      }
      if (reportFailure) rethrow;
    } finally {
      _load = null;
      notifyListeners();
    }
  }

  void _applyEntries(List<SourceRosterEntry> replacement) {
    final previousSelection = selectedId;
    entries
      ..clear()
      ..addAll(replacement);
    selectedId = entries.any((entry) => entry.id == previousSelection)
        ? previousSelection
        : entries.firstOrNull?.id;
  }
}

class SourceManagementScreen extends StatefulWidget {
  const SourceManagementScreen({
    super.key,
    required this.initialFocus,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.onAddSource,
    this.onManageVisibility = _noopManageVisibility,
    required this.controller,
    this.restoreSelectedFocusOnEntry = false,
    this.restoreVisibilityFocusOnEntry = false,
  });
  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final VoidCallback onAddSource;
  final ValueChanged<SourceRosterEntry> onManageVisibility;
  final SourceManagementController controller;

  /// Shell requests this after the Source Ledger closes so the directory row
  /// that opened it—not merely the first row—receives focus again.
  final bool restoreSelectedFocusOnEntry;

  /// Shell requests this only when the visibility continuation closes so the
  /// exact action that opened it receives focus again.
  final bool restoreVisibilityFocusOnEntry;
  @override
  State<SourceManagementScreen> createState() => _SourceManagementScreenState();
}

class _SourceManagementScreenState extends State<SourceManagementScreen> {
  final _addFocus = FocusNode(debugLabel: 'source management add');
  final _refreshFocus = FocusNode(debugLabel: 'source management refresh');
  final _renameFocus = FocusNode(debugLabel: 'source management rename');
  final _editFocus = FocusNode(debugLabel: 'source management edit');
  final _visibilityFocus = FocusNode(
    debugLabel: 'source management manage visibility',
  );
  final _toggleFocus = FocusNode(debugLabel: 'source management toggle');
  final _removeFocus = FocusNode(debugLabel: 'source management remove');
  final _cancelRemoveFocus = FocusNode(
    debugLabel: 'source management cancel remove',
  );
  late final Map<String, FocusNode> _rows = {};
  late bool _restoreSelectedFocus = widget.restoreSelectedFocusOnEntry;
  late bool _restoreVisibilityFocus = widget.restoreVisibilityFocusOnEntry;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    unawaited(widget.controller.initialize());
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _restoreEntryFocusIfNeeded(),
    );
    for (final node in [
      widget.initialFocus,
      _addFocus,
      _refreshFocus,
      _renameFocus,
      _editFocus,
      _visibilityFocus,
      _toggleFocus,
      _removeFocus,
      _cancelRemoveFocus,
    ]) {
      node.addListener(() {
        if (node.hasFocus) widget.onContentFocus(node);
      });
    }
  }

  @override
  void didUpdateWidget(covariant SourceManagementScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_changed);
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _addFocus.dispose();
    _refreshFocus.dispose();
    _renameFocus.dispose();
    _editFocus.dispose();
    _visibilityFocus.dispose();
    _toggleFocus.dispose();
    _removeFocus.dispose();
    _cancelRemoveFocus.dispose();
    for (final n in _rows.values) {
      n.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _restoreEntryFocusIfNeeded();
  }

  void _restoreEntryFocusIfNeeded() {
    if (_restoreVisibilityFocus && mounted) {
      _restoreVisibilityFocus = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _visibilityFocus.requestFocus();
      });
      return;
    }
    if (!_restoreSelectedFocus || !mounted) return;
    final selected = widget.controller.selected;
    if (selected == null) return;
    _restoreSelectedFocus = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _row(selected.id).requestFocus();
    });
  }

  FocusNode _row(String id) {
    if (widget.controller.entries.isNotEmpty &&
        widget.controller.entries.first.id == id) {
      return widget.initialFocus;
    }
    return _rows.putIfAbsent(id, () => FocusNode(debugLabel: 'source row $id'));
  }

  void _back() {
    final selected = widget.controller.selected;
    if (selected != null &&
        FocusManager.instance.primaryFocus != _row(selected.id)) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => FocusScope.of(context).requestFocus(_row(selected.id)),
      );
    } else {
      widget.onOpenRail();
    }
  }

  Future<void> _remove() async {
    final source = widget.controller.selected;
    if (source == null) return;
    final removedIndex = widget.controller.entries.indexWhere(
      (entry) => entry.id == source.id,
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _cancelRemoveFocus.requestFocus(),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _surface,
        title: Text(
          'Remove ${source.name}',
          style: const TextStyle(color: _warmWhite),
        ),
        content: const Text(
          'This removes this source’s credentials and active catalog contribution. Other sources stay available.',
          style: TextStyle(color: _quietText),
        ),
        actions: [
          OutlinedButton(
            focusNode: _cancelRemoveFocus,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove source'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.removeSelected();
      if (!mounted) return;
      final entries = widget.controller.entries;
      if (entries.isNotEmpty) {
        final target =
            entries[removedIndex.clamp(0, entries.length - 1).toInt()];
        if (widget.controller.selectedId != target.id) {
          widget.controller.select(target.id);
        }
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final selected = widget.controller.selected;
        (selected == null ? widget.initialFocus : _row(selected.id))
            .requestFocus();
      });
    }
  }

  Future<void> _rename() async {
    final source = widget.controller.selected;
    if (source == null) return;
    var name = source.name;
    final renamed = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _surface,
        title: const Text('Rename source', style: TextStyle(color: _warmWhite)),
        content: TextFormField(
          key: const ValueKey('source-rename-field'),
          initialValue: source.name,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onChanged: (value) => name = value,
          onFieldSubmitted: (value) {
            final normalized = value.trim();
            if (normalized.isNotEmpty) Navigator.pop(context, normalized);
          },
          decoration: const InputDecoration(labelText: 'Source name'),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final normalized = name.trim();
              if (normalized.isNotEmpty) Navigator.pop(context, normalized);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    _renameFocus.requestFocus();
    if (renamed != null && renamed != source.name) {
      await widget.controller.rename(renamed);
      if (mounted) _renameFocus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _back,
        const SingleActivator(LogicalKeyboardKey.browserBack): _back,
      },
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: ColoredBox(
          color: _graphite,
          child: LayoutBuilder(
            builder: (context, box) {
              final narrow = box.maxWidth < 760;
              final selected = c.selected;
              const headerText = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sources',
                    style: TextStyle(
                      color: _warmWhite,
                      fontSize: 31,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.7,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Manage the local sources in your library.',
                    style: TextStyle(color: _quietText, fontSize: 16),
                  ),
                ],
              );
              final addSource = _OutlinedAction(
                label: 'Add source',
                focusNode: _addFocus,
                onPressed: widget.onAddSource,
              );
              final header = narrow
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        headerText,
                        const SizedBox(height: 16),
                        addSource,
                      ],
                    )
                  : Row(
                      children: [
                        const Expanded(child: headerText),
                        addSource,
                      ],
                    );
              final directory = _Directory(
                entries: c.entries,
                selectedId: selected?.id,
                focusFor: _row,
                onSelected: c.select,
                scrollable: !narrow,
              );
              final detail = selected == null
                  ? _Empty(
                      onAdd: widget.onAddSource,
                      focusNode: widget.initialFocus,
                    )
                  : _Detail(
                      source: selected,
                      refreshing: c.refreshing,
                      working: c.isWorking,
                      failed: c.failedSourceId == selected.id,
                      recovery: c.recovery,
                      refreshFocus: _refreshFocus,
                      renameFocus: _renameFocus,
                      onRefresh: () {
                        _refreshFocus.requestFocus();
                        return c.refresh();
                      },
                      onEdit: () {
                        _editFocus.requestFocus();
                        return c.edit();
                      },
                      onManageVisibility: () {
                        _visibilityFocus.requestFocus();
                        widget.onManageVisibility(selected);
                      },
                      onRename: _rename,
                      onToggle: () {
                        _toggleFocus.requestFocus();
                        return c.toggle();
                      },
                      onRemove: _remove,
                      editFocus: _editFocus,
                      visibilityFocus: _visibilityFocus,
                      toggleFocus: _toggleFocus,
                      removeFocus: _removeFocus,
                      narrow: narrow,
                    );
              return Padding(
                padding: EdgeInsets.fromLTRB(
                  narrow ? 24 : 48,
                  22,
                  narrow ? 24 : 32,
                  32,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    header,
                    const SizedBox(height: 28),
                    Expanded(
                      child: c.state == SourceManagementLoadState.loading
                          ? Center(
                              child: Semantics(
                                liveRegion: true,
                                label: 'Loading sources',
                                child: const Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(color: _amber),
                                    SizedBox(height: 14),
                                    Text(
                                      'Loading sources…',
                                      style: TextStyle(color: _quietText),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : c.state == SourceManagementLoadState.failed
                          ? _LoadFailure(
                              onRetry: c.retryLoad,
                              focusNode: widget.initialFocus,
                            )
                          : narrow
                          ? ListView(
                              children: [
                                directory,
                                const SizedBox(height: 24),
                                detail,
                              ],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(width: 340, child: directory),
                                const VerticalDivider(color: _line, width: 44),
                                Expanded(
                                  child: SingleChildScrollView(child: detail),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Directory extends StatefulWidget {
  const _Directory({
    required this.entries,
    required this.selectedId,
    required this.focusFor,
    required this.onSelected,
    required this.scrollable,
  });
  final List<SourceRosterEntry> entries;
  final String? selectedId;
  final FocusNode Function(String) focusFor;
  final ValueChanged<String> onSelected;
  final bool scrollable;

  @override
  State<_Directory> createState() => _DirectoryState();
}

class _DirectoryState extends State<_Directory> {
  final _scroll = ScrollController();
  double _rowExtent = 96;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _move(int index, int direction) {
    final next = (index + direction).clamp(0, widget.entries.length - 1);
    if (next == index) return;
    final target = next * _rowExtent;
    if (_scroll.hasClients) {
      _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.focusFor(widget.entries[next].id).requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox();
    final scale = MediaQuery.textScalerOf(context).scale(1);
    _rowExtent = (96 + ((scale - 1).clamp(0, 3) * 58)).toDouble();
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(7),
      ),
      child: ListView(
        controller: _scroll,
        itemExtent: _rowExtent,
        shrinkWrap: !widget.scrollable,
        physics: widget.scrollable
            ? const ClampingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        children: List.generate(widget.entries.length, (index) {
          final source = widget.entries[index];
          return _SourceRow(
            source: source,
            selected: source.id == widget.selectedId,
            focusNode: widget.focusFor(source.id),
            onPressed: () => widget.onSelected(source.id),
            onMove: (direction) => _move(index, direction),
          );
        }),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.selected,
    required this.focusNode,
    required this.onPressed,
    required this.onMove,
  });
  final SourceRosterEntry source;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onPressed;
  final ValueChanged<int> onMove;
  @override
  Widget build(BuildContext context) {
    final connector = _connectorLabel(source.kind);
    final state = _sourceStatus(source).directory;
    final counts = _directoryCounts(source.counts);
    return FocusableActionDetector(
      focusNode: focusNode,
      autofocus: selected,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowUp): _DirectoryMoveIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowDown): _DirectoryMoveIntent(1),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      actions: {
        _DirectoryMoveIntent: CallbackAction<_DirectoryMoveIntent>(
          onInvoke: (intent) {
            onMove(intent.direction);
            return null;
          },
        ),
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onPressed();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (_) {},
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Semantics(
            button: true,
            selected: selected,
            excludeSemantics: true,
            label:
                '${source.name}, $connector, $state, Live ${_count(source.counts[SourceMediaKind.live] ?? 0)}, Movies ${_count(source.counts[SourceMediaKind.movies] ?? 0)}, Series ${_count(source.counts[SourceMediaKind.series] ?? 0)}',
            child: Container(
              key: ValueKey('source-row-${source.id}'),
              decoration: BoxDecoration(
                color: selected ? _raised : Colors.transparent,
                border: Border.all(
                  color: focused ? _amber : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onPressed,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: _line)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  source.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _warmWhite,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  '$connector · $state · $counts',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _quietText,
                                    fontSize: 12,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.chevron_right, color: _warmWhite),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({
    required this.source,
    required this.refreshing,
    required this.working,
    required this.failed,
    required this.recovery,
    required this.refreshFocus,
    required this.renameFocus,
    required this.onRefresh,
    required this.onRename,
    required this.onEdit,
    required this.onManageVisibility,
    required this.onToggle,
    required this.onRemove,
    required this.narrow,
    required this.editFocus,
    required this.visibilityFocus,
    required this.toggleFocus,
    required this.removeFocus,
  });
  final SourceRosterEntry source;
  final bool refreshing, working, failed, narrow;
  final String? recovery;
  final FocusNode refreshFocus;
  final FocusNode renameFocus;
  final FocusNode editFocus, visibilityFocus, toggleFocus, removeFocus;
  final Future<void> Function() onRefresh, onRename, onEdit, onToggle, onRemove;
  final VoidCallback onManageVisibility;
  @override
  Widget build(BuildContext context) {
    final status = _sourceStatus(source);
    final statusMessage = failed
        ? 'Refresh failed. Previous local catalog retained.'
        : (recovery ?? status.detail);
    final actions = [
      _FilledAction(
        label: refreshing ? 'Refreshing…' : 'Refresh',
        focusNode: refreshFocus,
        onPressed: working ? null : onRefresh,
      ),
      _OutlinedAction(
        label: 'Edit',
        focusNode: editFocus,
        onPressed: working ? null : onEdit,
      ),
      _OutlinedAction(
        label: 'Manage visibility',
        focusNode: visibilityFocus,
        onPressed: working ? null : onManageVisibility,
      ),
      _OutlinedAction(
        label: source.enabled ? 'Disable' : 'Enable',
        focusNode: toggleFocus,
        onPressed: working ? null : onToggle,
      ),
      _OutlinedAction(
        label: 'Remove',
        focusNode: removeFocus,
        onPressed: working ? null : onRemove,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                source.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _warmWhite,
                  fontSize: 31,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 16),
            _QuietTextAction(
              label: 'Rename',
              focusNode: renameFocus,
              onPressed: working ? null : onRename,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Semantics(
          key: ValueKey('source-status-${source.id}'),
          liveRegion: true,
          label:
              '${source.enabled ? 'Enabled' : 'Disabled, excluded from active results'}. $statusMessage',
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source.enabled
                      ? 'Enabled'
                      : 'Disabled — excluded from active results',
                  style: const TextStyle(color: _quietText, fontSize: 16),
                ),
                const SizedBox(height: 12),
                Text(
                  statusMessage,
                  style: const TextStyle(color: _quietText, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),
        narrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final a in actions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: a,
                    ),
                ],
              )
            : Row(
                children: [
                  for (final a in actions)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: a,
                      ),
                    ),
                ],
              ),
        const SizedBox(height: 30),
        const Divider(color: _line),
        const SizedBox(height: 28),
        _Counts(counts: source.counts, narrow: narrow),
      ],
    );
  }
}

class _Counts extends StatelessWidget {
  const _Counts({required this.counts, required this.narrow});
  final Map<SourceMediaKind, int> counts;
  final bool narrow;
  @override
  Widget build(BuildContext context) {
    final cells = [
      for (final k in SourceMediaKind.values)
        Expanded(
          child: Column(
            children: [
              Text(
                k.label,
                style: const TextStyle(color: _quietText, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                _count(counts[k] ?? 0),
                style: const TextStyle(color: _warmWhite, fontSize: 26),
              ),
            ],
          ),
        ),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: narrow
            ? Column(
                children: cells
                    .map(
                      (e) => Padding(
                        padding: const EdgeInsets.all(8),
                        child: e.child,
                      ),
                    )
                    .toList(),
              )
            : Row(children: cells),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd, required this.focusNode});
  final VoidCallback onAdd;
  final FocusNode focusNode;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'No sources yet',
          style: TextStyle(
            color: _warmWhite,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Add a source to build your local library.',
          style: TextStyle(color: _quietText),
        ),
        const SizedBox(height: 20),
        _FilledAction(
          label: 'Add source',
          focusNode: focusNode,
          onPressed: onAdd,
        ),
      ],
    ),
  );
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.onRetry, required this.focusNode});
  final VoidCallback onRetry;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Sources could not be loaded',
          style: TextStyle(
            color: _warmWhite,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Try again. Your local catalog is unchanged.',
          style: TextStyle(color: _quietText),
        ),
        const SizedBox(height: 20),
        _OutlinedAction(
          label: 'Retry',
          focusNode: focusNode,
          onPressed: onRetry,
        ),
      ],
    ),
  );
}

class _OutlinedAction extends StatelessWidget {
  const _OutlinedAction({
    required this.label,
    this.focusNode,
    required this.onPressed,
  });
  final String label;
  final FocusNode? focusNode;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => OutlinedButton(
    key: ValueKey('source-action-$label'),
    focusNode: focusNode,
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      foregroundColor: _warmWhite,
      side: const BorderSide(color: _line),
      minimumSize: const Size(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    child: Text(label),
  );
}

class _QuietTextAction extends StatelessWidget {
  const _QuietTextAction({
    required this.label,
    required this.focusNode,
    required this.onPressed,
  });

  final String label;
  final FocusNode focusNode;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    key: ValueKey('source-action-$label'),
    focusNode: focusNode,
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: _warmWhite,
      minimumSize: const Size(0, 44),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      side: const BorderSide(color: _line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    child: Text(label),
  );
}

class _FilledAction extends StatelessWidget {
  const _FilledAction({
    required this.label,
    this.focusNode,
    required this.onPressed,
  });
  final String label;
  final FocusNode? focusNode;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => FilledButton(
    key: ValueKey('source-action-$label'),
    focusNode: focusNode,
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: _amber,
      foregroundColor: _amberInk,
      minimumSize: const Size(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    child: Text(label),
  );
}

String _count(int value) => value.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'),
  (_) => ',',
);

String _compactCount(int value) {
  if (value < 1000) return value.toString();
  final divisor = value >= 1000000 ? 1000000 : 1000;
  final suffix = value >= 1000000 ? 'M' : 'K';
  final compact = value / divisor;
  return '${compact >= 100 ? compact.toStringAsFixed(0) : compact.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')}$suffix';
}

String _directoryCounts(Map<SourceMediaKind, int> counts) =>
    'L ${_compactCount(counts[SourceMediaKind.live] ?? 0)} · '
    'M ${_compactCount(counts[SourceMediaKind.movies] ?? 0)} · '
    'S ${_compactCount(counts[SourceMediaKind.series] ?? 0)}';

String _connectorLabel(String kind) => switch (kind.toLowerCase()) {
  'm3u_url' => 'M3U URL',
  'm3u_file' => 'Local M3U',
  'xtream' => 'Xtream',
  _ => kind,
};

class _SourceStatusPresentation {
  const _SourceStatusPresentation({
    required this.directory,
    required this.detail,
  });

  final String directory;
  final String detail;
}

_SourceStatusPresentation _sourceStatus(SourceRosterEntry source) {
  final refresh = switch (source.status.trim().toLowerCase()) {
    'refresh_failed' => const (
      directory: 'Refresh failed',
      detail: 'Refresh failed. Previous local catalog retained.',
    ),
    'refreshing' => const (
      directory: 'Refreshing',
      detail: 'Refreshing. Current local catalog remains available.',
    ),
    'ready' || 'last refresh complete' => const (
      directory: 'Ready',
      detail: 'Last refresh complete.',
    ),
    _ => const (
      directory: 'Status unavailable',
      detail: 'Refresh status unavailable.',
    ),
  };
  return _SourceStatusPresentation(
    directory: source.enabled
        ? refresh.directory
        : 'Disabled${refresh.directory == 'Refresh failed' ? ' · Refresh failed' : ''}',
    detail: refresh.detail,
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
