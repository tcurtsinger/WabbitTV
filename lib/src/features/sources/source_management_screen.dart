import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show FrameCallback;
import 'package:flutter/services.dart';

import '../../cinema.dart';
import '../settings/general_settings_section.dart';
import '../settings/startup_preferences_controller.dart';
import 'source_models.dart';

const _graphite = Cinema.ink;
const _surface = Color(0xFF141419);
const _raised = Color(0xFF1E1E23);
const _warmWhite = Cinema.text;
const _quietText = Cinema.faint;
const _amber = Cinema.amber;

const _overline = TextStyle(
  color: _quietText,
  fontSize: 12,
  fontWeight: FontWeight.w700,
  letterSpacing: 0.3,
);

/// Runs [callback] after the next frame and makes sure that frame comes. A
/// key press alone schedules none, so a focus move would otherwise wait for
/// some unrelated repaint.
void _afterNextFrame(FrameCallback callback) {
  WidgetsBinding.instance
    ..addPostFrameCallback(callback)
    ..ensureVisualUpdate();
}

void _noopManageVisibility(SourceRosterEntry _) {}

enum SourceManagementLoadState { loading, ready, failed }

enum SourceConnectionAllowanceState {
  unavailable,
  loading,
  ready,
  saving,
  loadFailed,
  saveFailed,
}

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

/// Narrow Phase 5 seam for the selected source's local stream allowance.
/// Source-management fixtures that predate the setting can keep implementing
/// [SourceManagementPort] without pretending they can persist this value.
abstract interface class SourceConnectionAllowancePort {
  Future<SourceConnectionAllowance> loadSourceConnectionAllowance(
    String sourceId,
  );

  Future<SourceConnectionAllowance> setSourceConnectionLimitOverride({
    required String sourceId,
    required int? overrideLimit,
  });
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
  SourceConnectionAllowanceState connectionAllowanceState =
      SourceConnectionAllowanceState.unavailable;
  SourceConnectionAllowance? connectionAllowance;
  String? connectionRecovery;
  int? _failedConnectionOverride;
  int _connectionGeneration = 0;
  bool _working = false;
  Future<void>? _load;

  bool get isEmpty => entries.isEmpty;
  bool get isWorking => _working;
  bool get canManageConnectionAllowance =>
      port is SourceConnectionAllowancePort;
  SourceConnectionAllowancePort? get _connectionPort {
    final current = port;
    return current is SourceConnectionAllowancePort
        ? current as SourceConnectionAllowancePort
        : null;
  }

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
    unawaited(_loadConnectionAllowance(id));
  }

  Future<void> retryConnectionAllowance() {
    final source = selected;
    if (source == null) return Future<void>.value();
    if (connectionAllowanceState == SourceConnectionAllowanceState.saveFailed) {
      return setConnectionLimitOverride(_failedConnectionOverride);
    }
    return _loadConnectionAllowance(source.id);
  }

  Future<void> setConnectionLimitOverride(int? overrideLimit) async {
    final source = selected;
    final currentPort = _connectionPort;
    if (source == null || currentPort == null || !_beginAction()) {
      return;
    }
    final sourceId = source.id;
    final generation = ++_connectionGeneration;
    connectionAllowanceState = SourceConnectionAllowanceState.saving;
    connectionRecovery = null;
    _failedConnectionOverride = null;
    notifyListeners();
    try {
      final saved = await currentPort.setSourceConnectionLimitOverride(
        sourceId: sourceId,
        overrideLimit: overrideLimit,
      );
      if (selectedId != sourceId || generation != _connectionGeneration) return;
      connectionAllowance = saved;
      connectionAllowanceState = SourceConnectionAllowanceState.ready;
    } catch (_) {
      if (selectedId != sourceId || generation != _connectionGeneration) return;
      _failedConnectionOverride = overrideLimit;
      connectionAllowanceState = SourceConnectionAllowanceState.saveFailed;
      connectionRecovery = "Couldn't save the stream setting.";
    } finally {
      _working = false;
      notifyListeners();
    }
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
      recovery = 'Refresh failed · showing saved catalog';
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
      recovery = "Couldn't update this source.";
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
      recovery = "Couldn't rename this source.";
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
      recovery = "Couldn't update this source.";
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
      recovery = "Couldn't remove this source.";
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
    recovery = 'Another action is running.';
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
      final selectedSourceId = selectedId;
      if (selectedSourceId != null) {
        await _loadConnectionAllowance(selectedSourceId);
      }
    } catch (_) {
      if (entries.isEmpty) {
        state = SourceManagementLoadState.failed;
      } else {
        // A transient local read failure must not erase the usable directory
        // the user was just managing. Keep the last roster and let the next
        // maintenance action retry normally.
        state = SourceManagementLoadState.ready;
        recovery ??= "Couldn't update sources · showing saved list";
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
    if (selectedId == null) {
      _clearConnectionAllowance();
    }
  }

  Future<void> _loadConnectionAllowance(String sourceId) async {
    final currentPort = _connectionPort;
    if (currentPort == null) {
      _clearConnectionAllowance();
      notifyListeners();
      return;
    }
    final generation = ++_connectionGeneration;
    connectionAllowanceState = SourceConnectionAllowanceState.loading;
    connectionAllowance = null;
    connectionRecovery = null;
    _failedConnectionOverride = null;
    notifyListeners();
    try {
      final loaded = await currentPort.loadSourceConnectionAllowance(sourceId);
      if (selectedId != sourceId || generation != _connectionGeneration) return;
      connectionAllowance = loaded;
      connectionAllowanceState = SourceConnectionAllowanceState.ready;
    } catch (_) {
      if (selectedId != sourceId || generation != _connectionGeneration) return;
      connectionAllowanceState = SourceConnectionAllowanceState.loadFailed;
      connectionRecovery = "Couldn't load the stream setting.";
    } finally {
      notifyListeners();
    }
  }

  void _clearConnectionAllowance() {
    _connectionGeneration++;
    connectionAllowanceState = SourceConnectionAllowanceState.unavailable;
    connectionAllowance = null;
    connectionRecovery = null;
    _failedConnectionOverride = null;
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
    this.startupPreferencesController,
    this.restoreSelectedFocusOnEntry = false,
    this.restoreVisibilityFocusOnEntry = false,
  });
  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final VoidCallback onAddSource;
  final ValueChanged<SourceRosterEntry> onManageVisibility;
  final SourceManagementController controller;
  final StartupPreferencesController? startupPreferencesController;

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
  final _generalSettingsKey = GlobalKey<GeneralSettingsSectionState>();
  final _directoryKey = GlobalKey<_DirectoryState>();
  final _addFocus = FocusNode(debugLabel: 'source management add');
  final _refreshFocus = FocusNode(debugLabel: 'source management refresh');
  final _renameFocus = FocusNode(debugLabel: 'source management rename');
  final _editFocus = FocusNode(debugLabel: 'source management edit');
  final _visibilityFocus = FocusNode(
    debugLabel: 'source management manage visibility',
  );
  final _toggleFocus = FocusNode(debugLabel: 'source management toggle');
  final _removeFocus = FocusNode(debugLabel: 'source management remove');
  final _automaticStreamsFocus = FocusNode(
    debugLabel: 'source management streams automatic',
  );
  final _oneStreamFocus = FocusNode(
    debugLabel: 'source management streams one',
  );
  final _twoStreamsFocus = FocusNode(
    debugLabel: 'source management streams two',
  );
  final _streamsRetryFocus = FocusNode(
    debugLabel: 'source management streams retry',
  );
  final _cancelRemoveFocus = FocusNode(
    debugLabel: 'source management cancel remove',
  );
  FocusNode? _connectionFocusTarget;
  late final Map<String, FocusNode> _rows = {};
  late bool _restoreSelectedFocus = widget.restoreSelectedFocusOnEntry;
  late bool _restoreVisibilityFocus = widget.restoreVisibilityFocusOnEntry;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    unawaited(widget.controller.initialize());
    _afterNextFrame((_) => _restoreEntryFocusIfNeeded());
    for (final node in [
      widget.initialFocus,
      _addFocus,
      _refreshFocus,
      _renameFocus,
      _editFocus,
      _visibilityFocus,
      _toggleFocus,
      _removeFocus,
      _automaticStreamsFocus,
      _oneStreamFocus,
      _twoStreamsFocus,
      _streamsRetryFocus,
      _cancelRemoveFocus,
    ]) {
      node.addListener(() {
        if (!node.hasFocus) return;
        _connectionFocusTarget = switch (node) {
          final current
              when current == _automaticStreamsFocus ||
                  current == _oneStreamFocus ||
                  current == _twoStreamsFocus ||
                  current == _streamsRetryFocus =>
            current,
          _ => null,
        };
        widget.onContentFocus(node);
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
    _automaticStreamsFocus.dispose();
    _oneStreamFocus.dispose();
    _twoStreamsFocus.dispose();
    _streamsRetryFocus.dispose();
    _cancelRemoveFocus.dispose();
    for (final n in _rows.values) {
      n.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final connectionTarget = _connectionFocusTarget;
    setState(() {});
    if (connectionTarget != null) {
      _afterNextFrame((_) {
        if (!mounted || _connectionFocusTarget != connectionTarget) return;
        final target =
            connectionTarget == _streamsRetryFocus &&
                widget.controller.connectionAllowanceState ==
                    SourceConnectionAllowanceState.ready
            ? _focusForAllowance(widget.controller.connectionAllowance)
            : connectionTarget;
        if (target.context == null || !target.canRequestFocus) return;
        _connectionFocusTarget = target;
        target.requestFocus();
      });
    }
    _restoreEntryFocusIfNeeded();
  }

  FocusNode _focusForAllowance(SourceConnectionAllowance? allowance) =>
      switch (allowance?.overrideLimit) {
        1 => _oneStreamFocus,
        2 => _twoStreamsFocus,
        _ => _automaticStreamsFocus,
      };

  void _restoreEntryFocusIfNeeded() {
    if (_restoreVisibilityFocus && mounted) {
      _restoreVisibilityFocus = false;
      _afterNextFrame((_) {
        if (mounted) _visibilityFocus.requestFocus();
      });
      return;
    }
    if (!_restoreSelectedFocus || !mounted) return;
    final selected = widget.controller.selected;
    if (selected == null) return;
    _restoreSelectedFocus = false;
    _afterNextFrame((_) {
      if (mounted) _row(selected.id).requestFocus();
    });
  }

  FocusNode _row(String id) {
    if (widget.controller.entries.isNotEmpty &&
        widget.controller.entries.first.id == id) {
      return widget.initialFocus;
    }
    return _rows.putIfAbsent(id, () {
      final node = FocusNode(debugLabel: 'source row $id');
      node.addListener(() {
        if (!node.hasFocus) return;
        _connectionFocusTarget = null;
        widget.onContentFocus(node);
      });
      return node;
    });
  }

  void _focusSelectedStartupChoice() {
    _generalSettingsKey.currentState?.focusSelectedChoice();
  }

  void _focusPrimarySourceTarget() {
    final controller = widget.controller;
    if (controller.state == SourceManagementLoadState.loading) {
      _addFocus.requestFocus();
      return;
    }
    if (controller.state == SourceManagementLoadState.failed) {
      widget.initialFocus.requestFocus();
      return;
    }
    final selected = controller.selected;
    if (selected == null) {
      widget.initialFocus.requestFocus();
      return;
    }
    final target = _row(selected.id);
    if (target.context != null && target.canRequestFocus) {
      target.requestFocus();
      return;
    }
    _directoryKey.currentState?.focusSource(selected.id);
  }

  void _back() {
    final selected = widget.controller.selected;
    if (selected != null &&
        FocusManager.instance.primaryFocus != _row(selected.id)) {
      _connectionFocusTarget = null;
      _row(selected.id).requestFocus();
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
    _afterNextFrame((_) => _cancelRemoveFocus.requestFocus());
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _raised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text('Remove ${source.name}', style: _dialogTitle),
        content: const Text(
          'Its login and catalog leave Wabbit. Other sources stay.',
          style: TextStyle(color: _quietText),
        ),
        actions: [
          OutlinedButton(
            focusNode: _cancelRemoveFocus,
            onPressed: () => Navigator.pop(context, false),
            style: Cinema.pillButton(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: Cinema.pillButton(primary: true),
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
      _afterNextFrame((_) {
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
        backgroundColor: _raised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('Rename source', style: _dialogTitle),
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
            style: Cinema.pillButton(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: Cinema.pillButton(primary: true),
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
              const headerText = Text(
                'Settings',
                style: TextStyle(
                  color: _warmWhite,
                  fontFamily: Cinema.display,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.6,
                ),
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
                key: _directoryKey,
                entries: c.entries,
                selectedId: selected?.id,
                focusFor: _row,
                onSelected: (id) {
                  _connectionFocusTarget = null;
                  c.select(id);
                },
                onMoveBeforeFirst: widget.startupPreferencesController == null
                    ? null
                    : _focusSelectedStartupChoice,
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
                      connectionAllowance: c.connectionAllowance,
                      connectionAllowanceState: c.connectionAllowanceState,
                      connectionRecovery: c.connectionRecovery,
                      automaticStreamsFocus: _automaticStreamsFocus,
                      oneStreamFocus: _oneStreamFocus,
                      twoStreamsFocus: _twoStreamsFocus,
                      streamsRetryFocus: _streamsRetryFocus,
                      onConnectionLimitChanged: c.setConnectionLimitOverride,
                      onRetryConnectionAllowance: c.retryConnectionAllowance,
                      showConnectionAllowance: c.canManageConnectionAllowance,
                      keepConnectionRetryMounted:
                          _connectionFocusTarget == _streamsRetryFocus,
                      narrow: narrow,
                    );
              final loading = Center(
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
              );
              final sourceContent = c.state == SourceManagementLoadState.loading
                  ? narrow
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 80),
                            child: loading,
                          )
                        : loading
                  : c.state == SourceManagementLoadState.failed
                  ? _LoadFailure(
                      onRetry: c.retryLoad,
                      focusNode: widget.initialFocus,
                    )
                  : narrow
                  ? Column(
                      children: [directory, const SizedBox(height: 24), detail],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 300, child: directory),
                        const SizedBox(width: 28),
                        Expanded(child: SingleChildScrollView(child: detail)),
                      ],
                    );
              final content = <Widget>[
                header,
                if (widget.startupPreferencesController != null) ...[
                  const SizedBox(height: 18),
                  GeneralSettingsSection(
                    key: _generalSettingsKey,
                    controller: widget.startupPreferencesController!,
                    onContentFocus: widget.onContentFocus,
                    onMoveToSources: _focusPrimarySourceTarget,
                    onMoveAbove: _addFocus.requestFocus,
                  ),
                ],
                const SizedBox(height: 22),
                const Text('Sources', style: _overline),
                const SizedBox(height: 10),
              ];
              return Padding(
                padding: EdgeInsets.fromLTRB(
                  narrow ? 24 : 32,
                  22,
                  narrow ? 24 : 32,
                  32,
                ),
                child: narrow
                    ? ListView(children: [...content, sourceContent])
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ...content,
                          Expanded(child: sourceContent),
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
    super.key,
    required this.entries,
    required this.selectedId,
    required this.focusFor,
    required this.onSelected,
    required this.onMoveBeforeFirst,
    required this.scrollable,
  });
  final List<SourceRosterEntry> entries;
  final String? selectedId;
  final FocusNode Function(String) focusFor;
  final ValueChanged<String> onSelected;
  final VoidCallback? onMoveBeforeFirst;
  final bool scrollable;

  @override
  State<_Directory> createState() => _DirectoryState();
}

class _DirectoryState extends State<_Directory> {
  final _scroll = ScrollController();
  double _rowExtent = 88;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _move(int index, int direction) {
    final next = (index + direction).clamp(0, widget.entries.length - 1);
    if (next == index) {
      if (index == 0 && direction < 0) widget.onMoveBeforeFirst?.call();
      return;
    }
    final target = next * _rowExtent;
    if (_scroll.hasClients) {
      _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
    }
    _afterNextFrame((_) {
      if (mounted) widget.focusFor(widget.entries[next].id).requestFocus();
    });
  }

  void focusSource(String sourceId) {
    final index = widget.entries.indexWhere((entry) => entry.id == sourceId);
    if (index < 0) return;
    final target = index * _rowExtent;
    if (_scroll.hasClients) {
      _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
    }
    _afterNextFrame((_) {
      if (mounted) widget.focusFor(sourceId).requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox();
    final scale = MediaQuery.textScalerOf(context).scale(1);
    _rowExtent = (88 + ((scale - 1).clamp(0, 3) * 64)).toDouble();
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
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
      mouseCursor: SystemMouseCursors.click,
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Semantics(
            button: true,
            selected: selected,
            excludeSemantics: true,
            label:
                '${source.name}, $connector, $state, Live ${_count(source.counts[SourceMediaKind.live] ?? 0)}, Movies ${_count(source.counts[SourceMediaKind.movies] ?? 0)}, Series ${_count(source.counts[SourceMediaKind.series] ?? 0)}',
            child: GestureDetector(
              onTap: onPressed,
              child: Container(
                key: ValueKey('source-row-${source.id}'),
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  // Opaque when focused so the ring stays a ring.
                  color: selected || focused
                      ? _raised
                      : const Color(0x00000000),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: focused ? Cinema.focusGlow : const [],
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
                            style: TextStyle(
                              color: selected ? _amber : _warmWhite,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '$connector · $state',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Cinema.quiet,
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: selected ? _amber : _quietText,
                    ),
                  ],
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
    required this.connectionAllowance,
    required this.connectionAllowanceState,
    required this.connectionRecovery,
    required this.automaticStreamsFocus,
    required this.oneStreamFocus,
    required this.twoStreamsFocus,
    required this.streamsRetryFocus,
    required this.onConnectionLimitChanged,
    required this.onRetryConnectionAllowance,
    required this.showConnectionAllowance,
    required this.keepConnectionRetryMounted,
  });
  final SourceRosterEntry source;
  final bool refreshing, working, failed, narrow;
  final String? recovery;
  final FocusNode refreshFocus;
  final FocusNode renameFocus;
  final FocusNode editFocus, visibilityFocus, toggleFocus, removeFocus;
  final FocusNode automaticStreamsFocus;
  final FocusNode oneStreamFocus;
  final FocusNode twoStreamsFocus;
  final FocusNode streamsRetryFocus;
  final SourceConnectionAllowance? connectionAllowance;
  final SourceConnectionAllowanceState connectionAllowanceState;
  final String? connectionRecovery;
  final ValueChanged<int?> onConnectionLimitChanged;
  final VoidCallback onRetryConnectionAllowance;
  final bool showConnectionAllowance;
  final bool keepConnectionRetryMounted;
  final Future<void> Function() onRefresh, onRename, onEdit, onToggle, onRemove;
  final VoidCallback onManageVisibility;
  @override
  Widget build(BuildContext context) {
    final status = _sourceStatus(source);
    final statusMessage = failed
        ? 'Refresh failed · showing saved catalog'
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
                  fontFamily: Cinema.display,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.4,
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
          label: '${source.enabled ? 'Enabled' : 'Disabled'}. $statusMessage',
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source.enabled ? 'Enabled' : 'Disabled',
                  style: TextStyle(
                    color: source.enabled ? Cinema.quiet : _amber,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  statusMessage,
                  style: const TextStyle(color: Cinema.quiet, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),
        // Natural-width pills that wrap in reading order at any width.
        Wrap(spacing: 10, runSpacing: 10, children: actions),
        const SizedBox(height: 24),
        _Counts(counts: source.counts, narrow: narrow),
        if (showConnectionAllowance) ...[
          const SizedBox(height: 28),
          _ConnectionAllowanceLedger(
            allowance: connectionAllowance,
            state: connectionAllowanceState,
            recovery: connectionRecovery,
            working: working,
            automaticFocus: automaticStreamsFocus,
            oneFocus: oneStreamFocus,
            twoFocus: twoStreamsFocus,
            retryFocus: streamsRetryFocus,
            onChanged: onConnectionLimitChanged,
            onRetry: onRetryConnectionAllowance,
            keepRetryMounted: keepConnectionRetryMounted,
          ),
        ],
      ],
    );
  }
}

class _ConnectionAllowanceLedger extends StatelessWidget {
  const _ConnectionAllowanceLedger({
    required this.allowance,
    required this.state,
    required this.recovery,
    required this.working,
    required this.automaticFocus,
    required this.oneFocus,
    required this.twoFocus,
    required this.retryFocus,
    required this.onChanged,
    required this.onRetry,
    required this.keepRetryMounted,
  });

  final SourceConnectionAllowance? allowance;
  final SourceConnectionAllowanceState state;
  final String? recovery;
  final bool working;
  final FocusNode automaticFocus, oneFocus, twoFocus, retryFocus;
  final ValueChanged<int?> onChanged;
  final VoidCallback onRetry;
  final bool keepRetryMounted;

  @override
  Widget build(BuildContext context) {
    final current = allowance;
    final busy = working || state == SourceConnectionAllowanceState.saving;
    final failed =
        state == SourceConnectionAllowanceState.loadFailed ||
        state == SourceConnectionAllowanceState.saveFailed;
    final showRetry =
        failed ||
        (keepRetryMounted &&
            (state == SourceConnectionAllowanceState.loading ||
                state == SourceConnectionAllowanceState.saving));
    final status = current == null ? null : _allowanceStatus(current);
    final semanticsLabel = StringBuffer('Simultaneous streams');
    if (status != null) semanticsLabel.write('. $status');
    if (recovery != null) semanticsLabel.write('. $recovery');
    return Semantics(
      key: const ValueKey('source-connection-allowance'),
      container: true,
      liveRegion: true,
      label: semanticsLabel.toString(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Simultaneous streams',
            style: TextStyle(
              color: _warmWhite,
              fontFamily: Cinema.display,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 24),
            child: state == SourceConnectionAllowanceState.loading
                ? const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          color: _amber,
                          strokeWidth: 2,
                        ),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Loading stream setting…',
                          style: TextStyle(color: _quietText),
                        ),
                      ),
                    ],
                  )
                : Text(
                    status ?? 'Stream setting unavailable',
                    key: const ValueKey('source-connection-status'),
                    style: const TextStyle(
                      color: _warmWhite,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _AllowanceChoice(
                label: 'Automatic',
                selected: current != null && current.overrideLimit == null,
                focusNode: automaticFocus,
                enabled: !busy,
                onPressed: current == null ? null : () => onChanged(null),
              ),
              _AllowanceChoice(
                label: '1',
                selected: current?.overrideLimit == 1,
                focusNode: oneFocus,
                enabled: !busy,
                onPressed: current == null ? null : () => onChanged(1),
              ),
              _AllowanceChoice(
                label: '2',
                selected: current?.overrideLimit == 2,
                focusNode: twoFocus,
                enabled: !busy,
                onPressed: current == null ? null : () => onChanged(2),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: showRetry
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          failed
                              ? (recovery ??
                                    'The stream setting is unavailable.')
                              : 'Retrying…',
                          style: const TextStyle(
                            color: _quietText,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      _FocusHoldingOutlinedAction(
                        label: 'Retry',
                        focusNode: retryFocus,
                        enabled: failed && !busy,
                        onPressed: onRetry,
                      ),
                    ],
                  )
                : Align(
                    alignment: Alignment.centerLeft,
                    child: state == SourceConnectionAllowanceState.saving
                        ? const Text(
                            'Saving locally…',
                            style: TextStyle(color: _quietText, fontSize: 14),
                          )
                        : const SizedBox.shrink(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _AllowanceChoice extends StatelessWidget {
  const _AllowanceChoice({
    required this.label,
    required this.selected,
    required this.focusNode,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback? onPressed;

  void _invoke() {
    focusNode.requestFocus();
    if (enabled) onPressed?.call();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    enabled: enabled && onPressed != null,
    excludeSemantics: true,
    label: '$label${selected ? ', selected' : ''}',
    child: OutlinedButton(
      key: ValueKey('source-connection-choice-$label'),
      focusNode: focusNode,
      onPressed: onPressed == null ? null : _invoke,
      style: Cinema.pillButton().copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(96, 44)),
        // Selected reads amber on glass; focus still fills the pill amber.
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? Cinema.amberInk
              : !enabled
              ? _quietText
              : selected
              ? _amber
              : _warmWhite,
        ),
        side: WidgetStatePropertyAll(
          selected
              ? const BorderSide(color: _amber, width: 1.5)
              : BorderSide.none,
        ),
      ),
      child: Text(label),
    ),
  );
}

class _FocusHoldingOutlinedAction extends StatelessWidget {
  const _FocusHoldingOutlinedAction({
    required this.label,
    required this.focusNode,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onPressed;

  void _invoke() {
    focusNode.requestFocus();
    if (enabled) onPressed();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: enabled,
    excludeSemantics: true,
    label: label,
    child: OutlinedButton(
      key: ValueKey('source-action-$label'),
      focusNode: focusNode,
      onPressed: _invoke,
      style: Cinema.pillButton().copyWith(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? Cinema.amberInk
              : enabled
              ? _warmWhite
              : _quietText,
        ),
      ),
      child: Text(label),
    ),
  );
}

String _allowanceStatus(SourceConnectionAllowance allowance) {
  final override = allowance.overrideLimit;
  if (override == null) {
    final reported = allowance.reportedLimit;
    return reported == null
        ? 'Automatic · 1 stream'
        : 'Automatic · provider allows $reported';
  }
  final reported = allowance.reportedLimit;
  return reported == null
      ? 'Set to $override'
      : 'Set to $override · provider allows $reported';
}

class _Counts extends StatelessWidget {
  const _Counts({required this.counts, required this.narrow});
  final Map<SourceMediaKind, int> counts;
  final bool narrow;
  @override
  Widget build(BuildContext context) {
    Widget tile(SourceMediaKind kind) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            kind.label,
            style: const TextStyle(color: Cinema.quiet, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            _count(counts[kind] ?? 0),
            style: const TextStyle(
              color: _warmWhite,
              fontFamily: Cinema.display,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final kind in SourceMediaKind.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: tile(kind),
            ),
        ],
      );
    }
    return Row(
      children: [
        for (final kind in SourceMediaKind.values) ...[
          if (kind != SourceMediaKind.values.first) const SizedBox(width: 10),
          Expanded(child: tile(kind)),
        ],
      ],
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
        const Text('No sources yet', style: _messageTitle),
        const SizedBox(height: 8),
        const Text(
          'Add one to start watching.',
          style: TextStyle(color: Cinema.quiet, fontSize: 15),
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
        const Text("Couldn't load sources", style: _messageTitle),
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
    style: Cinema.pillButton(),
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
    style: Cinema.pillButton(),
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
    style: Cinema.pillButton(primary: true),
    child: Text(label),
  );
}

String _count(int value) => value.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'),
  (_) => ',',
);

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
      detail: 'Refresh failed · showing saved catalog',
    ),
    'refreshing' => const (directory: 'Refreshing', detail: 'Refreshing…'),
    'ready' ||
    'last refresh complete' => const (directory: 'Ready', detail: 'Up to date'),
    _ => const (directory: 'Status unavailable', detail: 'Status unknown'),
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

const _dialogTitle = TextStyle(
  color: _warmWhite,
  fontFamily: Cinema.display,
  fontSize: 20,
  fontWeight: FontWeight.w800,
);

const _messageTitle = TextStyle(
  color: _warmWhite,
  fontFamily: Cinema.display,
  fontSize: 22,
  fontWeight: FontWeight.w800,
);
