import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'credential_store.dart';
import 'epg_models.dart';
import 'source_catalog_database.dart';

const xtreamEpgResponseByteLimit = 1024 * 1024;
const xtreamEpgRequestTimeout = Duration(seconds: 15);
const xtreamEpgBatchTimeout = Duration(minutes: 2);
const xtreamEpgRequestListingLimit = 24;
const xtreamEpgMaximumProgramsPerChannel = 32;
const xtreamEpgMaximumConcurrentRequests = 4;
const xtreamEpgMaximumQueuedChannels = 64;
const xtreamEpgPastRetention = Duration(hours: 2);
const xtreamEpgFutureHorizon = Duration(hours: 24);
const xtreamEpgTransientRetry = Duration(minutes: 5);
const xtreamEpgUnsupportedRetry = Duration(hours: 6);

class XtreamEpgService {
  XtreamEpgService({
    required this.database,
    CredentialStore? credentialStore,
    HttpClient Function()? clientFactory,
    DateTime Function()? now,
  }) : _credentialStore = credentialStore ?? SecureCredentialStore(),
       _clientFactory = clientFactory ?? HttpClient.new,
       _now = now ?? DateTime.now;

  final SourceCatalogDatabase database;
  final CredentialStore _credentialStore;
  final HttpClient Function() _clientFactory;
  final DateTime Function() _now;

  HttpClient? _activeClient;
  int _operation = 0;
  final Set<String> _pendingCatalogItemIds = {};
  bool _pendingManualRetry = false;
  Completer<EpgRefreshSummary>? _refreshCompleter;
  int? _refreshOperation;

  void cancel() {
    unawaited(cancelActiveRefresh());
  }

  /// Releases the current source/category refresh without making a newly
  /// selected scope wait for the obsolete drain. Claimed rows are released by
  /// the old batch through generation-safe cancelled failures.
  Future<void> cancelActiveRefresh() {
    final active = _refreshCompleter;
    ++_operation;
    _pendingCatalogItemIds.clear();
    _pendingManualRetry = false;
    _activeClient?.close(force: true);
    _activeClient = null;
    // Keep the active completer as a short barrier until every claimed row has
    // been generation-safely released. A new scope may request immediately,
    // but cannot claim the same row before cancelled cleanup finishes.
    return active?.future.then<void>((_) {}) ?? Future<void>.value();
  }

  /// Lazily refreshes only the exact visible catalog rows supplied by a
  /// presentation surface. It never enumerates a source or contacts M3U rows.
  /// [manualRetry] is reserved for an explicit Retry action; it bypasses only
  /// persisted error backoff and never an active database lease.
  Future<EpgRefreshSummary> refreshCatalogItems(
    Iterable<String> catalogItemIds, {
    bool manualRetry = false,
  }) {
    final bounded = catalogItemIds
        .take(xtreamEpgMaximumQueuedChannels)
        .toList(growable: false);
    final active = _refreshCompleter;
    if (bounded.isEmpty) {
      // An empty mounted window is a lifecycle release: preserve the current
      // in-flight wave, but do not keep fetching rows that are now off-screen.
      _pendingCatalogItemIds.clear();
      _pendingManualRetry = false;
      return active?.future ?? Future.value(const EpgRefreshSummary.none());
    }
    if (active != null) {
      if (_refreshOperation != _operation) {
        // Cancellation/timeout cleanup owns the old completer. Start the new
        // viewport only after that cleanup releases its exact database leases.
        return active.future.then(
          (_) => refreshCatalogItems(bounded, manualRetry: manualRetry),
        );
      }
      _replacePendingViewport(bounded, manualRetry: manualRetry);
      return active.future;
    }

    _replacePendingViewport(bounded, manualRetry: manualRetry);
    final completer = Completer<EpgRefreshSummary>();
    _refreshCompleter = completer;
    final operation = ++_operation;
    _refreshOperation = operation;
    unawaited(_drainRefreshQueue(operation, completer));
    return completer.future;
  }

  void _replacePendingViewport(
    Iterable<String> catalogItemIds, {
    required bool manualRetry,
  }) {
    // This iterable is the caller's complete mounted/near-visible window.
    // Keep the current batch, but supersede not-yet-started obsolete rows.
    _pendingCatalogItemIds.clear();
    for (final id in catalogItemIds) {
      _pendingCatalogItemIds.add(id);
    }
    _pendingManualRetry = manualRetry;
  }

  Future<void> _drainRefreshQueue(
    int operation,
    Completer<EpgRefreshSummary> completer,
  ) async {
    var claimed = 0;
    var refreshed = 0;
    var empty = 0;
    var failed = 0;
    var unsupported = 0;
    EpgRefreshFailure? failure;
    try {
      while (operation == _operation) {
        while (operation == _operation && _pendingCatalogItemIds.isNotEmpty) {
          final batch = _pendingCatalogItemIds
              .take(xtreamEpgMaximumConcurrentRequests)
              .toList(growable: false);
          final manualRetry = _pendingManualRetry;
          _pendingCatalogItemIds.removeAll(batch);
          final result = await _refreshBatch(
            batch,
            operation,
            manualRetry: manualRetry,
          );
          claimed += result.claimed;
          refreshed += result.refreshed;
          empty += result.empty;
          failed += result.failed;
          unsupported += result.unsupported;
          failure = result.failure ?? failure;
        }
        try {
          await database.pruneExpiredEpg(
            _now().toUtc().subtract(xtreamEpgPastRetention),
          );
        } catch (_) {
          // Maintenance never fails a usable result. Recheck the queue because
          // a viewport may have arrived while this off-isolate prune awaited.
        }
        if (_pendingCatalogItemIds.isEmpty) break;
      }
    } finally {
      if (identical(_refreshCompleter, completer)) {
        _refreshCompleter = null;
        _refreshOperation = null;
        _pendingManualRetry = false;
      }
      if (!completer.isCompleted) {
        completer.complete(
          EpgRefreshSummary(
            claimed: claimed,
            refreshed: refreshed,
            empty: empty,
            failed: failed,
            unsupported: unsupported,
            failure: failure,
          ),
        );
      }
    }
  }

  Future<EpgRefreshSummary> _refreshBatch(
    List<String> catalogItemIds,
    int operation, {
    required bool manualRetry,
  }) async {
    final now = _now().toUtc();
    List<EpgRefreshTarget> targets;
    try {
      targets = await database.claimEpgRefreshTargets(
        catalogItemIds: catalogItemIds,
        nowUtc: now,
        manualRetry: manualRetry,
      );
    } catch (_) {
      return EpgRefreshSummary(
        claimed: 0,
        refreshed: 0,
        empty: 0,
        failed: catalogItemIds.length,
        unsupported: 0,
        failure: EpgRefreshFailure.localPersistence,
      );
    }
    if (targets.isEmpty) {
      return const EpgRefreshSummary.none();
    }
    if (operation != _operation) {
      final persistenceFailed = await _recordFailures(
        targets,
        EpgRefreshFailure.cancelled,
        now,
      );
      return EpgRefreshSummary(
        claimed: targets.length,
        refreshed: 0,
        empty: 0,
        failed: targets.length,
        unsupported: 0,
        failure: persistenceFailed ? EpgRefreshFailure.localPersistence : null,
      );
    }

    late final HttpClient client;
    try {
      client = _clientFactory()..connectionTimeout = xtreamEpgRequestTimeout;
    } catch (_) {
      final failure = operation == _operation
          ? EpgRefreshFailure.unreachable
          : EpgRefreshFailure.cancelled;
      final persistenceFailed = await _recordFailures(targets, failure, now);
      return EpgRefreshSummary(
        claimed: targets.length,
        refreshed: 0,
        empty: 0,
        failed: targets.length,
        unsupported: 0,
        failure: persistenceFailed ? EpgRefreshFailure.localPersistence : null,
      );
    }
    _activeClient = client;
    final accessBySource = <String, Future<_XtreamEpgAccess?>>{};
    var refreshed = 0;
    var empty = 0;
    var failed = 0;
    var unsupported = 0;
    EpgRefreshFailure? batchFailure;
    final iterator = targets.iterator;

    Future<void> worker() async {
      while (operation == _operation && iterator.moveNext()) {
        final target = iterator.current;
        final access = await accessBySource.putIfAbsent(
          target.sourceId,
          () => _loadAccess(target.sourceId),
        );
        final result = await _refreshOne(
          client: client,
          access: access,
          target: target,
          operation: operation,
          nowUtc: now,
        );
        if (result.failure != null) batchFailure = result.failure;
        switch (result.outcome) {
          case _EpgTargetOutcome.refreshed:
            refreshed++;
          case _EpgTargetOutcome.empty:
            empty++;
          case _EpgTargetOutcome.failed:
            failed++;
          case _EpgTargetOutcome.unsupported:
            unsupported++;
        }
      }
    }

    var timedOut = false;
    try {
      await Future.wait(
        List.generate(
          targets.length.clamp(1, xtreamEpgMaximumConcurrentRequests),
          (_) => worker(),
        ),
      ).timeout(xtreamEpgBatchTimeout);
    } on TimeoutException {
      timedOut = true;
      if (operation == _operation) {
        ++_operation;
        _pendingCatalogItemIds.clear();
      }
      client.close(force: true);
      if (await _recordFailures(targets, EpgRefreshFailure.timedOut, now)) {
        batchFailure = EpgRefreshFailure.localPersistence;
      }
    } finally {
      client.close(force: true);
      if (identical(_activeClient, client)) _activeClient = null;
    }
    if (!timedOut && operation != _operation) {
      // A claim leases every row before the fixed worker pool begins. Release
      // rows that never reached a worker as well as any interrupted request.
      if (await _recordFailures(targets, EpgRefreshFailure.cancelled, now)) {
        batchFailure = EpgRefreshFailure.localPersistence;
      }
      failed = targets.length - refreshed - empty - unsupported;
    }
    if (timedOut) {
      failed = targets.length - refreshed - empty - unsupported;
    }
    return EpgRefreshSummary(
      claimed: targets.length,
      refreshed: refreshed,
      empty: empty,
      failed: failed,
      unsupported: unsupported,
      failure: batchFailure,
    );
  }

  Future<_XtreamEpgAccess?> _loadAccess(String sourceId) async {
    try {
      final record = await database.loadSourceOperation(sourceId);
      if (record == null || record.kind != 'xtream') return null;
      final credential = await _credentialStore.read(record.credentialKey);
      final serverUrl = credential?.serverUrl;
      if (credential == null || serverUrl == null || serverUrl.isEmpty) {
        return null;
      }
      final endpoint = _playerApi(serverUrl);
      return _XtreamEpgAccess(endpoint: endpoint, credential: credential);
    } catch (_) {
      return null;
    }
  }

  Future<_EpgTargetResult> _refreshOne({
    required HttpClient client,
    required _XtreamEpgAccess? access,
    required EpgRefreshTarget target,
    required int operation,
    required DateTime nowUtc,
  }) async {
    try {
      _throwIfCancelled(operation);
      if (access == null) {
        throw const _EpgRequestFailure(
          EpgRefreshFailure.credentialsUnavailable,
        );
      }
      final uri = access.endpoint.replace(
        queryParameters: {
          'username': access.credential.username,
          'password': access.credential.password,
          'action': 'get_short_epg',
          'stream_id': target.providerStreamId,
          'limit': '$xtreamEpgRequestListingLimit',
        },
      );
      final request = await client.getUrl(uri).timeout(xtreamEpgRequestTimeout);
      request.followRedirects = false;
      final response = await request.close().timeout(xtreamEpgRequestTimeout);
      if (response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden) {
        throw const _EpgRequestFailure(EpgRefreshFailure.authentication);
      }
      if (response.statusCode == HttpStatus.notFound ||
          response.statusCode == HttpStatus.methodNotAllowed ||
          response.statusCode == HttpStatus.notImplemented) {
        throw const _EpgRequestFailure(EpgRefreshFailure.unsupported);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const _EpgRequestFailure(EpgRefreshFailure.unreachable);
      }
      if (response.contentLength > xtreamEpgResponseByteLimit) {
        throw const _EpgRequestFailure(EpgRefreshFailure.responseTooLarge);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(xtreamEpgRequestTimeout)) {
        _throwIfCancelled(operation);
        if (bytes.length + chunk.length > xtreamEpgResponseByteLimit) {
          throw const _EpgRequestFailure(EpgRefreshFailure.responseTooLarge);
        }
        bytes.add(chunk);
      }
      final payload = bytes.takeBytes();
      final parseResult = await Isolate.run<_XtreamEpgParseResult>(
        () => _parseXtreamEpgResponse(
          payload,
          catalogItemId: target.catalogItemId,
          nowUtc: nowUtc,
        ),
      );
      if (parseResult.outcome == _XtreamEpgParseOutcome.malformedRows) {
        throw const FormatException('epg-listings-rows');
      }
      final programs = parseResult.programs;
      _throwIfCancelled(operation);
      late final bool committed;
      try {
        committed = await database.commitEpgRefreshTarget(
          target: target,
          programs: programs,
          completedAtUtc: _now().toUtc(),
        );
      } catch (_) {
        return await _recordTargetFailure(
          target,
          EpgRefreshFailure.localPersistence,
          nowUtc,
        );
      }
      if (!committed) return const _EpgTargetResult.failed();
      return programs.isEmpty
          ? const _EpgTargetResult.empty()
          : const _EpgTargetResult.refreshed();
    } on _EpgRequestFailure catch (error) {
      final failure = operation == _operation
          ? error.failure
          : EpgRefreshFailure.cancelled;
      return _recordTargetFailure(target, failure, nowUtc);
    } on TimeoutException {
      final failure = operation == _operation
          ? EpgRefreshFailure.timedOut
          : EpgRefreshFailure.cancelled;
      return _recordTargetFailure(target, failure, nowUtc);
    } on FormatException {
      final failure = operation == _operation
          ? EpgRefreshFailure.malformedResponse
          : EpgRefreshFailure.cancelled;
      return _recordTargetFailure(target, failure, nowUtc);
    } on SocketException {
      final failure = operation == _operation
          ? EpgRefreshFailure.unreachable
          : EpgRefreshFailure.cancelled;
      return _recordTargetFailure(target, failure, nowUtc);
    } catch (_) {
      final failure = operation == _operation
          ? EpgRefreshFailure.unreachable
          : EpgRefreshFailure.cancelled;
      return _recordTargetFailure(target, failure, nowUtc);
    }
  }

  Future<_EpgTargetResult> _recordTargetFailure(
    EpgRefreshTarget target,
    EpgRefreshFailure failure,
    DateTime failedAtUtc,
  ) async {
    final persisted = await _recordFailure(target, failure, failedAtUtc);
    if (!persisted || failure == EpgRefreshFailure.localPersistence) {
      return const _EpgTargetResult.failed(
        failure: EpgRefreshFailure.localPersistence,
      );
    }
    return failure == EpgRefreshFailure.unsupported
        ? const _EpgTargetResult.unsupported()
        : const _EpgTargetResult.failed();
  }

  Future<bool> _recordFailures(
    Iterable<EpgRefreshTarget> targets,
    EpgRefreshFailure failure,
    DateTime failedAtUtc,
  ) async {
    var persistenceFailed = false;
    for (final target in targets) {
      if (!await _recordFailure(target, failure, failedAtUtc)) {
        persistenceFailed = true;
      }
    }
    return persistenceFailed;
  }

  Future<bool> _recordFailure(
    EpgRefreshTarget target,
    EpgRefreshFailure failure,
    DateTime failedAtUtc,
  ) async {
    final retry = switch (failure) {
      EpgRefreshFailure.cancelled => Duration.zero,
      EpgRefreshFailure.unsupported => xtreamEpgUnsupportedRetry,
      _ => xtreamEpgTransientRetry,
    };
    try {
      await database.failEpgRefreshTarget(
        target: target,
        failure: failure,
        failedAtUtc: failedAtUtc,
        retryAfterUtc: failedAtUtc.add(retry),
      );
      return true;
    } catch (_) {
      // Guide persistence failures remain isolated from catalog and playback.
      return false;
    }
  }

  void _throwIfCancelled(int operation) {
    if (operation != _operation) {
      throw const _EpgRequestFailure(EpgRefreshFailure.cancelled);
    }
  }
}

/// Parses only the bounded JSON form returned by Xtream's per-stream short EPG
/// endpoint. Naive local timestamps are rejected rather than interpreted using
/// the workstation timezone.
List<EpgProgram> parseXtreamEpgResponse(
  Uint8List bytes, {
  required String catalogItemId,
  required DateTime nowUtc,
}) {
  final result = _parseXtreamEpgResponse(
    bytes,
    catalogItemId: catalogItemId,
    nowUtc: nowUtc,
  );
  if (result.outcome == _XtreamEpgParseOutcome.malformedRows) {
    throw const FormatException('epg-listings-rows');
  }
  return result.programs;
}

_XtreamEpgParseResult _parseXtreamEpgResponse(
  Uint8List bytes, {
  required String catalogItemId,
  required DateTime nowUtc,
}) {
  final decoded = utf8.decode(bytes);
  final raw = jsonDecode(
    decoded.startsWith('\ufeff') ? decoded.substring(1) : decoded,
  );
  final Object? listings = raw is Map ? raw['epg_listings'] : raw;
  if (listings is! List) throw const FormatException('epg-listings');
  final earliest = nowUtc.toUtc().subtract(xtreamEpgPastRetention);
  final latest = nowUtc.toUtc().add(xtreamEpgFutureHorizon);
  final byInterval = <String, EpgProgram>{};
  var structurallyValidRows = 0;
  for (final row in listings) {
    if (row is! Map) continue;
    final item = row;
    final start = _parseProviderTime(
      item['start_timestamp'],
      fallback: item['start'],
    );
    final end = _parseProviderTime(
      item['stop_timestamp'] ?? item['end_timestamp'],
      fallback: item['end'] ?? item['stop'],
    );
    final title = _decodeProviderText(item['title'], 512, collapse: true);
    if (start == null ||
        end == null ||
        !end.isAfter(start) ||
        end.difference(start) > epgMaximumProgramDuration ||
        title == null ||
        title.isEmpty) {
      continue;
    }
    structurallyValidRows++;
    if (!end.isAfter(earliest) || !start.isBefore(latest)) continue;
    final description = _decodeProviderText(item['description'], 4 * 1024);
    final key = '${start.millisecondsSinceEpoch}:${end.millisecondsSinceEpoch}';
    byInterval.putIfAbsent(
      key,
      () => EpgProgram(
        catalogItemId: catalogItemId,
        startUtc: start,
        endUtc: end,
        title: title,
        description: description,
      ),
    );
  }
  final programs = byInterval.values.toList()
    ..sort((a, b) {
      final start = a.startUtc.compareTo(b.startUtc);
      return start != 0 ? start : a.endUtc.compareTo(b.endUtc);
    });
  final boundedPrograms = List<EpgProgram>.unmodifiable(
    programs.take(xtreamEpgMaximumProgramsPerChannel),
  );
  final outcome = listings.isNotEmpty && structurallyValidRows == 0
      ? _XtreamEpgParseOutcome.malformedRows
      : boundedPrograms.isEmpty
      ? _XtreamEpgParseOutcome.validEmpty
      : _XtreamEpgParseOutcome.validPrograms;
  return _XtreamEpgParseResult(
    outcome: outcome,
    programs: boundedPrograms,
    listingCount: listings.length,
    structurallyValidRowCount: structurallyValidRows,
    retainedIntervalCount: byInterval.length,
  );
}

enum _XtreamEpgParseOutcome { validPrograms, validEmpty, malformedRows }

/// Keeps only non-sensitive parse truth; provider rows and text never cross
/// the parser boundary or enter ordinary diagnostics.
class _XtreamEpgParseResult {
  const _XtreamEpgParseResult({
    required this.outcome,
    required this.programs,
    required this.listingCount,
    required this.structurallyValidRowCount,
    required this.retainedIntervalCount,
  });

  final _XtreamEpgParseOutcome outcome;
  final List<EpgProgram> programs;
  final int listingCount;
  final int structurallyValidRowCount;
  final int retainedIntervalCount;

  @override
  String toString() =>
      '_XtreamEpgParseResult(outcome: $outcome, listings: $listingCount, '
      'structurallyValid: $structurallyValidRowCount, '
      'retainedIntervals: $retainedIntervalCount)';
}

DateTime? _parseProviderTime(Object? primary, {required Object? fallback}) {
  final epoch = _parseEpochMilliseconds(primary);
  if (epoch != null) {
    return DateTime.fromMillisecondsSinceEpoch(epoch, isUtc: true);
  }
  if (fallback is! String) return null;
  final value = fallback.trim();
  if (!RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$').hasMatch(value)) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  final utc = parsed.toUtc();
  return _plausibleEpoch(utc.millisecondsSinceEpoch) ? utc : null;
}

int? _parseEpochMilliseconds(Object? value) {
  final raw = value is int
      ? value
      : value is num
      ? value.toInt()
      : value is String
      ? int.tryParse(value.trim())
      : null;
  if (raw == null) return null;
  final milliseconds = raw.abs() >= 100000000000 ? raw : raw * 1000;
  return _plausibleEpoch(milliseconds) ? milliseconds : null;
}

bool _plausibleEpoch(int value) =>
    value >= DateTime.utc(2000).millisecondsSinceEpoch &&
    value < DateTime.utc(2100).millisecondsSinceEpoch;

String? _decodeProviderText(
  Object? value,
  int maxBytes, {
  bool collapse = false,
}) {
  if (value is! String) return null;
  var text = value.trim();
  if (text.isEmpty) return null;
  if (text.length % 4 == 0 &&
      RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(text)) {
    try {
      final candidate = utf8.decode(base64.decode(text));
      if (!_hasDisallowedControl(candidate)) text = candidate;
    } on FormatException {
      // Some providers return plain UTF-8 despite the Xtream Base64 contract.
    }
  }
  text = text.replaceAll(
    RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'),
    '',
  );
  if (collapse) text = text.replaceAll(RegExp(r'\s+'), ' ');
  text = _truncateUtf8(text.trim(), maxBytes);
  return text.isEmpty ? null : text;
}

bool _hasDisallowedControl(String value) =>
    RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]').hasMatch(value);

String _truncateUtf8(String value, int maxBytes) {
  if (utf8.encode(value).length <= maxBytes) return value;
  final buffer = StringBuffer();
  var used = 0;
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    final length = utf8.encode(character).length;
    if (used + length > maxBytes) break;
    buffer.write(character);
    used += length;
  }
  return buffer.toString();
}

Uri _playerApi(String serverUrl) {
  final base = Uri.tryParse(serverUrl);
  if (base == null ||
      (base.scheme != 'http' && base.scheme != 'https') ||
      base.host.isEmpty ||
      base.userInfo.isNotEmpty) {
    throw const _EpgRequestFailure(EpgRefreshFailure.credentialsUnavailable);
  }
  final segments = base.pathSegments.where((part) => part.isNotEmpty).toList();
  if (segments.lastOrNull == 'player_api.php') segments.removeLast();
  return base.replace(
    pathSegments: [...segments, 'player_api.php'],
    query: null,
    fragment: null,
  );
}

class _XtreamEpgAccess {
  const _XtreamEpgAccess({required this.endpoint, required this.credential});

  final Uri endpoint;
  final StoredCredential credential;
}

class _EpgRequestFailure implements Exception {
  const _EpgRequestFailure(this.failure);

  final EpgRefreshFailure failure;

  @override
  String toString() => 'Epg request unavailable.';
}

enum _EpgTargetOutcome { refreshed, empty, failed, unsupported }

class _EpgTargetResult {
  const _EpgTargetResult._(this.outcome, {this.failure});

  const _EpgTargetResult.refreshed() : this._(_EpgTargetOutcome.refreshed);

  const _EpgTargetResult.empty() : this._(_EpgTargetOutcome.empty);

  const _EpgTargetResult.failed({EpgRefreshFailure? failure})
    : this._(_EpgTargetOutcome.failed, failure: failure);

  const _EpgTargetResult.unsupported() : this._(_EpgTargetOutcome.unsupported);

  final _EpgTargetOutcome outcome;
  final EpgRefreshFailure? failure;
}
