import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show FrameCallback;
import 'package:flutter/services.dart';

import '../../cinema.dart';
import '../artwork/artwork_loader.dart';
import '../browse/minimal_continuations.dart';
import '../browse/playback_handoff.dart';
import '../browse/series_info_loader.dart';
import '../sources/credential_store.dart';
import '../sources/source_catalog_database.dart';
import '../sources/source_models.dart';

// THESIS: My Library is a calm read-only index of saved viewing intent.
// OWN-WORLD: Quiet Broadcast; approved composition A is the sole visual seed.
// STORY: choose Favorites or a custom group, then open its dense mixed ledger.
// FIRST VIEWPORT: 270 px directory, one divider, dominant 64 px-row ledger.
// FORM: matte graphite, Segoe UI hierarchy, 6 px forms, 1 px lines, and one
// precise 2 px amber focus edge; no mutation controls or storefront furniture.

const _graphite = Cinema.ink;
const _surface = Color(0xFF141419);
const _raised = Color(0xFF1E1E23);
const _warmWhite = Cinema.text;
const _quietText = Cinema.faint;
const _amber = Cinema.amber;

/// A read-only section in the user's saved library.
enum MyLibrarySectionKind { favorites, customGroup }

/// The media identity needed to hand a saved row back to the app shell.
enum MyLibraryMediaKind {
  live('Channel'),
  movie('Movie'),
  series('Series');

  const MyLibraryMediaKind(this.label);
  final String label;
}

/// Why a saved item cannot currently be opened.
enum MyLibraryItemAvailability { available, itemUnavailable, sourceUnavailable }

class MyLibrarySection {
  const MyLibrarySection({
    required this.id,
    required this.name,
    required this.kind,
    required this.itemCount,
    this.directoryOrdinal,
    this.homeOrdinal,
  });

  final String id;
  final String name;
  final MyLibrarySectionKind kind;
  final int itemCount;
  final int? directoryOrdinal;
  final int? homeOrdinal;

  bool get isPinned => homeOrdinal != null;
}

/// Credential-free presentation identity for one saved item.
///
/// [artworkKey] is deliberately opaque. The screen never interprets it or
/// starts a network request; the app-owned artwork seam may resolve it.
class MyLibraryItem {
  const MyLibraryItem({
    required this.id,
    required this.title,
    required this.kind,
    required this.sourceName,
    this.artworkKey,
    this.availability = MyLibraryItemAvailability.available,
  });

  final String id;
  final String title;
  final MyLibraryMediaKind kind;
  final String? sourceName;
  final String? artworkKey;
  final MyLibraryItemAvailability availability;

  bool get isAvailable => availability == MyLibraryItemAvailability.available;

  String get sourceLabel => sourceName == null || sourceName!.trim().isEmpty
      ? 'Unknown source'
      : sourceName!;
}

/// Opaque keyset position. It is not a numeric offset and contains no source
/// credentials.
class MyLibraryPageCursor {
  const MyLibraryPageCursor(this.value);
  final Object value;

  @override
  bool operator ==(Object other) =>
      other is MyLibraryPageCursor && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

class MyLibraryPage {
  const MyLibraryPage({
    required this.items,
    required this.nextCursor,
    this.totalCount,
  });

  final List<MyLibraryItem> items;
  final MyLibraryPageCursor? nextCursor;
  final int? totalCount;
}

/// The only local-data work required by the Phase 3 My Library surface.
abstract interface class MyLibraryData {
  Future<List<MyLibrarySection>> loadSections({int limit = 100});

  Future<MyLibraryPage> loadItems({
    required String sectionId,
    MyLibraryPageCursor? cursor,
    int limit = 100,
  });

  /// Resolves the currently playable exact source variant locally.
  Future<LibraryCatalogItem?> resolvePlayableItem(String libraryItemId);

  /// Resolves only the exact source selected by [resolvePlayableItem].
  Future<PersistedSource?> loadReadySourceById(String sourceId);
}

typedef MyLibraryItemActivated = void Function(MyLibraryItem item);
typedef MyLibraryArtworkBuilder = Widget Function(
  BuildContext context,
  MyLibraryItem item,
  bool deliberatelyFocused,
);

/// Practical in-memory return state owned by the app shell.
///
/// It intentionally stores only bounded pages already loaded by this screen.
class MyLibrarySession {
  bool hasSnapshot = false;
  String? selectedSectionId;
  String? focusedSectionId;
  String? focusedItemId;
  bool directoryWasOpen = false;
  double directoryScrollOffset = 0;
  double itemScrollOffset = 0;
  List<MyLibrarySection> sections = const [];
  List<MyLibraryItem> items = const [];
  MyLibraryPageCursor? nextCursor;
  int? totalCount;
}

/// Favorites/custom-groups directory and mixed-item ledger.
///
/// Phase 4 management stays behind two explicit secondary callbacks so the
/// dense ledger remains the primary viewing surface.
class MyLibraryScreen extends StatefulWidget {
  const MyLibraryScreen({
    super.key,
    required this.data,
    required this.initialFocus,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.session,
    this.organizationRevision = 0,
    this.onItemActivated,
    this.onPlaybackHandoff,
    this.onOrganizeItem,
    this.onCreateGroup,
    this.onManageGroup,
    this.credentialStore,
    this.seriesInfoLoader,
    this.continuationArtworkLoader,
    this.artworkBuilder,
  });

  final MyLibraryData data;
  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final MyLibrarySession session;
  final int organizationRevision;
  final MyLibraryItemActivated? onItemActivated;
  final ValueChanged<PlaybackHandoff>? onPlaybackHandoff;
  final ValueChanged<MyLibraryItem>? onOrganizeItem;
  final VoidCallback? onCreateGroup;
  final ValueChanged<MyLibrarySection>? onManageGroup;
  final CredentialStore? credentialStore;
  final SeriesInfoLoader? seriesInfoLoader;
  final ArtworkProvider? continuationArtworkLoader;
  final MyLibraryArtworkBuilder? artworkBuilder;

  @override
  State<MyLibraryScreen> createState() => _MyLibraryScreenState();
}

class _MyLibraryScreenState extends State<MyLibraryScreen> {
  static const _pageSize = 100;
  static const _directoryLimit = 200;
  double get _textScale =>
      MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
  double get _directoryRowExtent => 44 + (_textScale - 1) * 16;
  double get _itemRowExtent => 68 + (_textScale - 1) * 28;

  final ScrollController _directoryScroll = ScrollController();
  final ScrollController _itemScroll = ScrollController();
  final FocusNode _launcherFocus = FocusNode(
    debugLabel: 'my library directory launcher',
  );
  final FocusNode _retryFocus = FocusNode(debugLabel: 'my library retry');
  final FocusNode _pageRetryFocus = FocusNode(
    debugLabel: 'my library next page retry',
  );
  final FocusNode _emptySectionFocus = FocusNode(
    debugLabel: 'my library empty section',
  );
  final FocusNode _createGroupFocus = FocusNode(
    debugLabel: 'my library create group',
  );
  final FocusNode _manageGroupFocus = FocusNode(
    debugLabel: 'my library manage group',
  );
  final Map<String, FocusNode> _mountedSectionNodes = {};
  final Map<String, FocusNode> _mountedItemNodes = {};

  List<MyLibrarySection> _sections = const [];
  List<MyLibraryItem> _items = const [];
  MyLibrarySection? _selected;
  MyLibraryPageCursor? _nextCursor;
  int? _totalCount;
  bool _loadingDirectory = true;
  bool _loadingItems = false;
  bool _loadingMore = false;
  bool _initialDirectoryFailure = false;
  bool _itemFailure = false;
  bool _pageFailure = false;
  bool _directoryOpen = false;
  bool _isNarrow = false;
  String? _recoveryMessage;
  String? _pendingSectionId;
  MyLibrarySection? _failedSection;
  int _directoryRequest = 0;
  int _itemRequest = 0;
  int _activationRequest = 0;
  int _seriesRequest = 0;
  _LibraryContinuation? _continuation;
  late final SeriesInfoLoader _seriesInfoLoader;

  @override
  void initState() {
    super.initState();
    _seriesInfoLoader =
        widget.seriesInfoLoader ??
        XtreamSeriesInfoLoader(credentialStore: widget.credentialStore);
    _restoreSessionSnapshot();
    _directoryScroll.addListener(_rememberPosition);
    _itemScroll
      ..addListener(_rememberPosition)
      ..addListener(_loadMoreIfNeeded);
    unawaited(_loadDirectory());
  }

  @override
  void didUpdateWidget(covariant MyLibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data ||
        oldWidget.organizationRevision != widget.organizationRevision) {
      ++_activationRequest;
      unawaited(_loadDirectory(forceItemRefresh: true));
    }
  }

  @override
  void dispose() {
    _rememberPosition();
    _cacheSession();
    ++_directoryRequest;
    ++_itemRequest;
    ++_activationRequest;
    _cancelSeriesRequest();
    _directoryScroll
      ..removeListener(_rememberPosition)
      ..dispose();
    _itemScroll
      ..removeListener(_rememberPosition)
      ..removeListener(_loadMoreIfNeeded)
      ..dispose();
    _launcherFocus.dispose();
    _retryFocus.dispose();
    _pageRetryFocus.dispose();
    _emptySectionFocus.dispose();
    _createGroupFocus.dispose();
    _manageGroupFocus.dispose();
    super.dispose();
  }

  void _restoreSessionSnapshot() {
    if (!widget.session.hasSnapshot) return;
    _sections = widget.session.sections;
    _selected = _sectionById(widget.session.selectedSectionId, _sections);
    _items = widget.session.items;
    _nextCursor = widget.session.nextCursor;
    _totalCount = widget.session.totalCount;
    _directoryOpen = widget.session.directoryWasOpen;
    _loadingDirectory = false;
  }

  MyLibrarySection? _sectionById(String? id, List<MyLibrarySection> sections) {
    if (id == null) return null;
    for (final section in sections) {
      if (section.id == id) return section;
    }
    return null;
  }

  Future<void> _loadDirectory({bool forceItemRefresh = false}) async {
    final request = ++_directoryRequest;
    ++_itemRequest;
    final restoreFocusedItemId = widget.session.focusedItemId;
    final restoreFocusedSectionId = widget.session.focusedSectionId;
    final hadUsableSnapshot =
        widget.session.hasSnapshot || _sections.isNotEmpty;
    setState(() {
      _loadingDirectory = !hadUsableSnapshot;
      _loadingItems = false;
      _loadingMore = false;
      _initialDirectoryFailure = false;
      if (!hadUsableSnapshot) _recoveryMessage = null;
    });
    try {
      final sections = await widget.data.loadSections(limit: _directoryLimit);
      if (!mounted || request != _directoryRequest) return;

      if (sections.isEmpty) {
        ++_itemRequest;
        setState(() {
          _sections = const [];
          _selected = null;
          _items = const [];
          _nextCursor = null;
          _totalCount = 0;
          _loadingDirectory = false;
          _loadingItems = false;
          _itemFailure = false;
          _pageFailure = false;
          _recoveryMessage = null;
          _pendingSectionId = null;
          _failedSection = null;
        });
        _cacheSession();
        _focusEntryTarget();
        return;
      }

      final preferredId = _selected?.id ?? widget.session.selectedSectionId;
      final target = _sectionById(preferredId, sections) ?? sections.first;
      final canKeepItems =
          !forceItemRefresh &&
          _selected?.id == target.id &&
          widget.session.hasSnapshot;
      if (canKeepItems) {
        setState(() {
          _sections = sections;
          _selected = target;
          _loadingDirectory = false;
          _initialDirectoryFailure = false;
          _recoveryMessage = null;
          _failedSection = null;
        });
        _cacheSession();
        _restorePositionAndFocus(
          focusedItemId: restoreFocusedItemId,
          focusedSectionId: restoreFocusedSectionId,
        );
        return;
      }

      setState(() {
        _sections = sections;
        _selected = target;
        _loadingDirectory = false;
      });
      await _loadSection(
        target,
        restore: hadUsableSnapshot,
        restoreFocusedItemId: restoreFocusedItemId,
        restoreFocusedSectionId: restoreFocusedSectionId,
      );
    } catch (_) {
      if (!mounted || request != _directoryRequest) return;
      setState(() {
        _loadingDirectory = false;
        if (hadUsableSnapshot) {
          _failedSection = null;
          _recoveryMessage = "Couldn't refresh My Library.";
        } else {
          _initialDirectoryFailure = true;
        }
      });
      _afterNextFrame((_) {
        if (!mounted || request != _directoryRequest) return;
        if (_initialDirectoryFailure) _retryFocus.requestFocus();
      });
    }
  }

  Future<bool> _loadSection(
    MyLibrarySection section, {
    bool restore = false,
    bool preserveCurrentOnFailure = false,
    String? restoreFocusedItemId,
    String? restoreFocusedSectionId,
  }) async {
    final request = ++_itemRequest;
    final previousSection = _selected;
    final previousItems = _items;
    final previousCursor = _nextCursor;
    final previousTotal = _totalCount;
    setState(() {
      _loadingItems = true;
      _loadingMore = false;
      _itemFailure = false;
      _pageFailure = false;
      _pendingSectionId = section.id;
      _recoveryMessage = null;
      _failedSection = null;
      if (!preserveCurrentOnFailure) {
        _selected = section;
        _items = const [];
        _nextCursor = null;
        _totalCount = section.itemCount;
      }
    });
    try {
      final page = await widget.data.loadItems(
        sectionId: section.id,
        limit: _pageSize,
      );
      if (!mounted || request != _itemRequest) return false;
      setState(() {
        _selected = section;
        _items = page.items;
        _nextCursor = page.nextCursor;
        _totalCount = page.totalCount ?? section.itemCount;
        _loadingItems = false;
        _itemFailure = false;
        _pageFailure = false;
        _pendingSectionId = null;
        _failedSection = null;
        if (_directoryOpen && _isNarrow) _directoryOpen = false;
      });
      if (!restore && _itemScroll.hasClients) _itemScroll.jumpTo(0);
      if (!restore) {
        widget.session
          ..focusedItemId = null
          ..itemScrollOffset = 0;
      }
      _cacheSession();
      if (restore) {
        _restorePositionAndFocus(
          focusedItemId: restoreFocusedItemId,
          focusedSectionId: restoreFocusedSectionId,
        );
      }
      return true;
    } catch (_) {
      if (!mounted || request != _itemRequest) return false;
      setState(() {
        _loadingItems = false;
        _pendingSectionId = null;
        if (preserveCurrentOnFailure) {
          _selected = previousSection;
          _items = previousItems;
          _nextCursor = previousCursor;
          _totalCount = previousTotal;
          _failedSection = section;
          _recoveryMessage = "Couldn't open that group.";
        } else {
          _selected = section;
          _itemFailure = true;
        }
      });
      if (preserveCurrentOnFailure) _cacheSession();
      return false;
    }
  }

  Future<void> _selectSection(MyLibrarySection section) async {
    if (_pendingSectionId == section.id) return;
    if (_selected?.id == section.id && !_itemFailure) {
      if (_directoryOpen && _isNarrow) {
        setState(() => _directoryOpen = false);
        _focusFirstLedgerTarget();
      }
      return;
    }
    await _loadSection(
      section,
      preserveCurrentOnFailure: _selected != null && !_itemFailure,
    );
  }

  Future<void> _retryRecovery() async {
    final failedSection = _failedSection;
    if (failedSection != null) {
      final succeeded = await _loadSection(
        failedSection,
        preserveCurrentOnFailure: true,
      );
      if (mounted && succeeded) _focusFirstLedgerTarget();
      return;
    }
    await _loadDirectory();
  }

  Future<bool> _retrySelectedSection() async {
    final section = _selected;
    if (section == null) return false;
    final succeeded = await _loadSection(section);
    if (mounted && succeeded) _focusFirstLedgerTarget();
    return succeeded;
  }

  Future<void> _loadMore({bool focusFirstNew = false}) async {
    final cursor = _nextCursor;
    final section = _selected;
    if (cursor == null || section == null || _loadingMore || _loadingItems) {
      return;
    }
    final request = ++_itemRequest;
    final firstNewIndex = _items.length;
    setState(() {
      _loadingMore = true;
      _pageFailure = false;
    });
    try {
      final page = await widget.data.loadItems(
        sectionId: section.id,
        cursor: cursor,
        limit: _pageSize,
      );
      if (!mounted || request != _itemRequest || _selected?.id != section.id) {
        return;
      }
      setState(() {
        _items = [..._items, ...page.items];
        _nextCursor = page.nextCursor;
        _totalCount = page.totalCount ?? _totalCount;
        _loadingMore = false;
      });
      _cacheSession();
      if (focusFirstNew && page.items.isNotEmpty) {
        _requestItemFocusAt(firstNewIndex);
      }
    } catch (_) {
      if (!mounted || request != _itemRequest || _selected?.id != section.id) {
        return;
      }
      setState(() {
        _loadingMore = false;
        _pageFailure = true;
      });
      if (focusFirstNew) _pageRetryFocus.requestFocus();
    }
  }

  void _loadMoreIfNeeded() {
    _rememberPosition();
    if (!_itemScroll.hasClients ||
        _nextCursor == null ||
        _loadingItems ||
        _loadingMore ||
        _pageFailure) {
      return;
    }
    if (_itemScroll.position.extentAfter < 240) unawaited(_loadMore());
  }

  void _rememberPosition() {
    if (_directoryScroll.hasClients) {
      widget.session.directoryScrollOffset = _directoryScroll.offset;
    }
    if (_itemScroll.hasClients) {
      widget.session.itemScrollOffset = _itemScroll.offset;
    }
  }

  void _cacheSession() {
    widget.session
      ..hasSnapshot = true
      ..selectedSectionId = _selected?.id
      ..directoryWasOpen = _directoryOpen
      ..sections = _sections
      ..items = _items
      ..nextCursor = _nextCursor
      ..totalCount = _totalCount;
    _rememberPosition();
  }

  void _restorePositionAndFocus({
    String? focusedItemId,
    String? focusedSectionId,
  }) {
    _afterNextFrame((_) {
      if (!mounted) return;
      if (_directoryScroll.hasClients) {
        _directoryScroll.jumpTo(
          widget.session.directoryScrollOffset.clamp(
            0,
            _directoryScroll.position.maxScrollExtent,
          ),
        );
      }
      if (_itemScroll.hasClients) {
        _itemScroll.jumpTo(
          widget.session.itemScrollOffset.clamp(
            0,
            _itemScroll.position.maxScrollExtent,
          ),
        );
      }
      _afterNextFrame((_) {
        if (!mounted) return;
        final focusedItem = focusedItemId ?? widget.session.focusedItemId;
        final itemIndex = _items.indexWhere((item) => item.id == focusedItem);
        if (itemIndex >= 0) {
          _requestItemFocusAt(itemIndex);
          return;
        }
        final focusedSection =
            focusedSectionId ??
            widget.session.focusedSectionId ??
            _selected?.id;
        final sectionIndex = _sections.indexWhere(
          (section) => section.id == focusedSection,
        );
        if (sectionIndex >= 0) {
          if (_isNarrow) {
            _launcherFocus.requestFocus();
          } else {
            _requestSectionFocusAt(sectionIndex);
          }
          return;
        }
        _focusEntryTarget();
      });
    });
  }

  void _focusEntryTarget() {
    _afterNextFrame((_) {
      if (!mounted) return;
      if (_initialDirectoryFailure) {
        _retryFocus.requestFocus();
      } else if (_sections.isEmpty) {
        widget.initialFocus.requestFocus();
      } else {
        final focusedItem = widget.session.focusedItemId;
        final itemIndex = _items.indexWhere((item) => item.id == focusedItem);
        if (itemIndex >= 0) {
          _requestItemFocusAt(itemIndex);
          return;
        }
        if (_isNarrow) {
          _launcherFocus.requestFocus();
          return;
        }
        final preferredSectionId =
            widget.session.focusedSectionId ?? _selected?.id;
        final index = _sections.indexWhere(
          (section) => section.id == preferredSectionId,
        );
        _requestSectionFocusAt(index < 0 ? 0 : index);
      }
    });
  }

  void _focusedSection(MyLibrarySection section, FocusNode node) {
    widget.session
      ..focusedSectionId = section.id
      ..focusedItemId = null;
    widget.onContentFocus(node);
  }

  void _focusedItem(MyLibraryItem item, FocusNode node) {
    widget.session
      ..focusedItemId = item.id
      ..focusedSectionId = null;
    widget.onContentFocus(node);
  }

  void _focusedOwned(FocusNode node) => widget.onContentFocus(node);

  void _mountSectionNode(String id, FocusNode node) =>
      _mountedSectionNodes[id] = node;

  void _unmountSectionNode(String id, FocusNode node) {
    if (identical(_mountedSectionNodes[id], node)) {
      _mountedSectionNodes.remove(id);
    }
  }

  void _mountItemNode(String id, FocusNode node) =>
      _mountedItemNodes[id] = node;

  void _unmountItemNode(String id, FocusNode node) {
    if (identical(_mountedItemNodes[id], node)) {
      _mountedItemNodes.remove(id);
    }
  }

  /// Scrolls row [index] into view, centered, only when it is not already
  /// fully visible, so moving between visible rows never shifts the list.
  void _reveal(ScrollController controller, int index, double extent) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final start = index * extent;
    final top = controller.offset;
    if (start >= top && start + extent <= top + position.viewportDimension) {
      return;
    }
    controller.jumpTo(
      (start - (position.viewportDimension - extent) / 2).clamp(
        0,
        position.maxScrollExtent,
      ),
    );
  }

  void _requestSectionFocusAt(int index) {
    if (index < 0 || index >= _sections.length) return;
    final section = _sections[index];
    _reveal(_directoryScroll, index, _directoryRowExtent);
    final mountedNode = _mountedSectionNodes[section.id];
    if (mountedNode != null) {
      mountedNode.requestFocus();
      return;
    }
    _afterNextFrame((_) {
      if (mounted) _mountedSectionNodes[section.id]?.requestFocus();
    });
  }

  void _requestItemFocusAt(int index) {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    _reveal(_itemScroll, index, _itemRowExtent);
    final mountedNode = _mountedItemNodes[item.id];
    if (mountedNode != null) {
      mountedNode.requestFocus();
      return;
    }
    _afterNextFrame((_) {
      if (mounted) _mountedItemNodes[item.id]?.requestFocus();
    });
  }

  void _moveSection(int index, int amount) {
    final target = (index + amount).clamp(0, _sections.length - 1);
    if (target != index) _requestSectionFocusAt(target);
  }

  void _moveItem(int index, int amount) {
    if (amount > 0 && index == _items.length - 1 && _nextCursor != null) {
      unawaited(_loadMore(focusFirstNew: true));
      return;
    }
    final target = (index + amount).clamp(0, _items.length - 1);
    if (target != index) _requestItemFocusAt(target);
  }

  void _focusSelectedSection() {
    if (_isNarrow) {
      _openDirectory();
      return;
    }
    final index = _sections.indexWhere(
      (section) => section.id == _selected?.id,
    );
    _requestSectionFocusAt(index < 0 ? 0 : index);
  }

  /// Runs [callback] after the next frame and makes sure that frame comes.
  /// A key press alone schedules none, so a focus move would otherwise wait
  /// for some unrelated repaint.
  void _afterNextFrame(FrameCallback callback) {
    WidgetsBinding.instance
      ..addPostFrameCallback(callback)
      ..ensureVisualUpdate();
  }

  void _focusFirstLedgerTarget() {
    _afterNextFrame((_) {
      if (!mounted) return;
      if (_itemFailure) {
        _retryFocus.requestFocus();
      } else if (_items.isNotEmpty) {
        _requestItemFocusAt(0);
      } else {
        _emptySectionFocus.requestFocus();
      }
    });
  }

  void _openDirectory() {
    if (!_directoryOpen) setState(() => _directoryOpen = true);
    widget.session.directoryWasOpen = true;
    _afterNextFrame((_) {
      if (!mounted) return;
      final index = _sections.indexWhere(
        (section) => section.id == _selected?.id,
      );
      _requestSectionFocusAt(index < 0 ? 0 : index);
    });
  }

  void _closeDirectory() {
    if (!_directoryOpen) return;
    setState(() => _directoryOpen = false);
    widget.session.directoryWasOpen = false;
    _launcherFocus.requestFocus();
  }

  void _toggleDirectory() =>
      _directoryOpen ? _closeDirectory() : _openDirectory();

  void _back() {
    if (_directoryOpen) {
      _closeDirectory();
      return;
    }
    final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
    if (label == _retryFocus.debugLabel && _selected == null) {
      widget.onOpenRail();
      return;
    }
    if (label.startsWith('my library item ') ||
        label == _emptySectionFocus.debugLabel ||
        label == _retryFocus.debugLabel ||
        label == _pageRetryFocus.debugLabel) {
      _focusSelectedSection();
      return;
    }
    widget.onOpenRail();
  }

  Future<void> _activateItem(MyLibraryItem item) async {
    if (!item.isAvailable) {
      _announceUnavailable(item);
      return;
    }
    final request = ++_activationRequest;
    LibraryCatalogItem? exactItem;
    try {
      exactItem = await widget.data.resolvePlayableItem(item.id);
    } catch (_) {
      exactItem = null;
    }
    if (!mounted || request != _activationRequest) return;
    if (exactItem == null || !_resolvedItemMatches(item, exactItem)) {
      setState(
        () => _continuation = _FailureLibraryContinuation(
          item,
          ContinuationFailure.invalidReference,
        ),
      );
      return;
    }
    widget.onItemActivated?.call(item);
    // The direct callback is a notification/test seam. Production supplies a
    // playback handoff callback, which keeps Movie/Series behind continuations.
    if (widget.onPlaybackHandoff == null) return;
    switch (exactItem.kind) {
      case SourceMediaKind.live:
        _activateLive(item, exactItem);
      case SourceMediaKind.movies:
        _openMovie(item, exactItem);
      case SourceMediaKind.series:
        _openSeries(item, exactItem);
    }
  }

  bool _resolvedItemMatches(
    MyLibraryItem presentation,
    LibraryCatalogItem exact,
  ) =>
      presentation.id == exact.libraryItemId &&
      switch ((presentation.kind, exact.kind)) {
        (MyLibraryMediaKind.live, SourceMediaKind.live) => true,
        (MyLibraryMediaKind.movie, SourceMediaKind.movies) => true,
        (MyLibraryMediaKind.series, SourceMediaKind.series) => true,
        _ => false,
      };

  void _announceUnavailable(MyLibraryItem item) {
    final message = switch (item.availability) {
      MyLibraryItemAvailability.sourceUnavailable =>
        '${item.title}: source unavailable.',
      MyLibraryItemAvailability.itemUnavailable =>
        "${item.title} isn't available anymore.",
      MyLibraryItemAvailability.available => '',
    };
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  BrowseCatalogItem _browseItem(LibraryCatalogItem item) => BrowseCatalogItem(
    id: item.catalogItemId,
    sourceId: item.sourceId,
    kind: item.kind,
    title: item.title,
    artworkLocator: item.artworkLocator,
    playbackRef: item.playbackRef,
  );

  void _activateLive(MyLibraryItem presentation, LibraryCatalogItem exact) {
    try {
      widget.onPlaybackHandoff?.call(playbackHandoffForLibrary(exact));
    } on ContinuationException catch (error) {
      setState(
        () => _continuation = _FailureLibraryContinuation(
          presentation,
          error.failure,
        ),
      );
    }
  }

  void _openMovie(MyLibraryItem presentation, LibraryCatalogItem exact) {
    try {
      final handoff = playbackHandoffForLibrary(exact);
      if (handoff is! MoviePlaybackHandoff) {
        throw const ContinuationException(ContinuationFailure.invalidReference);
      }
      setState(
        () => _continuation = _MovieLibraryContinuation(
          presentation,
          exact,
          handoff,
        ),
      );
    } on ContinuationException catch (error) {
      setState(
        () => _continuation = _FailureLibraryContinuation(
          presentation,
          error.failure,
        ),
      );
    }
  }

  void _openSeries(MyLibraryItem presentation, LibraryCatalogItem exact) {
    _cancelSeriesRequest();
    try {
      seriesReferenceForLibrary(exact);
    } on ContinuationException catch (error) {
      setState(
        () => _continuation = _FailureLibraryContinuation(
          presentation,
          error.failure,
        ),
      );
      return;
    }
    unawaited(_loadSeries(presentation, exact));
  }

  Future<void> _loadSeries(
    MyLibraryItem presentation,
    LibraryCatalogItem exact,
  ) async {
    final request = ++_seriesRequest;
    setState(
      () => _continuation = _SeriesLibraryContinuation(
        presentation,
        exact,
        loading: true,
      ),
    );
    try {
      final source = await widget.data.loadReadySourceById(exact.sourceId);
      if (source == null) {
        throw const ContinuationException(
          ContinuationFailure.credentialsUnavailable,
        );
      }
      final info = await _seriesInfoLoader.load(
        source: source,
        series: _browseItem(exact),
      );
      if (!mounted || request != _seriesRequest) return;
      setState(
        () => _continuation = _SeriesLibraryContinuation(
          presentation,
          exact,
          loading: false,
          info: info,
        ),
      );
    } on ContinuationException catch (error) {
      if (!mounted || request != _seriesRequest) return;
      setState(
        () => _continuation = _SeriesLibraryContinuation(
          presentation,
          exact,
          loading: false,
          failure: error.failure,
        ),
      );
    } catch (_) {
      if (!mounted || request != _seriesRequest) return;
      setState(
        () => _continuation = _SeriesLibraryContinuation(
          presentation,
          exact,
          loading: false,
          failure: ContinuationFailure.unavailable,
        ),
      );
    }
  }

  void _cancelSeriesRequest() {
    ++_seriesRequest;
    _seriesInfoLoader.cancel();
  }

  void _returnToLibrary() {
    ++_activationRequest;
    _cancelSeriesRequest();
    setState(() => _continuation = null);
    _restorePositionAndFocus();
  }

  @override
  Widget build(BuildContext context) {
    final continuation = _continuation;
    if (continuation != null) return _buildContinuation(continuation);
    return _buildLibrary();
  }

  Widget _buildLibrary() => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): _back,
      const SingleActivator(LogicalKeyboardKey.browserBack): _back,
    },
    child: Focus(
      focusNode: widget.initialFocus,
      autofocus: true,
      onKeyEvent: (_, event) {
        if (widget.initialFocus.hasPrimaryFocus &&
            event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          widget.onOpenRail();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      onFocusChange: (_) {
        if (widget.initialFocus.hasPrimaryFocus) _focusEntryTarget();
      },
      child: ColoredBox(
        color: _graphite,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 780;
            _isNarrow = narrow;
            final horizontal = narrow ? 24.0 : 32.0;
            return SafeArea(
              left: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(horizontal, 22, horizontal, 28),
                child: _loadingDirectory
                    ? const _LibrarySkeleton()
                    : _initialDirectoryFailure
                    ? _InitialFailure(
                        focusNode: _retryFocus,
                        onFocused: _focusedOwned,
                        onLeft: widget.onOpenRail,
                        onRetry: _loadDirectory,
                      )
                    : _sections.isEmpty
                    ? const _EmptyLibrary()
                    : narrow
                    ? _buildNarrow()
                    : _buildWide(),
              ),
            );
          },
        ),
      ),
    ),
  );

  Widget _buildContinuation(_LibraryContinuation continuation) =>
      switch (continuation) {
        _MovieLibraryContinuation(
          :final presentation,
          :final exact,
          :final handoff,
        ) =>
          MovieContinuation(
            title: exact.title,
            artworkLocator: exact.artworkLocator,
            artworkLoader: widget.continuationArtworkLoader,
            onOrganize: widget.onOrganizeItem == null
                ? null
                : () => widget.onOrganizeItem!(presentation),
            onBack: _returnToLibrary,
            onPlay: () => widget.onPlaybackHandoff?.call(handoff),
          ),
        _SeriesLibraryContinuation(
          :final presentation,
          :final exact,
          :final loading,
          :final info,
          :final failure,
        ) =>
          SeriesContinuation(
            title: exact.title,
            artworkLocator: exact.artworkLocator,
            artworkLoader: widget.continuationArtworkLoader,
            onOrganize: widget.onOrganizeItem == null
                ? null
                : () => widget.onOrganizeItem!(presentation),
            loading: loading,
            info: info,
            failure: failure,
            onBack: _returnToLibrary,
            onRetry: () => _openSeries(presentation, exact),
            onEpisodeActivated: (episode) {
              widget.onPlaybackHandoff?.call(
                EpisodePlaybackHandoff(
                  sourceId: exact.sourceId,
                  title: episode.title,
                  providerItemId: episode.providerItemId,
                  extension: episode.extension,
                  libraryItemId: exact.libraryItemId,
                ),
              );
            },
          ),
        _FailureLibraryContinuation(:final presentation, :final failure) =>
          ContinuationFailureView(
            title: presentation.title,
            failure: failure,
            onBack: _returnToLibrary,
            onRetry: () => unawaited(_activateItem(presentation)),
          ),
      };

  Widget _buildWide() => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(width: 220, child: _buildDirectory(includeHeader: true)),
      const SizedBox(width: 24),
      Expanded(child: _buildLedger()),
    ],
  );

  Widget _buildNarrow() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _PageHeading(),
      const SizedBox(height: 18),
      _DirectoryLauncher(
        focusNode: _launcherFocus,
        selected: _selected!,
        open: _directoryOpen,
        onFocused: _focusedOwned,
        onPressed: _toggleDirectory,
        onLeft: widget.onOpenRail,
        onDown: _focusFirstLedgerTarget,
      ),
      const SizedBox(height: 20),
      Expanded(
        child: Stack(
          children: [
            Positioned.fill(child: _buildLedger()),
            if (_directoryOpen)
              Positioned.fill(
                child: DecoratedBox(
                  key: const ValueKey('my-library-directory-overlay'),
                  decoration: const BoxDecoration(color: _graphite),
                  child: _buildDirectory(includeHeader: false),
                ),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _buildDirectory({required bool includeHeader}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (includeHeader) ...[const _PageHeading(), const SizedBox(height: 22)],
      Row(
        children: [
          const Expanded(
            child: Text(
              'Groups',
              style: TextStyle(
                color: _quietText,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
          if (widget.onCreateGroup != null)
            _FocusableControl(
              key: const ValueKey('my-library-create-group'),
              focusNode: _createGroupFocus,
              onFocused: _focusedOwned,
              onPressed: widget.onCreateGroup!,
              onLeft: widget.onOpenRail,
              onDown: () => _requestSectionFocusAt(0),
              compact: true,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 16),
                  SizedBox(width: 4),
                  Text('New group'),
                ],
              ),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Expanded(
        child: ListView.builder(
          key: const ValueKey('my-library-directory'),
          controller: _directoryScroll,
          itemExtent: _directoryRowExtent,
          scrollCacheExtent: ScrollCacheExtent.pixels(_directoryRowExtent * 2),
          itemCount: _sections.length,
          itemBuilder: (context, index) {
            final section = _sections[index];
            return _SectionRow(
              key: ValueKey('my-library-section-${section.id}'),
              section: section,
              selected: section.id == _selected?.id,
              pending: section.id == _pendingSectionId,
              onNodeMounted: (node) => _mountSectionNode(section.id, node),
              onNodeUnmounted: (node) => _unmountSectionNode(section.id, node),
              onFocused: (node) => _focusedSection(section, node),
              onSelect: () => unawaited(_selectSection(section)),
              onMove: (amount) {
                if (index == 0 && amount < 0 && widget.onCreateGroup != null) {
                  _createGroupFocus.requestFocus();
                  return;
                }
                _moveSection(index, amount);
              },
              onLeft: _isNarrow ? _closeDirectory : widget.onOpenRail,
              onRight: () {
                if (section.id != _selected?.id) {
                  unawaited(
                    _selectSection(section).then((_) {
                      if (mounted && _selected?.id == section.id) {
                        _focusFirstLedgerTarget();
                      }
                    }),
                  );
                } else {
                  if (_directoryOpen && _isNarrow) _closeDirectory();
                  _focusFirstLedgerTarget();
                }
              },
            );
          },
        ),
      ),
    ],
  );

  Widget _buildLedger() {
    final selected = _selected!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                selected.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _warmWhite,
                  fontFamily: Cinema.display,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
            ),
            if (widget.onManageGroup != null) ...[
              const SizedBox(width: 12),
              _FocusableControl(
                key: const ValueKey('my-library-manage-group'),
                focusNode: _manageGroupFocus,
                onFocused: _focusedOwned,
                onPressed: () => widget.onManageGroup!(selected),
                onLeft: _focusSelectedSection,
                onDown: _focusFirstLedgerTarget,
                compact: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.tune_rounded, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      selected.kind == MyLibrarySectionKind.favorites
                          ? 'Manage Favorites'
                          : 'Manage group',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${_formatCount(_totalCount ?? selected.itemCount)} items',
          style: const TextStyle(color: _quietText, fontSize: 13),
        ),
        if (_recoveryMessage != null) ...[
          const SizedBox(height: 10),
          _RecoveryNotice(
            message: _recoveryMessage!,
            focusNode: _retryFocus,
            onFocused: _focusedOwned,
            onRetry: _retryRecovery,
            onLeft: _focusSelectedSection,
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: _loadingItems
              ? const _LedgerSkeleton()
              : _itemFailure
              ? _InlineFailure(
                  focusNode: _retryFocus,
                  onFocused: _focusedOwned,
                  onRetry: _retrySelectedSection,
                  onLeft: _focusSelectedSection,
                )
              : _items.isEmpty
              ? _EmptySection(
                  focusNode: _emptySectionFocus,
                  onFocused: _focusedOwned,
                  onLeft: _focusSelectedSection,
                )
              : ListView.builder(
                  key: ValueKey('my-library-items-${selected.id}'),
                  controller: _itemScroll,
                  itemExtent: _itemRowExtent,
                  scrollCacheExtent: ScrollCacheExtent.pixels(
                    _itemRowExtent * 2,
                  ),
                  itemCount:
                      _items.length +
                      (_loadingMore || _pageFailure || _nextCursor != null
                          ? 1
                          : 0),
                  itemBuilder: (context, index) {
                    if (index >= _items.length) {
                      if (_loadingMore) return const _LoadingMoreRow();
                      if (_pageFailure) {
                        return _PageFailureRow(
                          focusNode: _pageRetryFocus,
                          onFocused: _focusedOwned,
                          onRetry: () => _loadMore(focusFirstNew: true),
                          onLeft: _focusSelectedSection,
                          onUp: () => _requestItemFocusAt(_items.length - 1),
                        );
                      }
                      return const SizedBox.shrink();
                    }
                    final item = _items[index];
                    return _ItemRow(
                      key: ValueKey('${selected.id}:${item.id}'),
                      item: item,
                      artworkBuilder: widget.artworkBuilder,
                      onNodeMounted: (node) => _mountItemNode(item.id, node),
                      onNodeUnmounted: (node) =>
                          _unmountItemNode(item.id, node),
                      onFocused: (node) => _focusedItem(item, node),
                      onActivate: () => unawaited(_activateItem(item)),
                      onOrganize: widget.onOrganizeItem == null
                          ? null
                          : () => widget.onOrganizeItem!(item),
                      onMove: (amount) => _moveItem(index, amount),
                      onLeft: _focusSelectedSection,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

sealed class _LibraryContinuation {
  const _LibraryContinuation(this.presentation);
  final MyLibraryItem presentation;
}

class _MovieLibraryContinuation extends _LibraryContinuation {
  const _MovieLibraryContinuation(super.presentation, this.exact, this.handoff);
  final LibraryCatalogItem exact;
  final MoviePlaybackHandoff handoff;
}

class _SeriesLibraryContinuation extends _LibraryContinuation {
  const _SeriesLibraryContinuation(
    super.presentation,
    this.exact, {
    required this.loading,
    this.info,
    this.failure,
  });
  final LibraryCatalogItem exact;
  final bool loading;
  final SeriesInfo? info;
  final ContinuationFailure? failure;
}

class _FailureLibraryContinuation extends _LibraryContinuation {
  const _FailureLibraryContinuation(super.presentation, this.failure);
  final ContinuationFailure failure;
}

class _PageHeading extends StatelessWidget {
  const _PageHeading();

  @override
  Widget build(BuildContext context) => const Text(
    'My Library',
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: _warmWhite,
      fontFamily: Cinema.display,
      fontSize: 28,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.6,
    ),
  );
}

class _SectionRow extends StatefulWidget {
  const _SectionRow({
    super.key,
    required this.section,
    required this.selected,
    required this.pending,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onFocused,
    required this.onSelect,
    required this.onMove,
    required this.onLeft,
    required this.onRight,
  });

  final MyLibrarySection section;
  final bool selected;
  final bool pending;
  final ValueChanged<FocusNode> onNodeMounted;
  final ValueChanged<FocusNode> onNodeUnmounted;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onSelect;
  final ValueChanged<int> onMove;
  final VoidCallback onLeft;
  final VoidCallback onRight;

  @override
  State<_SectionRow> createState() => _SectionRowState();
}

class _SectionRowState extends State<_SectionRow> {
  late final FocusNode _focusNode;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      debugLabel: 'my library section ${widget.section.id}',
    );
    widget.onNodeMounted(_focusNode);
  }

  @override
  void dispose() {
    widget.onNodeUnmounted(_focusNode);
    _focusNode.dispose();
    super.dispose();
  }

  Color get ink => _focused
      ? Cinema.amberInk
      : widget.selected
      ? _amber
      : Cinema.quiet;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    onFocusChange: (focused) {
      setState(() => _focused = focused);
      if (focused) widget.onFocused(_focusNode);
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
          '${widget.section.name}, ${_formatCount(widget.section.itemCount)} items',
      child: GestureDetector(
        onTap: () {
          _focusNode.requestFocus();
          widget.onSelect();
        },
        child: AnimatedContainer(
          key: ValueKey('my-library-section-row-${widget.section.id}'),
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            // Focus fills the pill solid amber: the glow ring would show
            // through the selected pill's translucent fill.
            color: _focused
                ? _amber
                : widget.selected
                ? Cinema.glass
                : const Color(0x00000000),
            borderRadius: BorderRadius.circular(20),
            boxShadow: _focused ? [Cinema.focusGlow.last] : const [],
          ),
          child: Row(
            children: [
              Icon(
                widget.section.kind == MyLibrarySectionKind.favorites
                    ? Icons.bookmark_border
                    : Icons.video_library_outlined,
                size: 18,
                color: ink,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.section.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ink,
                    fontSize: 14,
                    fontWeight: widget.selected
                        ? FontWeight.w700
                        : FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (widget.pending)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: ink),
                )
              else
                Text(
                  _formatCount(widget.section.itemCount),
                  style: TextStyle(
                    color: _focused ? Cinema.amberInk : _quietText,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ItemRow extends StatefulWidget {
  const _ItemRow({
    super.key,
    required this.item,
    required this.artworkBuilder,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onFocused,
    required this.onActivate,
    this.onOrganize,
    required this.onMove,
    required this.onLeft,
  });

  final MyLibraryItem item;
  final MyLibraryArtworkBuilder? artworkBuilder;
  final ValueChanged<FocusNode> onNodeMounted;
  final ValueChanged<FocusNode> onNodeUnmounted;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onActivate;
  final VoidCallback? onOrganize;
  final ValueChanged<int> onMove;
  final VoidCallback onLeft;

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  late final FocusNode _focusNode;
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'my library item ${widget.item.id}');
    widget.onNodeMounted(_focusNode);
  }

  @override
  void dispose() {
    widget.onNodeUnmounted(_focusNode);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final availability = switch (widget.item.availability) {
      MyLibraryItemAvailability.available => null,
      MyLibraryItemAvailability.itemUnavailable => 'Unavailable',
      MyLibraryItemAvailability.sourceUnavailable => 'Source unavailable',
    };
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onFocused(_focusNode);
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
          case LogicalKeyboardKey.arrowRight:
          case LogicalKeyboardKey.contextMenu:
            widget.onOrganize?.call();
            return widget.onOrganize == null
                ? KeyEventResult.ignored
                : KeyEventResult.handled;
          case LogicalKeyboardKey.enter:
          case LogicalKeyboardKey.select:
            widget.onActivate();
            return KeyEventResult.handled;
          default:
            return KeyEventResult.ignored;
        }
      },
      child: Semantics(
        button: true,
        enabled: widget.item.isAvailable,
        label:
            '${widget.item.title}, ${widget.item.kind.label}, ${widget.item.sourceLabel}${availability == null ? '' : ', $availability'}',
        customSemanticsActions: widget.onOrganize == null
            ? null
            : {
                const CustomSemanticsAction(label: 'Organize item'):
                    widget.onOrganize!,
              },
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: () {
              _focusNode.requestFocus();
              widget.onActivate();
            },
            child: AnimatedContainer(
              key: ValueKey('my-library-item-${widget.item.id}'),
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              padding: const EdgeInsets.fromLTRB(6, 0, 10, 0),
              decoration: BoxDecoration(
                // Opaque when focused so the ring stays a ring.
                color: _focused
                    ? _raised
                    : _hovered
                    ? Cinema.glass
                    : const Color(0x00000000),
                borderRadius: BorderRadius.circular(14),
                boxShadow: _focused ? Cinema.focusGlow : const [],
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 88,
                    child: Center(
                      child: SizedBox(
                        key: ValueKey('my-library-artwork-${widget.item.id}'),
                        width: widget.item.kind == MyLibraryMediaKind.live
                            ? 88
                            : 34,
                        height: 50,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            widget.item.kind == MyLibraryMediaKind.live
                                ? 10
                                : 6,
                          ),
                          child:
                              widget.artworkBuilder?.call(
                                context,
                                widget.item,
                                _focused,
                              ) ??
                              _ArtworkPlaceholder(kind: widget.item.kind),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: widget.item.isAvailable
                                ? _warmWhite
                                : _quietText,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${widget.item.kind.label} · ${availability ?? widget.item.sourceLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: availability == null ? Cinema.quiet : _amber,
                            fontSize: 12.5,
                            fontWeight: availability == null
                                ? FontWeight.w400
                                : FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!widget.item.isAvailable) ...[
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.link_off_outlined,
                      color: _quietText,
                      size: 20,
                    ),
                  ],
                  if (widget.onOrganize != null) ...[
                    const SizedBox(width: 8),
                    Visibility(
                      visible: _focused || _hovered,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: Tooltip(
                        message: 'Organize',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            _focusNode.requestFocus();
                            widget.onOrganize!();
                          },
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: const BoxDecoration(
                              color: Color(0xB80B0B0E),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.bookmark_add_outlined,
                              size: 17,
                              color: _warmWhite,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder({required this.kind});
  final MyLibraryMediaKind kind;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: kind == MyLibraryMediaKind.live ? const Color(0xFF3A3A43) : _raised,
    child: Icon(
      switch (kind) {
        MyLibraryMediaKind.live => Icons.live_tv_outlined,
        MyLibraryMediaKind.movie => Icons.movie_outlined,
        MyLibraryMediaKind.series => Icons.tv_outlined,
      },
      color: _quietText,
      size: 18,
    ),
  );
}

class _DirectoryLauncher extends StatelessWidget {
  const _DirectoryLauncher({
    required this.focusNode,
    required this.selected,
    required this.open,
    required this.onFocused,
    required this.onPressed,
    required this.onLeft,
    required this.onDown,
  });
  final FocusNode focusNode;
  final MyLibrarySection selected;
  final bool open;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onPressed, onLeft, onDown;

  @override
  Widget build(BuildContext context) => _FocusableControl(
    key: const ValueKey('my-library-directory-launcher'),
    focusNode: focusNode,
    onFocused: onFocused,
    onPressed: onPressed,
    onLeft: onLeft,
    onDown: onDown,
    child: Row(
      children: [
        const Icon(Icons.bookmarks_outlined, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            selected.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          _formatCount(selected.itemCount),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        const SizedBox(width: 8),
        Icon(open ? Icons.expand_less : Icons.expand_more, size: 20),
      ],
    ),
  );
}

/// A pill control: glass at rest, solid amber when focused. Text and icons
/// inside take its ink color.
class _FocusableControl extends StatefulWidget {
  const _FocusableControl({
    super.key,
    required this.focusNode,
    required this.onFocused,
    required this.onPressed,
    required this.child,
    this.onLeft,
    this.onUp,
    this.onDown,
    this.compact = false,
  });
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onPressed;
  final Widget child;
  final VoidCallback? onLeft, onUp, onDown;

  /// A smaller pill for header actions.
  final bool compact;

  @override
  State<_FocusableControl> createState() => _FocusableControlState();
}

class _FocusableControlState extends State<_FocusableControl> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ink = _focused ? Cinema.amberInk : _warmWhite;
    final height = widget.compact ? 36.0 : 44.0;
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onFocused(widget.focusNode);
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        switch (event.logicalKey) {
          case LogicalKeyboardKey.enter:
          case LogicalKeyboardKey.select:
            widget.onPressed();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowLeft:
            widget.onLeft?.call();
            return widget.onLeft == null
                ? KeyEventResult.ignored
                : KeyEventResult.handled;
          case LogicalKeyboardKey.arrowUp:
            widget.onUp?.call();
            return widget.onUp == null
                ? KeyEventResult.ignored
                : KeyEventResult.handled;
          case LogicalKeyboardKey.arrowDown:
            widget.onDown?.call();
            return widget.onDown == null
                ? KeyEventResult.ignored
                : KeyEventResult.handled;
          default:
            return KeyEventResult.ignored;
        }
      },
      child: Semantics(
        button: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: () {
              widget.focusNode.requestFocus();
              widget.onPressed();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              constraints: BoxConstraints(minHeight: height),
              padding: EdgeInsets.symmetric(
                horizontal: widget.compact ? 14 : 20,
                vertical: 8,
              ),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _focused
                    ? _amber
                    : _hovered
                    ? Cinema.glassFocused
                    : Cinema.glass,
                borderRadius: BorderRadius.circular(height / 2),
                boxShadow: _focused ? [Cinema.focusGlow.last] : const [],
              ),
              child: IconTheme.merge(
                data: IconThemeData(color: ink),
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    color: ink,
                    fontSize: widget.compact ? 13 : 14,
                    fontWeight: FontWeight.w700,
                  ),
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InitialFailure extends StatelessWidget {
  const _InitialFailure({
    required this.focusNode,
    required this.onFocused,
    required this.onLeft,
    required this.onRetry,
  });
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onLeft;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "Can't load My Library",
            textAlign: TextAlign.center,
            style: _messageTitle,
          ),
          const SizedBox(height: 8),
          const Text(
            'Your saved items are safe.',
            textAlign: TextAlign.center,
            style: _messageBody,
          ),
          const SizedBox(height: 20),
          _FocusableControl(
            key: const ValueKey('my-library-initial-retry'),
            focusNode: focusNode,
            onFocused: onFocused,
            onPressed: () => unawaited(onRetry()),
            onLeft: onLeft,
            child: const Text('Try again'),
          ),
        ],
      ),
    ),
  );
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _PageHeading(),
      Expanded(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bookmarks_outlined, color: _quietText, size: 32),
                SizedBox(height: 14),
                Text(
                  'Nothing saved yet',
                  textAlign: TextAlign.center,
                  style: _messageTitle,
                ),
                SizedBox(height: 8),
                Text(
                  'Save channels, movies and series with the bookmark button.',
                  textAlign: TextAlign.center,
                  style: _messageBody,
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class _EmptySection extends StatelessWidget {
  const _EmptySection({
    required this.focusNode,
    required this.onFocused,
    required this.onLeft,
  });
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onLeft;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focusNode,
    onFocusChange: (focused) {
      if (focused) onFocused(focusNode);
    },
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
              event.logicalKey == LogicalKeyboardKey.escape)) {
        onLeft();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bookmark_border, color: _quietText, size: 28),
          SizedBox(height: 12),
          Text('Nothing here yet', style: _messageTitle),
          SizedBox(height: 6),
          Text(
            'Nothing in this group can play right now.',
            textAlign: TextAlign.center,
            style: _messageBody,
          ),
        ],
      ),
    ),
  );
}

class _InlineFailure extends StatelessWidget {
  const _InlineFailure({
    required this.focusNode,
    required this.onFocused,
    required this.onRetry,
    required this.onLeft,
  });
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onFocused;
  final Future<bool> Function() onRetry;
  final VoidCallback onLeft;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "Can't load this group",
            textAlign: TextAlign.center,
            style: _messageTitle,
          ),
          const SizedBox(height: 20),
          _FocusableControl(
            key: const ValueKey('my-library-section-retry'),
            focusNode: focusNode,
            onFocused: onFocused,
            onPressed: () => unawaited(onRetry()),
            onLeft: onLeft,
            child: const Text('Try again'),
          ),
        ],
      ),
    ),
  );
}

class _RecoveryNotice extends StatelessWidget {
  const _RecoveryNotice({
    required this.message,
    required this.focusNode,
    required this.onFocused,
    required this.onRetry,
    required this.onLeft,
  });
  final String message;
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onFocused;
  final Future<void> Function() onRetry;
  final VoidCallback onLeft;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Row(
      children: [
        Expanded(
          child: Text(
            message,
            key: const ValueKey('my-library-recovery'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _amber, fontSize: 13),
          ),
        ),
        const SizedBox(width: 10),
        _FocusableControl(
          key: const ValueKey('my-library-recovery-retry'),
          focusNode: focusNode,
          onFocused: onFocused,
          onPressed: () => unawaited(onRetry()),
          onLeft: onLeft,
          compact: true,
          child: const Text('Try again'),
        ),
      ],
    ),
  );
}

class _PageFailureRow extends StatelessWidget {
  const _PageFailureRow({
    required this.focusNode,
    required this.onFocused,
    required this.onRetry,
    required this.onLeft,
    required this.onUp,
  });
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onFocused;
  final Future<void> Function() onRetry;
  final VoidCallback onLeft, onUp;

  @override
  Widget build(BuildContext context) => Center(
    child: _FocusableControl(
      key: const ValueKey('my-library-page-retry'),
      focusNode: focusNode,
      onFocused: onFocused,
      onPressed: () => unawaited(onRetry()),
      onLeft: onLeft,
      onUp: onUp,
      compact: true,
      child: const Text("Couldn't load more · Try again"),
    ),
  );
}

class _LibrarySkeleton extends StatelessWidget {
  const _LibrarySkeleton();

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('my-library-loading'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _Skeleton(width: 190, height: 32),
      const SizedBox(height: 34),
      Expanded(
        child: Row(
          children: [
            SizedBox(
              width: 220,
              child: ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 6,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, _) => const _Skeleton(height: 40),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 7,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, _) => const _Skeleton(height: 56),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _LedgerSkeleton extends StatelessWidget {
  const _LedgerSkeleton();

  @override
  Widget build(BuildContext context) => ListView.separated(
    key: const ValueKey('my-library-ledger-loading'),
    physics: const NeverScrollableScrollPhysics(),
    itemCount: 7,
    separatorBuilder: (_, _) => const SizedBox(height: 8),
    itemBuilder: (_, _) => const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: _Skeleton(height: 56),
    ),
  );
}

class _LoadingMoreRow extends StatelessWidget {
  const _LoadingMoreRow();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 10),
    child: _Skeleton(height: 44),
  );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({this.width, required this.height});
  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
      ),
    ),
  );
}

String _formatCount(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return buffer.toString();
}

const _messageTitle = TextStyle(
  color: _warmWhite,
  fontFamily: Cinema.display,
  fontSize: 22,
  fontWeight: FontWeight.w800,
  letterSpacing: -0.3,
);

const _messageBody = TextStyle(color: Cinema.quiet, fontSize: 15, height: 1.4);
