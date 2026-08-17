import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'strong_probe_models.dart';

const accountRequestTimeout = Duration(seconds: 10);
const discoveryRequestTimeout = Duration(seconds: 60);
const _initialRenderTimeout = Duration(seconds: 20);
const accountResponseByteLimit = 1024 * 1024;
const discoveryResponseByteLimit = 64 * 1024 * 1024;
const probeCategoryLimit = 100;

Uri normalizeXtreamEndpoint(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) throw const FormatException('Endpoint is required.');
  final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final parsed = Uri.parse(withScheme);
  if ((parsed.scheme != 'http' && parsed.scheme != 'https') ||
      parsed.host.isEmpty) {
    throw const FormatException('Use an http or https provider endpoint.');
  }

  final segments = parsed.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.isEmpty || segments.last != 'player_api.php') {
    segments.add('player_api.php');
  }
  return parsed.replace(pathSegments: segments, query: null, fragment: null);
}

Uri buildXtreamApiUri(
  StrongProbeCredentials credentials, {
  String? action,
  Map<String, String> extraQuery = const {},
}) {
  final endpoint = normalizeXtreamEndpoint(credentials.endpoint);
  return endpoint.replace(
    queryParameters: {
      'username': credentials.username,
      'password': credentials.password,
      ...(action == null ? const <String, String>{} : {'action': action}),
      ...extraQuery,
    },
  );
}

Uri buildXtreamPlaybackUri(
  StrongProbeCredentials credentials,
  ProbeStreamCandidate candidate,
) {
  final endpoint = normalizeXtreamEndpoint(credentials.endpoint);
  final extension = candidate.extension.trim().isEmpty
      ? (candidate.kind == ProbeMediaKind.live ? 'ts' : 'mp4')
      : candidate.extension.trim();
  final path = <String>[
    candidate.kind.pathSegment,
    credentials.username,
    credentials.password,
    '${candidate.id}.$extension',
  ].join('/');
  return endpoint.replace(path: '/$path', query: null, fragment: null);
}

StrongAccountFacts parseAccountFacts(Object? raw) {
  final root = raw is Map ? raw : const <Object?, Object?>{};
  final userInfo = root['user_info'];
  final map = userInfo is Map ? userInfo : const <Object?, Object?>{};
  final authenticated = _asBool(map['auth']);
  final status = _normalizeStatus(map['status']);
  return StrongAccountFacts(
    authenticated: authenticated,
    status: status,
    maxConnections: _asNonNegativeInt(map['max_connections']),
    activeConnections: _asNonNegativeInt(map['active_cons']),
  );
}

String categoryDiscoveryAction(ProbeMediaKind kind) => switch (kind) {
  ProbeMediaKind.live => 'get_live_categories',
  ProbeMediaKind.movie => 'get_vod_categories',
  ProbeMediaKind.episode => 'get_series_categories',
};

String categoryCandidateAction(ProbeMediaKind kind) => switch (kind) {
  ProbeMediaKind.live => 'get_live_streams',
  ProbeMediaKind.movie => 'get_vod_streams',
  ProbeMediaKind.episode => 'get_series',
};

List<ProbeCategory> parseProbeCategories(
  Object? raw,
  ProbeMediaKind kind, {
  int limit = probeCategoryLimit,
}) {
  if (raw is! List) return const [];
  final categories = <ProbeCategory>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final id = _asString(entry['category_id']);
    final name = _asString(entry['category_name'] ?? entry['name']);
    if (id == null || name == null) continue;
    categories.add(ProbeCategory(kind: kind, id: id, name: name));
    if (categories.length == limit) break;
  }
  return List.unmodifiable(categories);
}

List<ProbeStreamCandidate> parseDiscoveryCandidates(
  Object? raw,
  ProbeMediaKind kind, {
  int limit = 40,
}) {
  if (raw is! List) return const [];
  final candidates = <ProbeStreamCandidate>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final idValue = kind == ProbeMediaKind.episode
        ? entry['id']
        : entry['stream_id'];
    final id = _asString(idValue);
    final title = _asString(entry['title'] ?? entry['name']);
    if (id == null || title == null) continue;
    final extension =
        _asString(entry['container_extension']) ??
        (kind == ProbeMediaKind.live ? 'ts' : 'mp4');
    candidates.add(
      ProbeStreamCandidate(
        kind: kind,
        id: id,
        title: title,
        extension: extension,
      ),
    );
    if (candidates.length == limit) break;
  }
  return List.unmodifiable(candidates);
}

List<ProbeStreamCandidate> parseSeriesCandidates(
  Object? raw, {
  int limit = 40,
}) {
  if (raw is! List) return const [];
  final candidates = <ProbeStreamCandidate>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final id = _asString(entry['series_id']);
    final title = _asString(entry['name'] ?? entry['title']);
    if (id == null || title == null) continue;
    candidates.add(
      ProbeStreamCandidate(
        kind: ProbeMediaKind.episode,
        id: id,
        title: title,
        extension: 'mp4',
      ),
    );
    if (candidates.length == limit) break;
  }
  return List.unmodifiable(candidates);
}

List<ProbeStreamCandidate> parseEpisodeCandidates(
  Object? raw, {
  int limit = 40,
}) {
  if (raw is! Map || raw['episodes'] is! Map) return const [];
  final entries = <Object?>[];
  for (final season in (raw['episodes'] as Map).values) {
    if (season is List) entries.addAll(season);
  }
  return parseDiscoveryCandidates(
    entries,
    ProbeMediaKind.episode,
    limit: limit,
  );
}

class StrongProbeClient {
  StrongProbeClient({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  HttpClient? _activeClient;

  Future<StrongAccountFacts> checkAccount(
    StrongProbeCredentials credentials,
  ) async {
    try {
      final raw = await _getJson(
        buildXtreamApiUri(credentials),
        timeout: accountRequestTimeout,
        byteLimit: accountResponseByteLimit,
      );
      return parseAccountFacts(raw);
    } on TimeoutException {
      throw const ProbeRequestException(ProbeFailure.accountInfoTimeout);
    } on ProbeResponseTooLarge {
      throw const ProbeRequestException(ProbeFailure.accountResponseTooLarge);
    } on ProbeRequestException {
      rethrow;
    } catch (_) {
      throw const ProbeRequestException(ProbeFailure.authentication);
    }
  }

  Future<List<ProbeCategory>> discoverCategories(
    StrongProbeCredentials credentials,
    ProbeMediaKind kind,
  ) async {
    try {
      final raw = await _getJson(
        buildXtreamApiUri(credentials, action: categoryDiscoveryAction(kind)),
        timeout: discoveryRequestTimeout,
        byteLimit: discoveryResponseByteLimit,
      );
      return parseProbeCategories(raw, kind);
    } on ProbeResponseTooLarge {
      throw const ProbeRequestException(ProbeFailure.discoveryResponseTooLarge);
    } on TimeoutException {
      throw const ProbeRequestException(ProbeFailure.discoveryTimeout);
    } on ProbeRequestException {
      rethrow;
    } catch (_) {
      throw const ProbeRequestException(ProbeFailure.discoveryTimeout);
    }
  }

  Future<List<ProbeStreamCandidate>> discoverCategoryCandidates(
    StrongProbeCredentials credentials,
    ProbeCategory category,
  ) async {
    try {
      final raw = await _getJson(
        buildXtreamApiUri(
          credentials,
          action: categoryCandidateAction(category.kind),
          extraQuery: {'category_id': category.id},
        ),
        timeout: discoveryRequestTimeout,
        byteLimit: discoveryResponseByteLimit,
      );
      return category.kind == ProbeMediaKind.episode
          ? parseSeriesCandidates(raw)
          : parseDiscoveryCandidates(raw, category.kind);
    } on ProbeResponseTooLarge {
      throw const ProbeRequestException(ProbeFailure.discoveryResponseTooLarge);
    } on TimeoutException {
      throw const ProbeRequestException(ProbeFailure.discoveryTimeout);
    } on ProbeRequestException {
      rethrow;
    } catch (_) {
      throw const ProbeRequestException(ProbeFailure.discoveryTimeout);
    }
  }

  Future<List<ProbeStreamCandidate>> discoverEpisodes(
    StrongProbeCredentials credentials,
    ProbeStreamCandidate series,
  ) async {
    try {
      final raw = await _getJson(
        buildXtreamApiUri(
          credentials,
          action: 'get_series_info',
          extraQuery: {'series_id': series.id},
        ),
        timeout: discoveryRequestTimeout,
        byteLimit: discoveryResponseByteLimit,
      );
      return parseEpisodeCandidates(raw);
    } on ProbeResponseTooLarge {
      throw const ProbeRequestException(ProbeFailure.discoveryResponseTooLarge);
    } on TimeoutException {
      throw const ProbeRequestException(ProbeFailure.discoveryTimeout);
    } on ProbeRequestException {
      rethrow;
    } catch (_) {
      throw const ProbeRequestException(ProbeFailure.discoveryTimeout);
    }
  }

  Future<Object?> _getJson(
    Uri uri, {
    required Duration timeout,
    required int byteLimit,
  }) async {
    final client = _clientFactory();
    _activeClient = client;
    var timedOut = false;
    final cancellationTimer = Timer(timeout, () {
      timedOut = true;
      client.close(force: true);
    });
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const ProbeRequestException(ProbeFailure.authentication);
      }
      final body = await readBoundedUtf8Body(response, maxBytes: byteLimit);
      return jsonDecode(body);
    } on ProbeResponseTooLarge {
      rethrow;
    } catch (_) {
      if (timedOut) throw TimeoutException('bounded request timed out');
      rethrow;
    } finally {
      cancellationTimer.cancel();
      client.close(force: true);
      if (identical(_activeClient, client)) _activeClient = null;
    }
  }

  void close() => _activeClient?.close(force: true);
}

class ProbeResponseTooLarge implements Exception {
  const ProbeResponseTooLarge();

  @override
  String toString() => 'ProbeResponseTooLarge';
}

Future<String> readBoundedUtf8Body(
  Stream<List<int>> response, {
  required int maxBytes,
}) async {
  final bytes = BytesBuilder(copy: false);
  var received = 0;
  await for (final chunk in response) {
    received += chunk.length;
    if (received > maxBytes) throw const ProbeResponseTooLarge();
    bytes.add(chunk);
  }
  return utf8.decode(bytes.takeBytes());
}

class ProbePlaybackHandle {
  ProbePlaybackHandle()
    : player = Player(
        configuration: const PlayerConfiguration(
          muted: true,
          logLevel: MPVLogLevel.error,
          title: 'Wabbit TV Phase 0 playback probe',
        ),
      );

  final Player player;
  late final VideoController controller = VideoController(player);

  Future<ProbeEvidence> run(
    ProbeStreamCandidate candidate,
    Uri mediaUri,
  ) async {
    final stopwatch = Stopwatch()..start();
    var observedPlayerError = false;
    final errors = player.stream.error.listen(
      (_) => observedPlayerError = true,
    );
    try {
      final dimensions = await (() async {
        await player.open(Media(mediaUri.toString()), play: true);
        return _waitForVideoDimensions();
      })().timeout(_initialRenderTimeout);
      final screenshot = await _captureScreenshot();
      final startupMs = stopwatch.elapsedMilliseconds;
      if (screenshot == null || screenshot.isEmpty) {
        return ProbeEvidence(
          kind: candidate.kind,
          passed: false,
          failure: ProbeFailure.screenshotUnavailable,
          startupMs: startupMs,
          width: dimensions.$1,
          height: dimensions.$2,
          screenshotPresent: false,
        );
      }
      await Future<void>.delayed(const Duration(seconds: 5));
      return ProbeEvidence(
        kind: candidate.kind,
        passed: true,
        failure: null,
        startupMs: startupMs,
        width: dimensions.$1,
        height: dimensions.$2,
        screenshotPresent: true,
      );
    } on TimeoutException {
      return ProbeEvidence(
        kind: candidate.kind,
        passed: false,
        failure: observedPlayerError
            ? ProbeFailure.playerError
            : player.state.position > Duration.zero
            ? ProbeFailure.noVideoTrack
            : ProbeFailure.streamTimeout,
        startupMs: stopwatch.elapsedMilliseconds,
        width: null,
        height: null,
        screenshotPresent: false,
      );
    } on ProbeRequestException catch (error) {
      return ProbeEvidence(
        kind: candidate.kind,
        passed: false,
        failure: error.failure,
        startupMs: stopwatch.elapsedMilliseconds,
        width: null,
        height: null,
        screenshotPresent: false,
      );
    } catch (_) {
      return ProbeEvidence(
        kind: candidate.kind,
        passed: false,
        failure: observedPlayerError
            ? ProbeFailure.playerError
            : ProbeFailure.buildOrPluginFailure,
        startupMs: stopwatch.elapsedMilliseconds,
        width: null,
        height: null,
        screenshotPresent: false,
      );
    } finally {
      stopwatch.stop();
      await errors.cancel();
    }
  }

  Future<(int, int)> _waitForVideoDimensions() async {
    int? width;
    int? height;
    final completer = Completer<(int, int)>();
    void completeWhenReady() {
      if (width != null &&
          height != null &&
          width! > 0 &&
          height! > 0 &&
          !completer.isCompleted) {
        completer.complete((width!, height!));
      }
    }

    final widthSubscription = player.stream.width.listen((value) {
      width = value;
      completeWhenReady();
    });
    final heightSubscription = player.stream.height.listen((value) {
      height = value;
      completeWhenReady();
    });
    try {
      return await completer.future;
    } finally {
      await widthSubscription.cancel();
      await heightSubscription.cancel();
    }
  }

  Future<List<int>?> _captureScreenshot() async {
    try {
      return await player.screenshot(format: 'image/png');
    } catch (_) {
      throw const ProbeRequestException(ProbeFailure.screenshotUnavailable);
    }
  }

  Future<void> dispose() async {
    await player.dispose();
  }
}

bool _asBool(Object? value) => value == true || value == 1 || value == '1';

int? _asNonNegativeInt(Object? value) {
  final parsed = switch (value) {
    int value => value,
    String value => int.tryParse(value.trim()),
    _ => null,
  };
  return parsed != null && parsed >= 0 ? parsed : null;
}

String _normalizeStatus(Object? value) {
  final status = _asString(value)?.toLowerCase();
  return switch (status) {
    'active' => 'active',
    'expired' => 'expired',
    'disabled' => 'disabled',
    'banned' => 'banned',
    _ => 'unknown',
  };
}

String? _asString(Object? value) {
  final string = switch (value) {
    String value => value.trim(),
    int value => value.toString(),
    _ => null,
  };
  return string == null || string.isEmpty ? null : string;
}
