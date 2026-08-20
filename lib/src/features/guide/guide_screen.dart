import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../browse/playback_handoff.dart';
import '../sources/epg_models.dart';
import '../sources/source_models.dart';
import 'guide_data.dart';

const _graphite = Color(0xFF111212);
const _surface = Color(0xFF191A1A);
const _raised = Color(0xFF222321);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);
const _guideRowExtent = 66.0;
const _rulerExtent = 46.0;
const _hourWidth = 180.0;
const _guideHours = 9;
const _guideEpgViewportHistoryLimit = 3;
const _guideEpgCacheLimit =
    guidePresentationEpgLimit * _guideEpgViewportHistoryLimit;

enum _GuidePageFailure { earlier, more }

class _GuideDeferredNowFocus {
  const _GuideDeferredNowFocus({
    required this.generation,
    required this.sourceId,
    required this.categoryKind,
    required this.categoryGroupId,
    required this.windowStartUtc,
    required this.windowEndUtc,
  });

  final int generation;
  final String? sourceId;
  final BrowseCategorySelectionKind categoryKind;
  final int? categoryGroupId;
  final DateTime windowStartUtc;
  final DateTime windowEndUtc;
}

class GuideLocalInstant {
  const GuideLocalInstant({
    required this.wallTime,
    required this.utcOffset,
    required this.zoneName,
  });

  final DateTime wallTime;
  final Duration utcOffset;
  final String zoneName;
}

/// Shell-lifetime practical Guide position. It contains only local catalog
/// identities and presentation state; no provider locators or credentials.
class GuideSession {
  String? sourceId;
  BrowseCategorySelection category = const BrowseCategorySelection.all();
  String? focusedChannelId;
  int? focusedProgramStartUtcMs;
  int? focusedProgramEndUtcMs;
  double verticalOffset = 0;
  double horizontalOffset = 0;
  DateTime? windowStartUtc;
  double? focusedChannelViewportOffset;
}

class GuideScreen extends StatefulWidget {
  const GuideScreen({
    super.key,
    required this.initialFocus,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.session,
    required this.onPlaybackHandoff,
    required this.data,
    required this.onBrowseLive,
    required this.onOpenSettings,
    this.now,
    this.localize,
  });

  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final GuideSession session;
  final ValueChanged<PlaybackHandoff> onPlaybackHandoff;
  final GuideDataPort data;
  final VoidCallback onBrowseLive;
  final VoidCallback onOpenSettings;
  final DateTime Function()? now;
  final GuideLocalInstant Function(DateTime utc)? localize;

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  final _sourceFocus = FocusNode(debugLabel: 'guide source');
  final _categoryFocus = FocusNode(debugLabel: 'guide category');
  final _goNowFocus = FocusNode(debugLabel: 'guide go to now');
  final _retryFocus = FocusNode(debugLabel: 'guide retry');
  final _vertical = ScrollController();
  final _timeline = ScrollController();
  final Map<String, FocusNode> _channelNodes = {};
  final Map<String, FocusNode> _programNodes = {};
  final Map<String, DateTime> _refreshAttempts = {};

  List<SourceRosterEntry>? _sources;
  List<BrowseCategorySummary>? _categories;
  List<BrowseCatalogItem> _channels = const [];
  BrowseCursor? _previousCursor;
  BrowseCursor? _nextCursor;
  Map<String, EpgChannelWindow> _windows = const {};
  List<String> _activeEpgIds = const [];
  List<List<String>> _epgViewportHistory = const [];
  Object? _loadError;
  BrowseCategorySummary? _failedCategory;
  _GuidePageFailure? _pageFailure;
  bool _loadingPage = false;
  bool _loadingPrevious = false;
  bool _loadingMore = false;
  bool _refreshFailed = false;
  bool _focusAnnouncement = false;
  _GuideDeferredNowFocus? _deferredNowFocus;
  late bool _initialMatrixFocusPending;
  late bool _exactProgramRestorePending;
  late String? _sharedFocusChannelId;
  late int? _sharedFocusProgramStartUtcMs;
  late int? _sharedFocusProgramEndUtcMs;
  String? _visualFocusChannelId;
  int? _visualFocusProgramStartUtcMs;
  int? _visualFocusProgramEndUtcMs;
  String? _focusContext;
  String? _fallbackAnnouncementChannelId;
  FocusNode? _fallbackAnnouncementFocusNode;
  int _generation = 0;
  int _windowRequest = 0;
  int? _previousRequestGeneration;
  int? _moreRequestGeneration;
  int? _restoreAnchorIndex;
  Timer? _visibleTimer;
  Timer? _boundaryTimer;
  late DateTime _windowStartUtc;
  late DateTime _windowEndUtc;
  double _lastRowExtent = _guideRowExtent;

  DateTime get _nowUtc => (widget.now?.call() ?? DateTime.now()).toUtc();

  GuideLocalInstant _localize(DateTime utc) {
    final injected = widget.localize;
    if (injected != null) return injected(utc.toUtc());
    final local = utc.toLocal();
    return GuideLocalInstant(
      wallTime: local,
      utcOffset: local.timeZoneOffset,
      zoneName: local.timeZoneName,
    );
  }

  bool get _visibleRangeCrossesOffsetTransition {
    final start = _localize(_windowStartUtc);
    final end = _localize(
      _windowEndUtc.subtract(const Duration(milliseconds: 1)),
    );
    return start.utcOffset != end.utcOffset;
  }

  double get _rowExtent {
    final scaled = MediaQuery.textScalerOf(context).scale(14);
    _lastRowExtent = 66 + ((scaled - 14).clamp(0, 14) * 2.6);
    return _lastRowExtent;
  }

  SourceRosterEntry? get _source {
    final sources = _sources ?? const <SourceRosterEntry>[];
    for (final source in sources) {
      if (source.id == widget.session.sourceId) return source;
    }
    return sources.firstOrNull;
  }

  BrowseCategorySummary? get _category {
    final categories = _categories ?? const <BrowseCategorySummary>[];
    for (final category in categories) {
      if (_sameCategory(category.selection, widget.session.category)) {
        return category;
      }
    }
    return categories.firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    _initialMatrixFocusPending = widget.session.focusedChannelId == null;
    _exactProgramRestorePending =
        widget.session.focusedChannelId != null &&
        widget.session.focusedProgramStartUtcMs != null &&
        widget.session.focusedProgramEndUtcMs != null;
    _sharedFocusChannelId = widget.session.focusedChannelId;
    _sharedFocusProgramStartUtcMs = widget.session.focusedProgramStartUtcMs;
    _sharedFocusProgramEndUtcMs = widget.session.focusedProgramEndUtcMs;
    _visualFocusChannelId = widget.session.focusedChannelId;
    _visualFocusProgramStartUtcMs = widget.session.focusedProgramStartUtcMs;
    _visualFocusProgramEndUtcMs = widget.session.focusedProgramEndUtcMs;
    _resetTimeWindow();
    for (final node in [
      _sourceFocus,
      _categoryFocus,
      _goNowFocus,
      _retryFocus,
    ]) {
      node.addListener(_reportHeaderFocus);
    }
    _vertical.addListener(_onVerticalScroll);
    _timeline.addListener(_onTimelineScroll);
    FocusManager.instance.addListener(_onPrimaryFocusChanged);
    unawaited(_loadGuide());
  }

  @override
  void dispose() {
    unawaited(widget.data.cancelActiveEpgRefresh());
    _visibleTimer?.cancel();
    _boundaryTimer?.cancel();
    _rememberPosition(rowExtent: _lastRowExtent);
    _vertical
      ..removeListener(_onVerticalScroll)
      ..dispose();
    _timeline
      ..removeListener(_onTimelineScroll)
      ..dispose();
    FocusManager.instance.removeListener(_onPrimaryFocusChanged);
    _deferredNowFocus = null;
    _sourceFocus.dispose();
    _categoryFocus.dispose();
    _goNowFocus.dispose();
    _retryFocus.dispose();
    super.dispose();
  }

  void _resetTimeWindow() {
    final now = _nowUtc;
    final retained = widget.session.windowStartUtc?.toUtc();
    if (retained != null &&
        !now.isBefore(retained) &&
        now.isBefore(retained.add(const Duration(hours: _guideHours)))) {
      _windowStartUtc = retained;
    } else {
      _windowStartUtc = _windowStartFor(now);
      widget.session.horizontalOffset = 0;
    }
    _windowEndUtc = _windowStartUtc.add(const Duration(hours: _guideHours));
    widget.session.windowStartUtc = _windowStartUtc;
  }

  DateTime _windowStartFor(DateTime nowUtc) {
    final hour = DateTime.utc(
      nowUtc.year,
      nowUtc.month,
      nowUtc.day,
      nowUtc.hour,
    );
    return hour.subtract(const Duration(minutes: 30));
  }

  void _reportHeaderFocus() {
    for (final node in [
      _sourceFocus,
      _categoryFocus,
      _goNowFocus,
      _retryFocus,
    ]) {
      if (node.hasFocus) {
        widget.onContentFocus(node);
        return;
      }
    }
  }

  void _onPrimaryFocusChanged() {
    if (_deferredNowFocus == null) return;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || _isDeferredNowFlowFocus(focus)) return;
    _deferredNowFocus = null;
  }

  bool _isDeferredNowFlowFocus(FocusNode focus) =>
      identical(focus, _categoryFocus) ||
      identical(focus, widget.initialFocus) ||
      _channelNodes.values.any((node) => identical(node, focus)) ||
      _programNodes.values.any((node) => identical(node, focus));

  bool _matchesDeferredNowFocus(_GuideDeferredNowFocus request) =>
      request.generation == _generation &&
      request.sourceId == widget.session.sourceId &&
      request.categoryKind == widget.session.category.kind &&
      request.categoryGroupId == widget.session.category.sourceGroupId &&
      request.windowStartUtc == _windowStartUtc &&
      request.windowEndUtc == _windowEndUtc;

  void _rememberPosition({double? rowExtent}) {
    var verticalOffset = widget.session.verticalOffset;
    if (_vertical.hasClients) {
      verticalOffset = _vertical.offset;
    }
    if (_timeline.hasClients) {
      widget.session.horizontalOffset = _timeline.offset;
    }
    widget.session.windowStartUtc = _windowStartUtc;
    widget.session.verticalOffset = verticalOffset;
    final extent = rowExtent ?? _rowExtent;
    final focusedIndex = widget.session.focusedChannelId == null
        ? -1
        : _channels.indexWhere(
            (channel) => channel.id == widget.session.focusedChannelId,
          );
    if (focusedIndex >= 0) {
      final viewport = _vertical.hasClients
          ? _vertical.position.viewportDimension
          : extent * 8;
      widget.session.focusedChannelViewportOffset =
          (focusedIndex * extent - verticalOffset)
              .clamp(0.0, math.max(0.0, viewport - extent))
              .toDouble();
    }
  }

  Future<void> _loadGuide() async {
    final generation = ++_generation;
    final requestedSourceId = widget.session.sourceId;
    final requestedCategory = widget.session.category;
    _windowRequest += 1;
    _visibleTimer?.cancel();
    _boundaryTimer?.cancel();
    setState(() {
      _loadError = null;
      _loadingPage = true;
      _loadingPrevious = false;
      _loadingMore = false;
      _previousRequestGeneration = null;
      _moreRequestGeneration = null;
      _restoreAnchorIndex = null;
      _windows = const {};
      _activeEpgIds = const [];
      _epgViewportHistory = const [];
      _failedCategory = null;
      _pageFailure = null;
      _deferredNowFocus = null;
      _focusContext = null;
      _focusAnnouncement = false;
      _fallbackAnnouncementChannelId = null;
      _fallbackAnnouncementFocusNode = null;
      _refreshAttempts.clear();
    });
    try {
      final sources = await widget.data.loadXtreamSources();
      if (!mounted || generation != _generation) return;
      final retained = sources.where(
        (source) => source.id == widget.session.sourceId,
      );
      final source = retained.isEmpty ? sources.firstOrNull : retained.first;
      if (source == null) {
        setState(() {
          _sources = sources;
          _categories = const [];
          _channels = const [];
          _windows = const {};
          _activeEpgIds = const [];
          _epgViewportHistory = const [];
          _loadingPage = false;
        });
        return;
      }
      final sourceFellBack =
          requestedSourceId != null && requestedSourceId != source.id;
      widget.session.sourceId = source.id;
      final categories = await widget.data.loadCategories(source.id);
      if (!mounted || generation != _generation) return;
      var category = categories.firstOrNull;
      for (final candidate in categories) {
        if (_sameCategory(candidate.selection, widget.session.category)) {
          category = candidate;
          break;
        }
      }
      final categoryFellBack =
          category != null &&
          !_sameCategory(requestedCategory, category.selection);
      final scopeFallbackMessage = switch ((sourceFellBack, categoryFellBack)) {
        (true, true) =>
          'Saved Guide source and category are unavailable · showing ${source.name} · ${category?.name ?? 'All Live'}.',
        (true, false) =>
          'Saved Guide source is unavailable · showing ${source.name}.',
        (false, true) =>
          'Saved Guide category is unavailable · showing ${category?.name ?? 'All Live'}.',
        (false, false) => null,
      };
      if (category != null) widget.session.category = category.selection;
      final firstPage = category == null
          ? const BrowsePage(items: [], nextCursor: null)
          : await widget.data.loadChannels(
              sourceId: source.id,
              selection: category.selection,
              limit: guideChannelPageSize,
            );
      if (!mounted || generation != _generation) return;
      var page = firstPage;
      BrowseCursor? previousCursor;
      var missingChannelFallback = false;
      final savedChannelId = widget.session.focusedChannelId;
      if (category != null && savedChannelId != null) {
        final restoration = widget.data;
        if (restoration is GuideRestorationDataPort) {
          final window = await (restoration as GuideRestorationDataPort)
              .loadChannelWindow(
                sourceId: source.id,
                selection: category.selection,
                catalogItemId: savedChannelId,
                limit: guideChannelPageSize,
              );
          if (!mounted || generation != _generation) return;
          if (window == null) {
            _fallbackFromMissingSavedChannel(firstPage.items.firstOrNull);
            missingChannelFallback = true;
          } else {
            page = BrowsePage(
              items: window.items,
              nextCursor: window.nextCursor,
            );
            previousCursor = window.previousCursor;
            final anchorIndex = window.items.indexWhere(
              (channel) => channel.id == savedChannelId,
            );
            _restoreAnchorIndex = anchorIndex;
          }
        } else {
          final exactIsOnFirstPage = firstPage.items.any(
            (channel) => channel.id == savedChannelId,
          );
          if (!exactIsOnFirstPage) {
            _fallbackFromMissingSavedChannel(firstPage.items.firstOrNull);
            missingChannelFallback = true;
          }
        }
      }
      if (!missingChannelFallback && scopeFallbackMessage != null) {
        _focusContext = scopeFallbackMessage;
        _focusAnnouncement = true;
        _fallbackAnnouncementChannelId =
            widget.session.focusedChannelId ?? page.items.firstOrNull?.id;
        _fallbackAnnouncementFocusNode = null;
      }
      setState(() {
        _sources = sources;
        _categories = categories;
        _channels = page.items;
        _previousCursor = previousCursor;
        _nextCursor = page.nextCursor;
        _windows = const {};
        _activeEpgIds = const [];
        _epgViewportHistory = const [];
        _failedCategory = null;
        _pageFailure = null;
        _loadingPage = false;
        _loadingPrevious = false;
        _loadingMore = false;
        _previousRequestGeneration = null;
        _moreRequestGeneration = null;
        _refreshFailed = false;
      });
      _restorePositionAndFocus();
      _scheduleVisibleEpg(immediate: true);
    } catch (_) {
      if (!mounted) return;
      if (generation != _generation) {
        if (_previousRequestGeneration == generation) {
          setState(() {
            _loadingPrevious = false;
            _previousRequestGeneration = null;
          });
        }
        return;
      }
      setState(() {
        _loadError = Object();
        _loadingPage = false;
        _loadingPrevious = false;
        _loadingMore = false;
        _previousRequestGeneration = null;
        _moreRequestGeneration = null;
      });
    }
  }

  void _fallbackFromMissingSavedChannel(BrowseCatalogItem? fallback) {
    widget.session
      ..focusedChannelId = fallback?.id
      ..focusedProgramStartUtcMs = null
      ..focusedProgramEndUtcMs = null
      ..focusedChannelViewportOffset = 0
      ..verticalOffset = 0;
    _initialMatrixFocusPending = false;
    _exactProgramRestorePending = false;
    _sharedFocusChannelId = fallback?.id;
    _sharedFocusProgramStartUtcMs = null;
    _sharedFocusProgramEndUtcMs = null;
    _visualFocusChannelId = fallback?.id;
    _visualFocusProgramStartUtcMs = null;
    _visualFocusProgramEndUtcMs = null;
    _focusContext = fallback == null
        ? 'Saved Guide channel is no longer available.'
        : 'Saved Guide channel is no longer available · showing ${fallback.title}.';
    _focusAnnouncement = true;
    _fallbackAnnouncementChannelId = fallback?.id;
    _fallbackAnnouncementFocusNode = null;
    _restoreAnchorIndex = null;
  }

  Future<void> _chooseSource(String sourceId) async {
    if (sourceId == widget.session.sourceId) return;
    final releaseGeneration = ++_generation;
    _windowRequest += 1;
    _rememberPosition();
    widget.session
      ..sourceId = sourceId
      ..category = const BrowseCategorySelection.all()
      ..focusedChannelId = null
      ..focusedProgramStartUtcMs = null
      ..focusedProgramEndUtcMs = null
      ..focusedChannelViewportOffset = null
      ..verticalOffset = 0;
    _initialMatrixFocusPending = true;
    _exactProgramRestorePending = false;
    _sharedFocusChannelId = null;
    _sharedFocusProgramStartUtcMs = null;
    _sharedFocusProgramEndUtcMs = null;
    _visualFocusChannelId = null;
    _visualFocusProgramStartUtcMs = null;
    _visualFocusProgramEndUtcMs = null;
    _fallbackAnnouncementChannelId = null;
    _fallbackAnnouncementFocusNode = null;
    _focusAnnouncement = false;
    _refreshAttempts.clear();
    setState(() {
      _categories = const [];
      _channels = const [];
      _previousCursor = null;
      _nextCursor = null;
      _windows = const {};
      _activeEpgIds = const [];
      _epgViewportHistory = const [];
      _failedCategory = null;
      _pageFailure = null;
      _deferredNowFocus = null;
      _loadError = null;
      _loadingPage = true;
      _loadingPrevious = false;
      _loadingMore = false;
      _previousRequestGeneration = null;
      _moreRequestGeneration = null;
      _restoreAnchorIndex = null;
      _refreshFailed = false;
    });
    await widget.data.cancelActiveEpgRefresh();
    if (!mounted ||
        releaseGeneration != _generation ||
        widget.session.sourceId != sourceId) {
      return;
    }
    await _loadGuide();
    if (!mounted || widget.session.sourceId != sourceId) return;
    if (_loadError == null) {
      _sourceFocus.requestFocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _loadError != null) widget.initialFocus.requestFocus();
      });
    }
  }

  Future<void> _chooseCategory(int index) async {
    final categories = _categories ?? const <BrowseCategorySummary>[];
    final source = _source;
    if (source == null || index < 0 || index >= categories.length) return;
    final category = categories[index];
    if (_sameCategory(category.selection, widget.session.category)) return;
    final generation = ++_generation;
    _windowRequest += 1;
    setState(() {
      _loadingPage = true;
      _loadError = null;
      _loadingPrevious = false;
      _loadingMore = false;
      _previousRequestGeneration = null;
      _moreRequestGeneration = null;
      _restoreAnchorIndex = null;
      _windows = const {};
      _activeEpgIds = const [];
      _epgViewportHistory = const [];
      _failedCategory = null;
      _pageFailure = null;
      _deferredNowFocus = null;
      _refreshAttempts.clear();
    });
    try {
      await widget.data.cancelActiveEpgRefresh();
      if (!mounted || generation != _generation) return;
      final page = await widget.data.loadChannels(
        sourceId: source.id,
        selection: category.selection,
        limit: guideChannelPageSize,
      );
      if (!mounted || generation != _generation) return;
      widget.session
        ..category = category.selection
        ..focusedChannelId = null
        ..focusedProgramStartUtcMs = null
        ..focusedProgramEndUtcMs = null
        ..focusedChannelViewportOffset = null
        ..verticalOffset = 0;
      _initialMatrixFocusPending = true;
      _exactProgramRestorePending = false;
      _sharedFocusChannelId = null;
      _sharedFocusProgramStartUtcMs = null;
      _sharedFocusProgramEndUtcMs = null;
      _visualFocusChannelId = null;
      _visualFocusProgramStartUtcMs = null;
      _visualFocusProgramEndUtcMs = null;
      _fallbackAnnouncementChannelId = null;
      _fallbackAnnouncementFocusNode = null;
      _focusAnnouncement = false;
      _refreshAttempts.clear();
      setState(() {
        _channels = page.items;
        _previousCursor = null;
        _nextCursor = page.nextCursor;
        _windows = const {};
        _activeEpgIds = const [];
        _epgViewportHistory = const [];
        _failedCategory = null;
        _loadingPage = false;
        _loadingPrevious = false;
        _loadingMore = false;
        _previousRequestGeneration = null;
        _moreRequestGeneration = null;
        _restoreAnchorIndex = null;
        _refreshFailed = false;
      });
      if (_vertical.hasClients) _vertical.jumpTo(0);
      _restorePositionAndFocus();
      _scheduleVisibleEpg(immediate: true);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadError = Object();
        _failedCategory = category;
        _loadingPage = false;
        _loadingPrevious = false;
        _loadingMore = false;
        _previousRequestGeneration = null;
        _moreRequestGeneration = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _failedCategory != null) {
          widget.initialFocus.requestFocus();
        }
      });
    }
  }

  void _retryFailedCategory() {
    final failed = _failedCategory;
    final categories = _categories ?? const <BrowseCategorySummary>[];
    if (failed == null) return;
    final index = categories.indexWhere(
      (candidate) => _sameCategory(candidate.selection, failed.selection),
    );
    if (index < 0) {
      _restoreFailedCategory();
      return;
    }
    unawaited(_chooseCategory(index));
  }

  void _restoreFailedCategory() {
    setState(() {
      _loadError = null;
      _failedCategory = null;
      _loadingPage = false;
      _loadingPrevious = false;
      _loadingMore = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _categoryFocus.requestFocus();
      _scheduleVisibleEpg(immediate: true);
    });
  }

  Future<void> _loadPrevious({bool manualRetry = false}) async {
    final cursor = _previousCursor;
    final source = _source;
    final category = _category;
    final restoration = widget.data;
    if (cursor == null ||
        source == null ||
        category == null ||
        restoration is! GuideRestorationDataPort ||
        _loadingPrevious ||
        (_pageFailure == _GuidePageFailure.earlier && !manualRetry)) {
      return;
    }
    final restorationPort = restoration as GuideRestorationDataPort;
    final generation = _generation;
    setState(() {
      _loadingPrevious = true;
      _previousRequestGeneration = generation;
    });
    try {
      final page = await restorationPort.loadPreviousChannels(
        sourceId: source.id,
        selection: category.selection,
        cursor: cursor,
        limit: guideChannelPageSize,
      );
      if (!mounted) return;
      if (generation != _generation) {
        if (_previousRequestGeneration == generation) {
          setState(() {
            _loadingPrevious = false;
            _previousRequestGeneration = null;
          });
        }
        return;
      }
      final currentOffset = _vertical.hasClients ? _vertical.offset : 0.0;
      final matrixFocusActive =
          _channelNodes.values.any((node) => node.hasFocus) ||
          _programNodes.values.any((node) => node.hasFocus);
      final existingIds = _channels.map((channel) => channel.id).toSet();
      final prepended = page.items
          .where((channel) => !existingIds.contains(channel.id))
          .toList(growable: false);
      if (_pageFailure == _GuidePageFailure.earlier && _retryFocus.hasFocus) {
        _focusRememberedMatrixTarget();
      }
      setState(() {
        _channels = [...prepended, ..._channels];
        _previousCursor = page.previousCursor;
        _loadingPrevious = false;
        _previousRequestGeneration = null;
        if (_pageFailure == _GuidePageFailure.earlier) {
          _pageFailure = null;
        }
      });
      if (prepended.isNotEmpty) {
        final correction = prepended.length * _rowExtent;
        final targetOffset = currentOffset + correction;
        if (_vertical.hasClients) {
          _vertical.position.correctBy(correction);
          widget.session.verticalOffset = targetOffset;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_vertical.hasClients) return;
          final boundedTarget = targetOffset.clamp(
            0.0,
            _vertical.position.maxScrollExtent,
          );
          if ((_vertical.offset - boundedTarget).abs() > 0.1) {
            _vertical.jumpTo(boundedTarget);
          }
          if (matrixFocusActive) {
            _focusRememberedMatrixTarget();
          }
        });
      }
      _scheduleVisibleEpg(immediate: true);
    } catch (_) {
      if (!mounted) return;
      if (generation != _generation) {
        if (_previousRequestGeneration == generation) {
          setState(() {
            _loadingPrevious = false;
            _previousRequestGeneration = null;
          });
        }
        return;
      }
      setState(() {
        _loadingPrevious = false;
        _previousRequestGeneration = null;
        _pageFailure = _GuidePageFailure.earlier;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageFailure == _GuidePageFailure.earlier) {
          _retryFocus.requestFocus();
        }
      });
    }
  }

  Future<void> _loadMore({bool manualRetry = false}) async {
    final cursor = _nextCursor;
    final source = _source;
    final category = _category;
    if (cursor == null ||
        source == null ||
        category == null ||
        _loadingMore ||
        (_pageFailure == _GuidePageFailure.more && !manualRetry)) {
      return;
    }
    final generation = _generation;
    setState(() {
      _loadingMore = true;
      _moreRequestGeneration = generation;
    });
    try {
      final page = await widget.data.loadChannels(
        sourceId: source.id,
        selection: category.selection,
        cursor: cursor,
        limit: guideChannelPageSize,
      );
      if (!mounted) return;
      if (generation != _generation) {
        if (_moreRequestGeneration == generation) {
          setState(() {
            _loadingMore = false;
            _moreRequestGeneration = null;
          });
        }
        return;
      }
      if (_pageFailure == _GuidePageFailure.more && _retryFocus.hasFocus) {
        _focusRememberedMatrixTarget();
      }
      setState(() {
        _channels = [..._channels, ...page.items];
        _nextCursor = page.nextCursor;
        _loadingMore = false;
        _moreRequestGeneration = null;
        if (_pageFailure == _GuidePageFailure.more) {
          _pageFailure = null;
        }
      });
      _scheduleVisibleEpg(immediate: true);
    } catch (_) {
      if (!mounted) return;
      if (generation != _generation) {
        if (_moreRequestGeneration == generation) {
          setState(() {
            _loadingMore = false;
            _moreRequestGeneration = null;
          });
        }
        return;
      }
      setState(() {
        _loadingMore = false;
        _moreRequestGeneration = null;
        _pageFailure = _GuidePageFailure.more;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageFailure == _GuidePageFailure.more) {
          _retryFocus.requestFocus();
        }
      });
    }
  }

  void _onVerticalScroll() {
    widget.session.verticalOffset = _vertical.offset;
    if (_vertical.position.extentBefore < _rowExtent * 4) {
      unawaited(_loadPrevious());
    }
    if (_vertical.position.extentAfter < _rowExtent * 4) {
      unawaited(_loadMore());
    }
    _scheduleVisibleEpg();
  }

  void _onTimelineScroll() {
    widget.session.horizontalOffset = _timeline.offset;
    if (mounted) {
      if (_goNowFocus.hasFocus && !_awayFromNow) {
        _focusRememberedMatrixTarget();
      }
      setState(() {});
    }
  }

  void _scheduleVisibleEpg({bool immediate = false}) {
    _visibleTimer?.cancel();
    if (immediate) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadVisibleEpg());
    } else {
      _visibleTimer = Timer(const Duration(milliseconds: 120), _loadVisibleEpg);
    }
  }

  Future<void> _loadVisibleEpg({
    bool forceRefresh = false,
    bool manualRetry = false,
  }) async {
    if (!mounted || _channels.isEmpty) return;
    final viewport = _vertical.hasClients
        ? _vertical.position.viewportDimension
        : _rowExtent * 8;
    final offset = _vertical.hasClients ? _vertical.offset : 0.0;
    final first = math.max(0, (offset / _rowExtent).floor() - 2);
    final count = math.min(
      guidePresentationEpgLimit,
      (viewport / _rowExtent).ceil() + 6,
    );
    final end = math.min(_channels.length, first + count);
    if (first >= end) return;
    final ids = _channels
        .sublist(first, end)
        .map((channel) => channel.id)
        .toList(growable: false);
    _activateEpgViewport(ids);
    final generation = _generation;
    final windowRequest = ++_windowRequest;
    await _readEpg(ids, generation, windowRequest);
    if (!mounted ||
        generation != _generation ||
        windowRequest != _windowRequest) {
      return;
    }
    final attemptedAt = _nowUtc;
    final retainedIds = _retainedEpgIds;
    _refreshAttempts.removeWhere((id, _) => !retainedIds.contains(id));
    final toRefresh = forceRefresh
        ? ids
        : ids
              .where((id) {
                final previous = _refreshAttempts[id];
                return previous == null ||
                    attemptedAt.difference(previous) >=
                        const Duration(minutes: 5);
              })
              .toList(growable: false);
    if (toRefresh.isEmpty) return;
    for (final id in toRefresh) {
      _refreshAttempts[id] = attemptedAt;
    }
    final refresh = await widget.data.refreshCatalogItems(
      toRefresh,
      manualRetry: manualRetry,
    );
    if (!mounted ||
        generation != _generation ||
        windowRequest != _windowRequest) {
      return;
    }
    await _readEpg(
      ids,
      generation,
      windowRequest,
      refreshRequestFailed:
          refresh.failure == EpgRefreshFailure.localPersistence,
    );
    if (!mounted ||
        generation != _generation ||
        windowRequest != _windowRequest) {
      return;
    }
  }

  Future<void> _readEpg(
    List<String> ids,
    int generation,
    int windowRequest, {
    bool refreshRequestFailed = false,
  }) async {
    try {
      final windows = await widget.data.loadEpgWindow(
        catalogItemIds: ids,
        windowStartUtc: _windowStartUtc,
        windowEndUtc: _windowEndUtc,
        atUtc: _nowUtc,
      );
      if (!mounted ||
          generation != _generation ||
          windowRequest != _windowRequest) {
        return;
      }
      final refreshFailed = windows.any(
        (window) =>
            window.availability == EpgAvailability.temporarilyUnavailable,
      );
      if (_pageFailure == null && _retryFocus.hasFocus && !refreshFailed) {
        _focusRememberedMatrixTarget();
      }
      setState(() {
        final retainedIds = _retainedEpgIds;
        _windows = Map.unmodifiable({
          for (final entry in _windows.entries)
            if (retainedIds.contains(entry.key)) entry.key: entry.value,
          for (final window in windows)
            if (retainedIds.contains(window.catalogItemId))
              window.catalogItemId: window,
        });
        _refreshFailed = refreshFailed || refreshRequestFailed;
      });
      _settleRestoredMatrixFocus(windows);
      _settleInitialMatrixFocus(windows);
      final deferredNowFocus = _deferredNowFocus;
      if (deferredNowFocus != null &&
          !_matchesDeferredNowFocus(deferredNowFocus)) {
        _deferredNowFocus = null;
      }
      final nowFocusWindow = windows
          .where(
            (window) => window.catalogItemId == widget.session.focusedChannelId,
          )
          .firstOrNull;
      if (deferredNowFocus != null &&
          _matchesDeferredNowFocus(deferredNowFocus) &&
          nowFocusWindow != null &&
          nowFocusWindow.availability != EpgAvailability.unknown &&
          nowFocusWindow.availability != EpgAvailability.refreshing) {
        _deferredNowFocus = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final focus = FocusManager.instance.primaryFocus;
          if (mounted &&
              _matchesDeferredNowFocus(deferredNowFocus) &&
              focus != null &&
              _isDeferredNowFlowFocus(focus)) {
            _focusNowOnRememberedChannel();
          }
        });
      }
      _scheduleBoundaryRefresh();
    } catch (_) {
      if (mounted &&
          generation == _generation &&
          windowRequest == _windowRequest) {
        setState(() => _refreshFailed = true);
        _scheduleBoundaryRefresh(forceFallback: true);
      }
    }
  }

  void _activateEpgViewport(List<String> ids) {
    if (_sameStringList(ids, _activeEpgIds)) return;
    final history = <List<String>>[List.unmodifiable(ids)];
    for (final snapshot in _epgViewportHistory) {
      if (_sameStringList(snapshot, ids)) continue;
      history.add(snapshot);
      if (history.length == _guideEpgViewportHistoryLimit) break;
    }
    final retainedIds = _retainedIdsFor(history);
    setState(() {
      _activeEpgIds = List.unmodifiable(ids);
      _epgViewportHistory = List.unmodifiable(history);
      _windows = Map.unmodifiable({
        for (final entry in _windows.entries)
          if (retainedIds.contains(entry.key)) entry.key: entry.value,
      });
    });
  }

  Set<String> get _retainedEpgIds => _retainedIdsFor(_epgViewportHistory);

  Set<String> _retainedIdsFor(List<List<String>> history) {
    final retained = <String>{};
    for (final snapshot in history) {
      for (final id in snapshot) {
        if (retained.length == _guideEpgCacheLimit) return retained;
        retained.add(id);
      }
    }
    return retained;
  }

  void _scheduleBoundaryRefresh({bool forceFallback = false}) {
    _boundaryTimer?.cancel();
    final now = _nowUtc;
    DateTime? boundary;
    for (final id in _activeEpgIds) {
      final window = _windows[id];
      if (window == null) continue;
      for (final program in window.programs) {
        for (final candidate in [program.startUtc, program.endUtc]) {
          if (candidate.isAfter(now) &&
              (boundary == null || candidate.isBefore(boundary))) {
            boundary = candidate;
          }
        }
      }
      final fallbackDelay = switch (window.availability) {
        EpgAvailability.unknown ||
        EpgAvailability.refreshing ||
        EpgAvailability.temporarilyUnavailable => const Duration(minutes: 5),
        EpgAvailability.empty => const Duration(minutes: 15),
        EpgAvailability.available when window.programs.isEmpty =>
          const Duration(minutes: 30),
        EpgAvailability.unsupported => const Duration(hours: 6),
        EpgAvailability.available => null,
      };
      if (fallbackDelay != null) {
        final fallback = now.add(fallbackDelay);
        if (boundary == null || fallback.isBefore(boundary)) {
          boundary = fallback;
        }
      }
    }
    final horizontalOffset = _timeline.hasClients
        ? _timeline.offset
        : widget.session.horizontalOffset;
    final goNowWake = _windowStartUtc.add(
      Duration(
        milliseconds:
            ((horizontalOffset + 170) /
                    _hourWidth *
                    Duration.millisecondsPerHour)
                .round(),
      ),
    );
    if (goNowWake.isAfter(now) &&
        (boundary == null || goNowWake.isBefore(boundary))) {
      boundary = goNowWake;
    }
    if (_windowEndUtc.isAfter(now) &&
        (boundary == null || _windowEndUtc.isBefore(boundary))) {
      boundary = _windowEndUtc;
    }
    if (boundary == null && forceFallback) {
      boundary = now.add(const Duration(minutes: 5));
    }
    if (boundary == null) return;
    final delay = boundary.difference(now) + const Duration(milliseconds: 100);
    _boundaryTimer = Timer(delay, () => _loadVisibleEpg());
  }

  void _settleInitialMatrixFocus(List<EpgChannelWindow> windows) {
    if (!_initialMatrixFocusPending || _channels.isEmpty) return;
    final firstId = _channels.first.id;
    final window = windows
        .where((candidate) => candidate.catalogItemId == firstId)
        .firstOrNull;
    if (window == null ||
        window.availability == EpgAvailability.unknown ||
        window.availability == EpgAvailability.refreshing) {
      return;
    }
    _initialMatrixFocusPending = false;
    final now = _nowUtc;
    final current = window.programs
        .where(
          (program) =>
              !program.startUtc.isAfter(now) && program.endUtc.isAfter(now),
        )
        .firstOrNull;
    if (current == null) return;
    widget.session
      ..focusedChannelId = firstId
      ..focusedProgramStartUtcMs = current.startUtc.millisecondsSinceEpoch
      ..focusedProgramEndUtcMs = current.endUtc.millisecondsSinceEpoch;
    _sharedFocusChannelId = firstId;
    _sharedFocusProgramStartUtcMs = current.startUtc.millisecondsSinceEpoch;
    _sharedFocusProgramEndUtcMs = current.endUtc.millisecondsSinceEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusProgram(0, window.programs.indexOf(current));
    });
  }

  void _settleRestoredMatrixFocus(List<EpgChannelWindow> windows) {
    if (!_exactProgramRestorePending) return;
    final channelId = widget.session.focusedChannelId;
    final start = widget.session.focusedProgramStartUtcMs;
    final end = widget.session.focusedProgramEndUtcMs;
    if (channelId == null || start == null || end == null) {
      _exactProgramRestorePending = false;
      return;
    }
    final window = windows
        .where((candidate) => candidate.catalogItemId == channelId)
        .firstOrNull;
    if (window == null ||
        window.availability == EpgAvailability.unknown ||
        window.availability == EpgAvailability.refreshing) {
      return;
    }
    final row = _channels.indexWhere((channel) => channel.id == channelId);
    if (row < 0) return;
    final index = window.programs.indexWhere(
      (program) =>
          program.startUtc.millisecondsSinceEpoch == start &&
          program.endUtc.millisecondsSinceEpoch == end,
    );
    _exactProgramRestorePending = false;
    if (index >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusProgram(row, index);
      });
      return;
    }
    setState(() {
      widget.session
        ..focusedProgramStartUtcMs = null
        ..focusedProgramEndUtcMs = null;
      _sharedFocusProgramStartUtcMs = null;
      _sharedFocusProgramEndUtcMs = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusChannel(row);
    });
  }

  void _restorePositionAndFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_vertical.hasClients) {
        final anchorIndex = _restoreAnchorIndex;
        if (anchorIndex != null && anchorIndex >= 0) {
          final extent = _rowExtent;
          final maxRelative = math.max(
            0.0,
            _vertical.position.viewportDimension - extent,
          );
          final relativeOffset =
              (widget.session.focusedChannelViewportOffset ?? extent * 2)
                  .clamp(0.0, maxRelative)
                  .toDouble();
          widget.session
            ..focusedChannelViewportOffset = relativeOffset
            ..verticalOffset = math.max(
              0,
              anchorIndex * extent - relativeOffset,
            );
        }
        _restoreAnchorIndex = null;
        _vertical.jumpTo(
          widget.session.verticalOffset.clamp(
            0.0,
            _vertical.position.maxScrollExtent,
          ),
        );
      }
      if (_timeline.hasClients) {
        _timeline.jumpTo(
          widget.session.horizontalOffset.clamp(
            0.0,
            _timeline.position.maxScrollExtent,
          ),
        );
      }
      _restoreFocus();
    });
  }

  void _restoreFocus() {
    final channelId = widget.session.focusedChannelId;
    final start = widget.session.focusedProgramStartUtcMs;
    final end = widget.session.focusedProgramEndUtcMs;
    if (channelId != null && start != null && end != null) {
      final node = _programNodes[_programKey(channelId, start, end)];
      if (node != null) {
        node.requestFocus();
        return;
      }
      if (_exactProgramRestorePending) return;
    }
    if (channelId != null) {
      final node = _channelNodes[channelId];
      if (node != null) {
        node.requestFocus();
        return;
      }
    }
    if (_channels.isNotEmpty) widget.initialFocus.requestFocus();
  }

  void _focusChannel(int index) {
    if (index < 0 || index >= _channels.length) return;
    _revealRow(index, () {
      final channel = _channels[index];
      _channelNodes[channel.id]?.requestFocus();
    });
  }

  void _focusProgram(int row, int index, {bool revealTimeline = true}) {
    final programs = _programsForRow(row);
    if (row < 0 ||
        row >= _channels.length ||
        index < 0 ||
        index >= programs.length) {
      _focusChannel(row);
      return;
    }
    final program = programs[index];
    if (revealTimeline) _revealProgram(program);
    _revealRow(row, () {
      _programNodes[_programKey(
            _channels[row].id,
            program.startUtc.millisecondsSinceEpoch,
            program.endUtc.millisecondsSinceEpoch,
          )]
          ?.requestFocus();
    });
  }

  void _revealRow(int row, VoidCallback focus) {
    if (!_vertical.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) => focus());
      return;
    }
    final start = row * _rowExtent;
    final end = start + _rowExtent;
    final visibleStart = _vertical.offset;
    final visibleEnd = visibleStart + _vertical.position.viewportDimension;
    if (start < visibleStart || end > visibleEnd) {
      _vertical.jumpTo(
        (start - _rowExtent).clamp(0.0, _vertical.position.maxScrollExtent),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => focus());
    } else {
      focus();
    }
  }

  void _revealProgram(EpgProgram program) {
    if (!_timeline.hasClients) return;
    final start = _xFor(program.startUtc);
    final end = _xFor(program.endUtc);
    final visibleStart = _timeline.offset;
    final visibleEnd = visibleStart + _timeline.position.viewportDimension;
    if (start < visibleStart || end > visibleEnd) {
      final target = (start - 36).clamp(
        0.0,
        _timeline.position.maxScrollExtent,
      );
      _timeline.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _focusNearestProgram(int fromRow, int toRow, EpgProgram origin) {
    final targetPrograms = _programsForRow(toRow);
    if (targetPrograms.isEmpty) {
      _focusChannel(toRow);
      return;
    }
    final midpoint =
        origin.startUtc.millisecondsSinceEpoch +
        (origin.endUtc.millisecondsSinceEpoch -
                origin.startUtc.millisecondsSinceEpoch) ~/
            2;
    var best = 0;
    var bestDistance = 1 << 62;
    for (var index = 0; index < targetPrograms.length; index++) {
      final program = targetPrograms[index];
      final overlaps =
          program.startUtc.millisecondsSinceEpoch <= midpoint &&
          program.endUtc.millisecondsSinceEpoch > midpoint;
      final programMid =
          program.startUtc.millisecondsSinceEpoch +
          (program.endUtc.millisecondsSinceEpoch -
                  program.startUtc.millisecondsSinceEpoch) ~/
              2;
      final distance = overlaps ? 0 : (programMid - midpoint).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = index;
      }
    }
    _focusProgram(toRow, best);
  }

  List<EpgProgram> _programsForRow(int row) {
    if (row < 0 || row >= _channels.length) return const [];
    return _windows[_channels[row].id]?.programs ?? const [];
  }

  void _tune(BrowseCatalogItem channel, {bool clearProgramIdentity = false}) {
    widget.session.focusedChannelId = channel.id;
    if (clearProgramIdentity) {
      widget.session
        ..focusedProgramStartUtcMs = null
        ..focusedProgramEndUtcMs = null;
      _visualFocusChannelId = channel.id;
      _visualFocusProgramStartUtcMs = null;
      _visualFocusProgramEndUtcMs = null;
    }
    final desiredChannel = widget.session.focusedChannelId;
    final desiredProgram = widget.session.focusedProgramStartUtcMs;
    final desiredProgramEnd = widget.session.focusedProgramEndUtcMs;
    if (_sharedFocusChannelId != desiredChannel ||
        _sharedFocusProgramStartUtcMs != desiredProgram ||
        _sharedFocusProgramEndUtcMs != desiredProgramEnd) {
      setState(() {
        _sharedFocusChannelId = desiredChannel;
        _sharedFocusProgramStartUtcMs = desiredProgram;
        _sharedFocusProgramEndUtcMs = desiredProgramEnd;
      });
    }
    _dispatchTune(channel);
  }

  void _dispatchTune(BrowseCatalogItem channel) {
    try {
      widget.onPlaybackHandoff(playbackHandoffFor(channel));
    } on ContinuationException {
      setState(() => _refreshFailed = true);
    }
  }

  double _xFor(DateTime instant) =>
      instant.toUtc().difference(_windowStartUtc).inSeconds /
      Duration.secondsPerHour *
      _hourWidth;

  double get _timelineWidth => _guideHours * _hourWidth;

  bool get _awayFromNow {
    if (!_timeline.hasClients) return false;
    final nowX = _xFor(_nowUtc);
    final preferred = math.max(0.0, nowX - 90);
    return (_timeline.offset - preferred).abs() > 80;
  }

  void _goToNow() => _goToNowAndRefocus();

  void _goToNowAndRefocus() {
    if (!_timeline.hasClients) return;
    final now = _nowUtc;
    if (now.isBefore(_windowStartUtc) || !now.isBefore(_windowEndUtc)) {
      _categoryFocus.requestFocus();
      _windowRequest += 1;
      _visibleTimer?.cancel();
      _boundaryTimer?.cancel();
      final start = _windowStartFor(now);
      setState(() {
        _windowStartUtc = start;
        _windowEndUtc = start.add(const Duration(hours: _guideHours));
        widget.session
          ..windowStartUtc = start
          ..horizontalOffset = 0
          ..focusedProgramStartUtcMs = null
          ..focusedProgramEndUtcMs = null;
        _sharedFocusProgramStartUtcMs = null;
        _sharedFocusProgramEndUtcMs = null;
        _visualFocusProgramStartUtcMs = null;
        _visualFocusProgramEndUtcMs = null;
        _exactProgramRestorePending = false;
        _deferredNowFocus = _GuideDeferredNowFocus(
          generation: _generation,
          sourceId: widget.session.sourceId,
          categoryKind: widget.session.category.kind,
          categoryGroupId: widget.session.category.sourceGroupId,
          windowStartUtc: start,
          windowEndUtc: _windowEndUtc,
        );
        _windows = const {};
        _activeEpgIds = const [];
        _epgViewportHistory = const [];
        _refreshFailed = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_timeline.hasClients) _timeline.jumpTo(0);
        _focusRememberedChannelTarget();
        _scheduleVisibleEpg(immediate: true);
      });
      return;
    }
    _categoryFocus.requestFocus();
    final target = math
        .max(0.0, _xFor(now) - 90)
        .clamp(0.0, _timeline.position.maxScrollExtent);
    _timeline.jumpTo(target);
    if (mounted) _focusNowOnRememberedChannel();
  }

  void _focusNowOnRememberedChannel() {
    if (_channels.isEmpty) return;
    final rememberedId = widget.session.focusedChannelId;
    final row = rememberedId == null
        ? 0
        : _channels.indexWhere((channel) => channel.id == rememberedId);
    final targetRow = row < 0 ? 0 : row;
    final programs = _programsForRow(targetRow);
    final now = _nowUtc;
    var index = programs.indexWhere(
      (program) =>
          !program.startUtc.isAfter(now) && program.endUtc.isAfter(now),
    );
    if (index < 0 && _timeline.hasClients) {
      final visibleStart = _timeline.offset;
      final visibleEnd = visibleStart + _timeline.position.viewportDimension;
      var distance = 1 << 62;
      for (var candidate = 0; candidate < programs.length; candidate++) {
        final program = programs[candidate];
        final left = _xFor(program.startUtc);
        final right = _xFor(program.endUtc);
        if (right <= visibleStart || left >= visibleEnd) continue;
        final candidateDistance = program.startUtc
            .difference(now)
            .inSeconds
            .abs();
        if (candidateDistance < distance) {
          distance = candidateDistance;
          index = candidate;
        }
      }
    }
    if (index >= 0) {
      _focusProgram(targetRow, index, revealTimeline: false);
    } else {
      widget.session
        ..focusedChannelId = _channels[targetRow].id
        ..focusedProgramStartUtcMs = null
        ..focusedProgramEndUtcMs = null;
      _focusChannel(targetRow);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      final failedCategory = _failedCategory;
      if (failedCategory != null) {
        return _GuideMessage(
          title: 'Guide category unavailable',
          message:
              '${failedCategory.name} could not be loaded. Your previous Guide category is unchanged.',
          primaryLabel: 'Retry',
          primaryAction: _retryFailedCategory,
          secondaryLabel: 'Keep current category',
          secondaryAction: _restoreFailedCategory,
          focusNode: widget.initialFocus,
          onFocused: widget.onContentFocus,
          onLeft: widget.onOpenRail,
        );
      }
      return _GuideMessage(
        title: 'Guide unavailable',
        message: 'The saved guide could not be loaded. Live TV is unchanged.',
        primaryLabel: 'Try again',
        primaryAction: _loadGuide,
        secondaryLabel: 'Browse Live',
        secondaryAction: widget.onBrowseLive,
        focusNode: widget.initialFocus,
        onFocused: widget.onContentFocus,
        onLeft: widget.onOpenRail,
      );
    }
    final sources = _sources;
    if (sources != null && sources.isEmpty) {
      return _GuideMessage(
        title: 'Guide needs an Xtream source',
        message: 'Add or enable an Xtream source to use the Live Guide. M3U channels remain available in Live.',
        primaryLabel: 'Open Settings',
        primaryAction: widget.onOpenSettings,
        secondaryLabel: 'Browse Live',
        secondaryAction: widget.onBrowseLive,
        focusNode: widget.initialFocus,
        onFocused: widget.onContentFocus,
        onLeft: widget.onOpenRail,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        final channelWidth = narrow ? 168.0 : 228.0;
        return ColoredBox(
          color: _graphite,
          child: SafeArea(
            left: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                narrow ? 20 : 32,
                22,
                narrow ? 20 : 32,
                28,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(context, narrow),
                  const SizedBox(height: 14),
                  _buildStatus(context),
                  const SizedBox(height: 6),
                  Semantics(
                    liveRegion: _focusAnnouncement,
                    child: Text(
                      _focusContext ??
                          'Select a channel or program to tune Live.',
                      key: const ValueKey('guide-focus-context'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _quietText, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _loadingPage && _channels.isEmpty
                        ? const _GuideSkeleton()
                        : _channels.isEmpty
                        ? _GuideEmpty(
                            focusNode: widget.initialFocus,
                            onFocused: widget.onContentFocus,
                            onLeft: widget.onOpenRail,
                            onBrowseLive: widget.onBrowseLive,
                          )
                        : _buildMatrix(context, channelWidth),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, bool narrow) {
    final localNow = _localize(_nowUtc);
    final localizations = MaterialLocalizations.of(context);
    final subtitle =
        '${localizations.formatFullDate(localNow.wallTime)} · ${_formatGuideCompactTime(localizations, localNow, includeZone: _visibleRangeCrossesOffsetTransition)}';
    final source = _source;
    final sources = _sources ?? const <SourceRosterEntry>[];
    final categories = _categories ?? const <BrowseCategorySummary>[];
    final selectedCategory = math.max(
      0,
      categories.indexWhere(
        (entry) => _sameCategory(entry.selection, widget.session.category),
      ),
    );
    final selectors = Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: narrow ? 210 : 230,
          child: _GuideDropdown<String>(
            key: const ValueKey('guide-source-selector'),
            focusNode: _sourceFocus,
            label: 'Source',
            value: source?.id,
            values: [for (final entry in sources) entry.id],
            labels: [for (final entry in sources) entry.name],
            onChanged: (value) => unawaited(_chooseSource(value)),
            onDown: () => _categoryFocus.requestFocus(),
          ),
        ),
        SizedBox(
          width: narrow ? 210 : 250,
          child: _GuideDropdown<int>(
            key: const ValueKey('guide-category-selector'),
            focusNode: _categoryFocus,
            label: 'Category',
            value: categories.isEmpty ? null : selectedCategory,
            values: [for (var i = 0; i < categories.length; i++) i],
            labels: [for (final entry in categories) entry.name],
            onChanged: (value) => unawaited(_chooseCategory(value)),
            onDown: () => _focusRememberedMatrixTarget(),
          ),
        ),
        if (_awayFromNow)
          _GuideButton(
            key: const ValueKey('guide-go-now'),
            label: 'Go to now',
            icon: Icons.schedule,
            focusNode: _goNowFocus,
            onPressed: _goToNow,
            onDown: _focusRememberedMatrixTarget,
          ),
      ],
    );
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Guide',
          style: TextStyle(
            color: _warmWhite,
            fontSize: 31,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.7,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _quietText, fontSize: 14),
        ),
      ],
    );
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [title, const SizedBox(height: 14), selectors],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: title),
        selectors,
      ],
    );
  }

  Widget _buildStatus(BuildContext context) {
    final windows = <EpgChannelWindow>[];
    for (final id in _activeEpgIds) {
      final window = _windows[id];
      if (window != null) windows.add(window);
    }
    final anySaved = windows.any((window) => window.programs.isNotEmpty);
    final anyPreparing =
        _activeEpgIds.isEmpty ||
        _activeEpgIds.any((id) {
          final window = _windows[id];
          return window == null ||
              window.availability == EpgAvailability.unknown ||
              window.availability == EpgAvailability.refreshing;
        });
    final anyFailure = windows.any(
      (window) => window.availability == EpgAvailability.temporarilyUnavailable,
    );
    final allUnsupported =
        _activeEpgIds.isNotEmpty &&
        _activeEpgIds.every(
          (id) => _windows[id]?.availability == EpgAvailability.unsupported,
        );
    final allEmpty =
        _activeEpgIds.isNotEmpty &&
        _activeEpgIds.every((id) {
          final window = _windows[id];
          return window != null &&
              window.programs.isEmpty &&
              (window.availability == EpgAvailability.empty ||
                  window.availability == EpgAvailability.available);
        });
    final pageFailure = _pageFailure;
    final hasEpgFailure = _refreshFailed || anyFailure;
    String text;
    if (pageFailure == _GuidePageFailure.earlier) {
      text = 'Earlier channels could not be loaded · current channels remain available';
    } else if (pageFailure == _GuidePageFailure.more) {
      text = 'More channels could not be loaded · current channels remain available';
    } else if (hasEpgFailure && anySaved) {
      text = 'Guide update failed · showing saved schedule';
    } else if (hasEpgFailure && !anySaved) {
      text = 'Schedule unavailable · channels remain ready to tune';
    } else if (allUnsupported) {
      text = 'This source does not expose a short Live guide · channels remain ready to tune';
    } else if (allEmpty) {
      text = 'No schedule for these channels · channels remain ready to tune';
    } else if (anyPreparing && !anySaved) {
      text = 'Preparing schedule…';
    } else {
      final category = _category;
      final count = category?.itemCount ?? _channels.length;
      text = '${category?.name ?? 'All Live'} · $count channels';
    }
    return Row(
      children: [
        Expanded(
          child: Semantics(
            liveRegion: pageFailure != null || hasEpgFailure,
            child: Text(
              text,
              key: const ValueKey('guide-status'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _quietText, fontSize: 13),
            ),
          ),
        ),
        if (pageFailure != null || hasEpgFailure) ...[
          const SizedBox(width: 12),
          _GuideButton(
            key: const ValueKey('guide-retry'),
            label: switch (pageFailure) {
              _GuidePageFailure.earlier => 'Retry earlier channels',
              _GuidePageFailure.more => 'Retry more channels',
              null => 'Retry',
            },
            icon: Icons.refresh,
            focusNode: _retryFocus,
            onPressed: () {
              if (pageFailure == _GuidePageFailure.earlier) {
                unawaited(_loadPrevious(manualRetry: true));
              } else if (pageFailure == _GuidePageFailure.more) {
                unawaited(_loadMore(manualRetry: true));
              } else {
                _focusRememberedMatrixTarget();
                setState(() => _refreshFailed = false);
                unawaited(
                  _loadVisibleEpg(forceRefresh: true, manualRetry: true),
                );
              }
            },
            onDown: _focusRememberedMatrixTarget,
          ),
        ],
      ],
    );
  }

  Widget _buildMatrix(BuildContext context, double channelWidth) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          SizedBox(
            height: _rulerExtent,
            child: Row(
              children: [
                SizedBox(
                  width: channelWidth,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'CHANNEL',
                        style: TextStyle(
                          color: _quietText,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
                const VerticalDivider(width: 1, color: _line),
                Expanded(
                  child: SingleChildScrollView(
                    key: const ValueKey('guide-time-ruler-scroll'),
                    controller: _timeline,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: _timelineWidth,
                      child: _TimeRuler(
                        startUtc: _windowStartUtc,
                        nowUtc: _nowUtc,
                        hourWidth: _hourWidth,
                        localize: _localize,
                        includeZone: _visibleRangeCrossesOffsetTransition,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _line),
          Expanded(
            child: Listener(
              onPointerSignal: (signal) {
                if (signal is! PointerScrollEvent || !_timeline.hasClients) {
                  return;
                }
                if (HardwareKeyboard.instance.isShiftPressed ||
                    signal.scrollDelta.dx.abs() > signal.scrollDelta.dy.abs()) {
                  final delta = signal.scrollDelta.dx.abs() > 0
                      ? signal.scrollDelta.dx
                      : signal.scrollDelta.dy;
                  _timeline.jumpTo(
                    (_timeline.offset + delta).clamp(
                      0.0,
                      _timeline.position.maxScrollExtent,
                    ),
                  );
                }
              },
              child: ListView.builder(
                key: const ValueKey('guide-channel-list'),
                controller: _vertical,
                itemExtent: _rowExtent,
                scrollCacheExtent: ScrollCacheExtent.pixels(_rowExtent * 4),
                itemCount: _channels.length + (_loadingMore ? 2 : 0),
                findChildIndexCallback: (key) {
                  if (key is! ValueKey<String>) return null;
                  const prefix = 'guide-row-';
                  final value = key.value;
                  if (!value.startsWith(prefix)) return null;
                  final channelId = value.substring(prefix.length);
                  final index = _channels.indexWhere(
                    (channel) => channel.id == channelId,
                  );
                  return index < 0 ? null : index;
                },
                itemBuilder: (context, row) {
                  if (row >= _channels.length) {
                    return const _GuideRowSkeleton();
                  }
                  final channel = _channels[row];
                  final window = _windows[channel.id];
                  final rememberedChannelId = _sharedFocusChannelId;
                  final rememberedProgramStart = _sharedFocusProgramStartUtcMs;
                  final rememberedProgramEnd = _sharedFocusProgramEndUtcMs;
                  final ownsSharedFocus = rememberedChannelId == null
                      ? row == 0
                      : rememberedChannelId == channel.id;
                  return _GuideRow(
                    key: ValueKey('guide-row-${channel.id}'),
                    channel: channel,
                    window: window,
                    row: row,
                    channelWidth: channelWidth,
                    timelineWidth: _timelineWidth,
                    timelineOffset: _timeline.hasClients ? _timeline.offset : 0,
                    windowStartUtc: _windowStartUtc,
                    hourWidth: _hourWidth,
                    nowUtc: _nowUtc,
                    localize: _localize,
                    includeZone: _visibleRangeCrossesOffsetTransition,
                    initialFocusNode: ownsSharedFocus
                        ? widget.initialFocus
                        : null,
                    initialProgramStartUtcMs: ownsSharedFocus
                        ? rememberedProgramStart
                        : null,
                    initialProgramEndUtcMs: ownsSharedFocus
                        ? rememberedProgramEnd
                        : null,
                    focusedProgramStartUtcMs:
                        _visualFocusChannelId == channel.id
                        ? _visualFocusProgramStartUtcMs
                        : null,
                    focusedProgramEndUtcMs: _visualFocusChannelId == channel.id
                        ? _visualFocusProgramEndUtcMs
                        : null,
                    onChannelNodeMounted: (node) =>
                        _channelNodes[channel.id] = node,
                    onChannelNodeUnmounted: (node) {
                      if (identical(_channelNodes[channel.id], node)) {
                        _channelNodes.remove(channel.id);
                      }
                    },
                    onProgramNodeMounted: (program, node) =>
                        _programNodes[_programKey(
                              channel.id,
                              program.startUtc.millisecondsSinceEpoch,
                              program.endUtc.millisecondsSinceEpoch,
                            )] =
                            node,
                    onProgramNodeUnmounted: (program, node) {
                      final key = _programKey(
                        channel.id,
                        program.startUtc.millisecondsSinceEpoch,
                        program.endUtc.millisecondsSinceEpoch,
                      );
                      if (identical(_programNodes[key], node)) {
                        _programNodes.remove(key);
                      }
                    },
                    onChannelFocused: (node) {
                      if (_initialMatrixFocusPending &&
                          _channels.isNotEmpty &&
                          channel.id != _channels.first.id) {
                        _initialMatrixFocusPending = false;
                      }
                      widget.session
                        ..focusedChannelId = channel.id
                        ..focusedProgramStartUtcMs = null
                        ..focusedProgramEndUtcMs = null;
                      setState(() {
                        final preservesFallbackAnnouncement =
                            _focusAnnouncement &&
                            _fallbackAnnouncementChannelId == channel.id &&
                            (_fallbackAnnouncementFocusNode == null ||
                                identical(
                                  _fallbackAnnouncementFocusNode,
                                  node,
                                ));
                        if (preservesFallbackAnnouncement) {
                          _fallbackAnnouncementFocusNode ??= node;
                        } else {
                          _focusContext = '${channel.title} · Live channel';
                          _focusAnnouncement = false;
                          _fallbackAnnouncementChannelId = null;
                          _fallbackAnnouncementFocusNode = null;
                        }
                        _visualFocusChannelId = channel.id;
                        _visualFocusProgramStartUtcMs = null;
                        _visualFocusProgramEndUtcMs = null;
                      });
                      widget.onContentFocus(node);
                    },
                    onProgramFocused: (program, node) {
                      _initialMatrixFocusPending = false;
                      widget.session
                        ..focusedChannelId = channel.id
                        ..focusedProgramStartUtcMs =
                            program.startUtc.millisecondsSinceEpoch
                        ..focusedProgramEndUtcMs =
                            program.endUtc.millisecondsSinceEpoch;
                      setState(() {
                        final preservesFallbackAnnouncement =
                            _focusAnnouncement &&
                            _fallbackAnnouncementChannelId == channel.id &&
                            (_fallbackAnnouncementFocusNode == null ||
                                identical(
                                  _fallbackAnnouncementFocusNode,
                                  node,
                                ));
                        if (preservesFallbackAnnouncement) {
                          _fallbackAnnouncementFocusNode ??= node;
                        } else {
                          _focusContext = _programFocusContext(
                            context,
                            channel,
                            program,
                          );
                          _focusAnnouncement = false;
                          _fallbackAnnouncementChannelId = null;
                          _fallbackAnnouncementFocusNode = null;
                        }
                        _visualFocusChannelId = channel.id;
                        _visualFocusProgramStartUtcMs =
                            program.startUtc.millisecondsSinceEpoch;
                        _visualFocusProgramEndUtcMs =
                            program.endUtc.millisecondsSinceEpoch;
                      });
                      widget.onContentFocus(node);
                    },
                    onChannelTune: () =>
                        _tune(channel, clearProgramIdentity: true),
                    onProgramTune: () => _tune(channel),
                    onVisualProgramActivate: (program, index) {
                      widget.session
                        ..focusedChannelId = channel.id
                        ..focusedProgramStartUtcMs =
                            program.startUtc.millisecondsSinceEpoch
                        ..focusedProgramEndUtcMs =
                            program.endUtc.millisecondsSinceEpoch;
                      setState(() {
                        _visualFocusChannelId = channel.id;
                        _visualFocusProgramStartUtcMs =
                            program.startUtc.millisecondsSinceEpoch;
                        _visualFocusProgramEndUtcMs =
                            program.endUtc.millisecondsSinceEpoch;
                        _focusContext = _programFocusContext(
                          context,
                          channel,
                          program,
                        );
                        _focusAnnouncement = false;
                        _fallbackAnnouncementChannelId = null;
                        _fallbackAnnouncementFocusNode = null;
                      });
                      _focusProgram(row, index);
                      _tune(channel);
                    },
                    onChannelLeft: widget.onOpenRail,
                    onChannelRight: () {
                      final programs = _programsForRow(row);
                      if (programs.isEmpty) return;
                      final now = _nowUtc;
                      var index = programs.indexWhere(
                        (program) =>
                            !program.startUtc.isAfter(now) &&
                            program.endUtc.isAfter(now),
                      );
                      if (index < 0) {
                        index = programs.indexWhere(
                          (program) => !program.startUtc.isBefore(now),
                        );
                      }
                      _focusProgram(row, math.max(0, index));
                    },
                    onUpFromChannel: row == 0
                        ? () => _categoryFocus.requestFocus()
                        : () => _focusChannel(row - 1),
                    onDownFromChannel: () {
                      if (row + 1 < _channels.length) {
                        _focusChannel(row + 1);
                      } else {
                        unawaited(_loadMore());
                      }
                    },
                    onProgramLeft: (index) => index == 0
                        ? _focusChannel(row)
                        : _focusProgram(row, index - 1),
                    onProgramRight: (index) {
                      final programs = _programsForRow(row);
                      if (index + 1 < programs.length) {
                        _focusProgram(row, index + 1);
                      }
                    },
                    onProgramUp: (program) => row == 0
                        ? _categoryFocus.requestFocus()
                        : _focusNearestProgram(row, row - 1, program),
                    onProgramDown: (program) {
                      if (row + 1 < _channels.length) {
                        _focusNearestProgram(row, row + 1, program);
                      } else {
                        unawaited(_loadMore());
                      }
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _focusRememberedMatrixTarget() {
    final channelId = widget.session.focusedChannelId;
    final row = channelId == null
        ? 0
        : _channels.indexWhere((channel) => channel.id == channelId);
    if (row < 0) {
      _focusChannel(0);
      return;
    }
    final start = widget.session.focusedProgramStartUtcMs;
    final end = widget.session.focusedProgramEndUtcMs;
    final programs = _programsForRow(row);
    final index = start == null || end == null
        ? -1
        : programs.indexWhere(
            (program) =>
                program.startUtc.millisecondsSinceEpoch == start &&
                program.endUtc.millisecondsSinceEpoch == end,
          );
    if (index >= 0) {
      _focusProgram(row, index);
    } else {
      _focusChannel(row);
    }
  }

  void _focusRememberedChannelTarget() {
    final channelId = widget.session.focusedChannelId;
    final row = channelId == null
        ? 0
        : _channels.indexWhere((channel) => channel.id == channelId);
    _focusChannel(row < 0 ? 0 : row);
  }

  String _programFocusContext(
    BuildContext context,
    BrowseCatalogItem channel,
    EpgProgram program,
  ) {
    final localizations = MaterialLocalizations.of(context);
    final range = _formatGuideRange(
      localizations,
      _localize(program.startUtc),
      _localize(program.endUtc),
      includeZone: _visibleRangeCrossesOffsetTransition,
    );
    return '${channel.title} · ${program.title} · $range';
  }
}

class _GuideRow extends StatelessWidget {
  const _GuideRow({
    super.key,
    required this.channel,
    required this.window,
    required this.row,
    required this.channelWidth,
    required this.timelineWidth,
    required this.timelineOffset,
    required this.windowStartUtc,
    required this.hourWidth,
    required this.nowUtc,
    required this.localize,
    required this.includeZone,
    required this.initialFocusNode,
    required this.initialProgramStartUtcMs,
    required this.initialProgramEndUtcMs,
    required this.focusedProgramStartUtcMs,
    required this.focusedProgramEndUtcMs,
    required this.onChannelNodeMounted,
    required this.onChannelNodeUnmounted,
    required this.onProgramNodeMounted,
    required this.onProgramNodeUnmounted,
    required this.onChannelFocused,
    required this.onProgramFocused,
    required this.onChannelTune,
    required this.onProgramTune,
    required this.onVisualProgramActivate,
    required this.onChannelLeft,
    required this.onChannelRight,
    required this.onUpFromChannel,
    required this.onDownFromChannel,
    required this.onProgramLeft,
    required this.onProgramRight,
    required this.onProgramUp,
    required this.onProgramDown,
  });

  final BrowseCatalogItem channel;
  final EpgChannelWindow? window;
  final int row;
  final double channelWidth;
  final double timelineWidth;
  final double timelineOffset;
  final DateTime windowStartUtc;
  final double hourWidth;
  final DateTime nowUtc;
  final GuideLocalInstant Function(DateTime utc) localize;
  final bool includeZone;
  final FocusNode? initialFocusNode;
  final int? initialProgramStartUtcMs;
  final int? initialProgramEndUtcMs;
  final int? focusedProgramStartUtcMs;
  final int? focusedProgramEndUtcMs;
  final ValueChanged<FocusNode> onChannelNodeMounted;
  final ValueChanged<FocusNode> onChannelNodeUnmounted;
  final void Function(EpgProgram, FocusNode) onProgramNodeMounted;
  final void Function(EpgProgram, FocusNode) onProgramNodeUnmounted;
  final ValueChanged<FocusNode> onChannelFocused;
  final void Function(EpgProgram, FocusNode) onProgramFocused;
  final VoidCallback onChannelTune;
  final VoidCallback onProgramTune;
  final void Function(EpgProgram, int) onVisualProgramActivate;
  final VoidCallback onChannelLeft;
  final VoidCallback onChannelRight;
  final VoidCallback onUpFromChannel;
  final VoidCallback onDownFromChannel;
  final ValueChanged<int> onProgramLeft;
  final ValueChanged<int> onProgramRight;
  final ValueChanged<EpgProgram> onProgramUp;
  final ValueChanged<EpgProgram> onProgramDown;

  @override
  Widget build(BuildContext context) {
    final programs = window?.programs ?? const <EpgProgram>[];
    final layouts = _interactionLayouts(programs);
    final emptyLabel = switch (window?.availability) {
      null ||
      EpgAvailability.unknown ||
      EpgAvailability.refreshing => 'Preparing schedule…',
      EpgAvailability.temporarilyUnavailable => 'Schedule unavailable',
      EpgAvailability.available ||
      EpgAvailability.empty ||
      EpgAvailability.unsupported => 'No schedule available',
    };
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: channelWidth,
            child: _GuideChannelCell(
              channel: channel,
              focusNode:
                  initialProgramStartUtcMs == null ||
                      initialProgramEndUtcMs == null
                  ? initialFocusNode
                  : null,
              onMounted: onChannelNodeMounted,
              onUnmounted: onChannelNodeUnmounted,
              onFocused: onChannelFocused,
              onActivate: onChannelTune,
              onLeft: onChannelLeft,
              onRight: onChannelRight,
              onUp: onUpFromChannel,
              onDown: onDownFromChannel,
            ),
          ),
          const VerticalDivider(width: 1, color: _line),
          Expanded(
            child: ClipRect(
              child: Listener(
                onPointerDown: (_) {},
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: timelineWidth,
                  maxWidth: timelineWidth,
                  child: Transform.translate(
                    offset: Offset(-timelineOffset, 0),
                    child: SizedBox(
                      width: timelineWidth,
                      child: Stack(
                        children: [
                          if (programs.isEmpty)
                            Positioned.fill(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 14),
                                  child: Text(
                                    emptyLabel,
                                    style: const TextStyle(
                                      color: _quietText,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          for (var index = 0; index < layouts.length; index++)
                            _positionedProgramTarget(
                              context,
                              layouts[index],
                              index,
                            ),
                          for (var index = 0; index < layouts.length; index++)
                            _positionedProgramVisual(
                              context,
                              layouts[index],
                              index,
                            ),
                          if (!nowUtc.isBefore(windowStartUtc))
                            Positioned(
                              left: _xFor(nowUtc),
                              top: 0,
                              bottom: 0,
                              child: IgnorePointer(
                                child: Container(width: 1, color: _quietText),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<_GuideProgramLayout> _interactionLayouts(List<EpgProgram> programs) {
    if (programs.isEmpty) return const [];
    final visualLefts = <double>[];
    final visualWidths = <double>[];
    final desiredWidths = <double>[];
    for (final program in programs) {
      final left = _xFor(program.startUtc).clamp(0.0, timelineWidth);
      final right = _xFor(program.endUtc).clamp(0.0, timelineWidth);
      final width = math.max(1.0, right - left);
      visualLefts.add(left);
      visualWidths.add(width);
      desiredWidths.add(math.max(44.0, width));
    }
    final minimumTotal = programs.length * 44.0;
    final desiredTotal = desiredWidths.fold<double>(
      0,
      (sum, width) => sum + width,
    );
    final flexTotal = desiredTotal - minimumTotal;
    final flexScale = desiredTotal <= timelineWidth || flexTotal <= 0
        ? 1.0
        : ((timelineWidth - minimumTotal) / flexTotal).clamp(0.0, 1.0);
    final targetWidths = [
      for (final width in desiredWidths) 44.0 + (width - 44.0) * flexScale,
    ];
    final targetLefts = <double>[];
    var previousEnd = 0.0;
    for (var index = 0; index < programs.length; index++) {
      final center = visualLefts[index] + visualWidths[index] / 2;
      final desiredLeft = (center - targetWidths[index] / 2).clamp(
        0.0,
        math.max(0.0, timelineWidth - targetWidths[index]),
      );
      final left = math.max(previousEnd, desiredLeft).toDouble();
      targetLefts.add(left);
      previousEnd = left + targetWidths[index];
    }
    if (previousEnd > timelineWidth) {
      targetLefts[targetLefts.length - 1] = timelineWidth - targetWidths.last;
      for (var index = targetLefts.length - 2; index >= 0; index--) {
        targetLefts[index] = math.min(
          targetLefts[index],
          targetLefts[index + 1] - targetWidths[index],
        );
      }
    }
    return [
      for (var index = 0; index < programs.length; index++)
        _GuideProgramLayout(
          program: programs[index],
          visualLeft: visualLefts[index],
          visualWidth: visualWidths[index],
          targetLeft: targetLefts[index],
          targetWidth: targetWidths[index],
        ),
    ];
  }

  Widget _positionedProgramVisual(
    BuildContext context,
    _GuideProgramLayout layout,
    int index,
  ) {
    final program = layout.program;
    final localizations = MaterialLocalizations.of(context);
    final time = _formatGuideCompactRange(
      localizations,
      localize(program.startUtc),
      localize(program.endUtc),
      includeZone: includeZone,
    );
    final current =
        !program.startUtc.isAfter(nowUtc) && program.endUtc.isAfter(nowUtc);
    final focused =
        focusedProgramStartUtcMs == program.startUtc.millisecondsSinceEpoch &&
        focusedProgramEndUtcMs == program.endUtc.millisecondsSinceEpoch;
    return Positioned(
      left: layout.visualLeft,
      top: 5,
      width: layout.visualWidth,
      bottom: 5,
      child: _GuideProgramVisual(
        key: ValueKey(
          'guide-program-visual-${channel.id}-${program.startUtc.millisecondsSinceEpoch}-${program.endUtc.millisecondsSinceEpoch}',
        ),
        title: program.title,
        timeLabel: time,
        current: current,
        focused: focused,
        onActivate: () => onVisualProgramActivate(program, index),
      ),
    );
  }

  Widget _positionedProgramTarget(
    BuildContext context,
    _GuideProgramLayout layout,
    int index,
  ) {
    final program = layout.program;
    final localizations = MaterialLocalizations.of(context);
    final time = _formatGuideRange(
      localizations,
      localize(program.startUtc),
      localize(program.endUtc),
      includeZone: includeZone,
    );
    final temporalStatus = program.endUtc.isAfter(nowUtc)
        ? (program.startUtc.isAfter(nowUtc)
              ? _GuideProgramTemporalStatus.upcoming
              : _GuideProgramTemporalStatus.current)
        : _GuideProgramTemporalStatus.past;
    return Positioned(
      left: layout.targetLeft,
      top: 5,
      width: layout.targetWidth,
      bottom: 5,
      child: _GuideProgramCell(
        key: ValueKey(
          'guide-program-${channel.id}-${program.startUtc.millisecondsSinceEpoch}-${program.endUtc.millisecondsSinceEpoch}',
        ),
        channelTitle: channel.title,
        program: program,
        timeLabel: time,
        temporalStatus: temporalStatus,
        focusNode:
            initialProgramStartUtcMs ==
                    program.startUtc.millisecondsSinceEpoch &&
                initialProgramEndUtcMs == program.endUtc.millisecondsSinceEpoch
            ? initialFocusNode
            : null,
        onMounted: (node) => onProgramNodeMounted(program, node),
        onUnmounted: (node) => onProgramNodeUnmounted(program, node),
        onFocused: (node) => onProgramFocused(program, node),
        onActivate: onProgramTune,
        onLeft: () => onProgramLeft(index),
        onRight: () => onProgramRight(index),
        onUp: () => onProgramUp(program),
        onDown: () => onProgramDown(program),
      ),
    );
  }

  double _xFor(DateTime instant) =>
      instant.toUtc().difference(windowStartUtc).inSeconds /
      Duration.secondsPerHour *
      hourWidth;
}

class _GuideChannelCell extends StatefulWidget {
  const _GuideChannelCell({
    required this.channel,
    required this.focusNode,
    required this.onMounted,
    required this.onUnmounted,
    required this.onFocused,
    required this.onActivate,
    required this.onLeft,
    required this.onRight,
    required this.onUp,
    required this.onDown,
  });

  final BrowseCatalogItem channel;
  final FocusNode? focusNode;
  final ValueChanged<FocusNode> onMounted;
  final ValueChanged<FocusNode> onUnmounted;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onActivate;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onUp;
  final VoidCallback onDown;

  @override
  State<_GuideChannelCell> createState() => _GuideChannelCellState();
}

class _GuideChannelCellState extends State<_GuideChannelCell> {
  late final FocusNode _owned = FocusNode(
    debugLabel: 'guide channel ${widget.channel.id}',
  );
  bool _focused = false;

  FocusNode get _node => widget.focusNode ?? _owned;

  @override
  void initState() {
    super.initState();
    widget.onMounted(_node);
  }

  @override
  void didUpdateWidget(covariant _GuideChannelCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel.id != widget.channel.id ||
        oldWidget.focusNode != widget.focusNode) {
      oldWidget.onUnmounted(oldWidget.focusNode ?? _owned);
      widget.onMounted(_node);
    }
  }

  @override
  void dispose() {
    widget.onUnmounted(_node);
    _owned.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _FocusableCell(
    key: ValueKey('guide-channel-${widget.channel.id}'),
    focusNode: _node,
    semanticLabel: '${widget.channel.title}, Live channel',
    focused: _focused,
    onFocusChange: (focused) {
      setState(() => _focused = focused);
      if (focused) widget.onFocused(_node);
    },
    onActivate: widget.onActivate,
    onLeft: widget.onLeft,
    onRight: widget.onRight,
    onUp: widget.onUp,
    onDown: widget.onDown,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Icon(Icons.live_tv_outlined, color: _quietText, size: 19),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.channel.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _warmWhite,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _GuideProgramLayout {
  const _GuideProgramLayout({
    required this.program,
    required this.visualLeft,
    required this.visualWidth,
    required this.targetLeft,
    required this.targetWidth,
  });

  final EpgProgram program;
  final double visualLeft;
  final double visualWidth;
  final double targetLeft;
  final double targetWidth;
}

enum _GuideProgramTemporalStatus { past, current, upcoming }

class _GuideProgramVisual extends StatelessWidget {
  const _GuideProgramVisual({
    super.key,
    required this.title,
    required this.timeLabel,
    required this.current,
    required this.focused,
    required this.onActivate,
  });

  final String title;
  final String timeLabel;
  final bool current;
  final bool focused;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    onTap: onActivate,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: current ? _raised : const Color(0xFF1D1E1D),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: focused ? _amber : Colors.transparent,
          width: focused ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _warmWhite,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              timeLabel,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: const TextStyle(color: _quietText, fontSize: 11),
            ),
          ],
        ),
      ),
    ),
  );
}

class _GuideProgramCell extends StatefulWidget {
  const _GuideProgramCell({
    super.key,
    required this.channelTitle,
    required this.program,
    required this.timeLabel,
    required this.temporalStatus,
    required this.focusNode,
    required this.onMounted,
    required this.onUnmounted,
    required this.onFocused,
    required this.onActivate,
    required this.onLeft,
    required this.onRight,
    required this.onUp,
    required this.onDown,
  });

  final String channelTitle;
  final EpgProgram program;
  final String timeLabel;
  final _GuideProgramTemporalStatus temporalStatus;
  final FocusNode? focusNode;
  final ValueChanged<FocusNode> onMounted;
  final ValueChanged<FocusNode> onUnmounted;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onActivate;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onUp;
  final VoidCallback onDown;

  @override
  State<_GuideProgramCell> createState() => _GuideProgramCellState();
}

class _GuideProgramCellState extends State<_GuideProgramCell> {
  late final FocusNode _node = FocusNode(debugLabel: 'guide program');
  bool _focused = false;

  FocusNode get _focusNode => widget.focusNode ?? _node;

  @override
  void initState() {
    super.initState();
    widget.onMounted(_focusNode);
  }

  @override
  void didUpdateWidget(covariant _GuideProgramCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.onUnmounted(oldWidget.focusNode ?? _node);
      widget.onMounted(_focusNode);
    }
  }

  @override
  void dispose() {
    widget.onUnmounted(_focusNode);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 3),
    child: _FocusableCell(
      focusNode: _focusNode,
      semanticLabel:
          '${widget.channelTitle}, ${widget.program.title}, ${widget.timeLabel}, ${widget.temporalStatus.name}',
      focused: _focused,
      preserveFillOnFocus: true,
      showFocusBorder: false,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onFocused(_focusNode);
      },
      onActivate: widget.onActivate,
      onLeft: widget.onLeft,
      onRight: widget.onRight,
      onUp: widget.onUp,
      onDown: widget.onDown,
      child: const SizedBox.expand(),
    ),
  );
}

class _FocusableCell extends StatelessWidget {
  const _FocusableCell({
    super.key,
    required this.focusNode,
    required this.semanticLabel,
    required this.focused,
    required this.onFocusChange,
    required this.onActivate,
    required this.onLeft,
    required this.onRight,
    required this.onUp,
    required this.onDown,
    required this.child,
    this.preserveFillOnFocus = false,
    this.showFocusBorder = true,
  });

  final FocusNode focusNode;
  final String semanticLabel;
  final bool focused;
  final ValueChanged<bool> onFocusChange;
  final VoidCallback onActivate;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final Widget child;
  final bool preserveFillOnFocus;
  final bool showFocusBorder;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focusNode,
    onFocusChange: onFocusChange,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowLeft:
          onLeft();
        case LogicalKeyboardKey.arrowRight:
          onRight();
        case LogicalKeyboardKey.arrowUp:
          onUp();
        case LogicalKeyboardKey.arrowDown:
          onDown();
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
          onActivate();
        default:
          return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    },
    child: Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          focusNode.requestFocus();
          onActivate();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: focused && !preserveFillOnFocus
                ? _raised
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: focused && showFocusBorder ? _amber : Colors.transparent,
              width: focused && showFocusBorder ? 2 : 1,
            ),
          ),
          child: child,
        ),
      ),
    ),
  );
}

class _TimeRuler extends StatelessWidget {
  const _TimeRuler({
    required this.startUtc,
    required this.nowUtc,
    required this.hourWidth,
    required this.localize,
    required this.includeZone,
  });

  final DateTime startUtc;
  final DateTime nowUtc;
  final double hourWidth;
  final GuideLocalInstant Function(DateTime utc) localize;
  final bool includeZone;

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    String labelFor(int index) {
      final instant = localize(startUtc.add(Duration(hours: index)));
      final time = _formatGuideCompactTime(
        localizations,
        instant,
        includeZone: includeZone,
      );
      if (index == 0) return time;
      final previous = localize(startUtc.add(Duration(hours: index - 1)))
          .wallTime;
      final current = instant.wallTime;
      final changedDay =
          previous.year != current.year ||
          previous.month != current.month ||
          previous.day != current.day;
      return changedDay
          ? '${localizations.formatShortDate(current)} $time'
          : time;
    }

    return Stack(
      children: [
        for (var index = 0; index <= _guideHours; index++)
          Positioned(
            left: index * hourWidth,
            top: 0,
            bottom: 0,
            child: Row(
              children: [
                Container(width: 1, color: _line),
                const SizedBox(width: 10),
                SizedBox(
                  width: math.max(0, hourWidth - 12),
                  child: Text(
                    labelFor(index),
                    key: ValueKey('guide-ruler-label-$index'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _quietText,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _GuideDropdown<T> extends StatelessWidget {
  const _GuideDropdown({
    super.key,
    required this.focusNode,
    required this.label,
    required this.value,
    required this.values,
    required this.labels,
    required this.onChanged,
    required this.onDown,
  });

  final FocusNode focusNode;
  final String label;
  final T? value;
  final List<T> values;
  final List<String> labels;
  final ValueChanged<T> onChanged;
  final VoidCallback onDown;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowDown &&
            !HardwareKeyboard.instance.isAltPressed) {
          onDown();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: DropdownButtonFormField<T>(
        focusNode: focusNode,
        key: ValueKey('guide-dropdown-$label'),
        initialValue: value,
        isExpanded: true,
        dropdownColor: _raised,
        iconEnabledColor: _quietText,
        style: const TextStyle(
          color: _warmWhite,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: _quietText, fontSize: 12),
          isDense: true,
          filled: true,
          fillColor: _surface,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: _line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: _amber, width: 2),
          ),
        ),
        items: [
          for (var index = 0; index < values.length; index++)
            DropdownMenuItem<T>(
              value: values[index],
              child: Text(
                labels[index],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
      ),
    ),
  );
}

class _GuideButton extends StatefulWidget {
  const _GuideButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.onDown,
    this.focusNode,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final VoidCallback onDown;
  final FocusNode? focusNode;

  @override
  State<_GuideButton> createState() => _GuideButtonState();
}

class _GuideButtonState extends State<_GuideButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    onFocusChange: (focused) => setState(() => _focused = focused),
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        widget.onDown();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.select) {
        widget.onPressed();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused ? _amber : _line,
              width: _focused ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 17, color: _quietText),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: const TextStyle(
                  color: _warmWhite,
                  fontSize: 14,
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

class _GuideMessage extends StatelessWidget {
  const _GuideMessage({
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.primaryAction,
    required this.secondaryLabel,
    required this.secondaryAction,
    required this.focusNode,
    required this.onFocused,
    required this.onLeft,
  });

  final String title;
  final String message;
  final String primaryLabel;
  final VoidCallback primaryAction;
  final String secondaryLabel;
  final VoidCallback secondaryAction;
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onLeft;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _graphite,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _warmWhite,
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _quietText,
                  fontSize: 15,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  _GuideMessageAction(
                    focusNode: focusNode,
                    label: primaryLabel,
                    primary: true,
                    onPressed: primaryAction,
                    onFocused: onFocused,
                    onLeft: onLeft,
                  ),
                  _GuideMessageAction(
                    label: secondaryLabel,
                    onPressed: secondaryAction,
                    onFocused: onFocused,
                    onLeft: onLeft,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _GuideMessageAction extends StatefulWidget {
  const _GuideMessageAction({
    required this.label,
    required this.onPressed,
    required this.onFocused,
    required this.onLeft,
    this.focusNode,
    this.primary = false,
  });

  final String label;
  final VoidCallback onPressed;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onLeft;
  final FocusNode? focusNode;
  final bool primary;

  @override
  State<_GuideMessageAction> createState() => _GuideMessageActionState();
}

class _GuideMessageActionState extends State<_GuideMessageAction> {
  late final FocusNode _owned = FocusNode(debugLabel: 'guide message action');
  bool _focused = false;
  FocusNode get _node => widget.focusNode ?? _owned;

  @override
  void dispose() {
    _owned.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _node,
    autofocus: widget.focusNode != null,
    onFocusChange: (focused) {
      setState(() => _focused = focused);
      if (focused) widget.onFocused(_node);
    },
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        widget.onLeft();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.select) {
        widget.onPressed();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: GestureDetector(
      onTap: widget.onPressed,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: widget.primary ? _amber : _surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: _focused
                ? _amber
                : widget.primary
                ? _amber
                : _line,
            width: _focused ? 2 : 1,
          ),
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            color: widget.primary ? const Color(0xFF17120A) : _warmWhite,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
  );
}

class _GuideSkeleton extends StatelessWidget {
  const _GuideSkeleton();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: _line),
    ),
    child: ListView.builder(
      itemExtent: _guideRowExtent,
      itemCount: 8,
      itemBuilder: (_, _) => const _GuideRowSkeleton(),
    ),
  );
}

class _GuideRowSkeleton extends StatelessWidget {
  const _GuideRowSkeleton();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    child: Row(
      children: [
        Container(width: 150, height: 16, color: _raised),
        const SizedBox(width: 28),
        Expanded(child: Container(height: 38, color: _raised)),
      ],
    ),
  );
}

class _GuideEmpty extends StatelessWidget {
  const _GuideEmpty({
    required this.focusNode,
    required this.onFocused,
    required this.onLeft,
    required this.onBrowseLive,
  });

  final FocusNode focusNode;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onLeft;
  final VoidCallback onBrowseLive;

  @override
  Widget build(BuildContext context) => Center(
    child: _GuideMessageAction(
      focusNode: focusNode,
      label: 'Browse Live',
      onPressed: onBrowseLive,
      onFocused: onFocused,
      onLeft: onLeft,
    ),
  );
}

String _formatGuideTime(
  MaterialLocalizations localizations,
  GuideLocalInstant instant, {
  required bool includeZone,
}) {
  final time = localizations.formatTimeOfDay(
    TimeOfDay.fromDateTime(instant.wallTime),
  );
  if (!includeZone) return time;
  final offset = _formatGuideUtcOffset(instant.utcOffset);
  final zone = instant.zoneName.trim();
  return '$time${zone.isEmpty ? '' : ' $zone'} $offset';
}

String _formatGuideCompactTime(
  MaterialLocalizations localizations,
  GuideLocalInstant instant, {
  required bool includeZone,
}) {
  final time = localizations.formatTimeOfDay(
    TimeOfDay.fromDateTime(instant.wallTime),
  );
  if (!includeZone) return time;
  final zone = _compactGuideZone(instant.zoneName);
  return '$time ${zone ?? _formatGuideUtcOffset(instant.utcOffset, compact: true)}';
}

String? _compactGuideZone(String zoneName) {
  final zone = zoneName.trim();
  if (zone.isEmpty) return null;
  if (RegExp(r'^[A-Z]{2,5}$').hasMatch(zone)) return zone;
  final words = zone
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  if (words.length >= 2) {
    final abbreviation = words.map((word) => word[0]).join().toUpperCase();
    if (abbreviation.length >= 2 && abbreviation.length <= 5) {
      return abbreviation;
    }
  }
  return null;
}

String _formatGuideUtcOffset(Duration offset, {bool compact = false}) {
  final totalMinutes = offset.inMinutes;
  final sign = totalMinutes < 0 ? '−' : '+';
  final absolute = totalMinutes.abs();
  final hours = (absolute ~/ 60).toString().padLeft(2, '0');
  final minutes = (absolute % 60).toString().padLeft(2, '0');
  if (compact && minutes == '00') return 'UTC$sign$hours';
  return 'UTC$sign$hours:$minutes';
}

String _formatGuideCompactRange(
  MaterialLocalizations localizations,
  GuideLocalInstant start,
  GuideLocalInstant end, {
  required bool includeZone,
}) {
  final startTime = _formatGuideCompactTime(
    localizations,
    start,
    includeZone: includeZone,
  );
  final endTime = _formatGuideCompactTime(
    localizations,
    end,
    includeZone: includeZone,
  );
  final crossesDay =
      start.wallTime.year != end.wallTime.year ||
      start.wallTime.month != end.wallTime.month ||
      start.wallTime.day != end.wallTime.day;
  if (!crossesDay) return '$startTime–$endTime';
  return '${localizations.formatShortDate(start.wallTime)} $startTime–${localizations.formatShortDate(end.wallTime)} $endTime';
}

String _formatGuideRange(
  MaterialLocalizations localizations,
  GuideLocalInstant start,
  GuideLocalInstant end, {
  required bool includeZone,
}) {
  final startTime = _formatGuideTime(
    localizations,
    start,
    includeZone: includeZone,
  );
  final endTime = _formatGuideTime(
    localizations,
    end,
    includeZone: includeZone,
  );
  final crossesDay =
      start.wallTime.year != end.wallTime.year ||
      start.wallTime.month != end.wallTime.month ||
      start.wallTime.day != end.wallTime.day;
  if (!crossesDay) return '$startTime–$endTime';
  return '${localizations.formatShortDate(start.wallTime)} $startTime–${localizations.formatShortDate(end.wallTime)} $endTime';
}

String _programKey(String channelId, int startUtcMs, int endUtcMs) =>
    '$channelId:$startUtcMs:$endUtcMs';

bool _sameCategory(BrowseCategorySelection a, BrowseCategorySelection b) =>
    a.kind == b.kind && a.sourceGroupId == b.sourceGroupId;

bool _sameStringList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
