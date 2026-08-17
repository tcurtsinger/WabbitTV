import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../sources/credential_store.dart';
import '../sources/source_catalog_database.dart';
import '../sources/source_models.dart';
import 'playback_handoff.dart';

const seriesInfoRequestTimeout = Duration(seconds: 60);
const seriesInfoResponseByteLimit = 4 * 1024 * 1024;

abstract interface class SeriesInfoLoader {
  Future<SeriesInfo> load({
    required PersistedSource source,
    required BrowseCatalogItem series,
  });

  void cancel();
}

class XtreamSeriesInfoLoader implements SeriesInfoLoader {
  XtreamSeriesInfoLoader({
    CredentialStore? credentialStore,
    HttpClient Function()? clientFactory,
  }) : _credentialStore = credentialStore ?? SecureCredentialStore(),
       _clientFactory = clientFactory ?? HttpClient.new;

  final CredentialStore _credentialStore;
  final HttpClient Function() _clientFactory;
  HttpClient? _activeClient;
  int _operation = 0;

  @override
  void cancel() {
    ++_operation;
    _activeClient?.close(force: true);
    _activeClient = null;
  }

  @override
  Future<SeriesInfo> load({
    required PersistedSource source,
    required BrowseCatalogItem series,
  }) async {
    final reference = seriesReferenceFor(series);
    final operation = ++_operation;
    StoredCredential? credential;
    HttpClient? client;
    try {
      credential = await _credentialStore.read(source.credentialKey);
      if (operation != _operation) {
        throw const ContinuationException(ContinuationFailure.cancelled);
      }
      final serverUrl = credential?.serverUrl;
      if (credential == null || serverUrl == null || serverUrl.isEmpty) {
        throw const ContinuationException(
          ContinuationFailure.credentialsUnavailable,
        );
      }
      final endpoint = _playerApi(serverUrl);
      client = _clientFactory();
      _activeClient = client;
      if (operation != _operation) {
        throw const ContinuationException(ContinuationFailure.cancelled);
      }
      final request = await client
          .getUrl(
            endpoint.replace(
              queryParameters: {
                'username': credential.username,
                'password': credential.password,
                'action': 'get_series_info',
                'series_id': reference.providerItemId,
              },
            ),
          )
          .timeout(seriesInfoRequestTimeout);
      final response = await request.close().timeout(seriesInfoRequestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const ContinuationException(ContinuationFailure.unavailable);
      }
      final bytes = await _readBounded(response)
          .timeout(seriesInfoRequestTimeout);
      final info = await parseSeriesInfoBytesInWorker(bytes);
      if (operation != _operation) {
        throw const ContinuationException(ContinuationFailure.cancelled);
      }
      return info;
    } on ContinuationException {
      rethrow;
    } on TimeoutException {
      throw const ContinuationException(ContinuationFailure.timedOut);
    } on _SeriesResponseTooLarge {
      throw const ContinuationException(ContinuationFailure.responseTooLarge);
    } on FormatException {
      throw const ContinuationException(ContinuationFailure.malformedResponse);
    } catch (_) {
      throw const ContinuationException(ContinuationFailure.unavailable);
    } finally {
      client?.close(force: true);
      if (identical(_activeClient, client)) _activeClient = null;
      // Credential data deliberately has no instance field and falls out of
      // scope with this explicit, one-request operation.
      credential = null;
    }
  }
}

Uri _playerApi(String serverUrl) {
  final base = Uri.tryParse(serverUrl);
  if (base == null ||
      (base.scheme != 'http' && base.scheme != 'https') ||
      base.host.isEmpty) {
    throw const ContinuationException(
      ContinuationFailure.credentialsUnavailable,
    );
  }
  final path = base.path.replaceFirst(RegExp(r'/+$'), '');
  return base.replace(
    path: '$path/player_api.php',
    query: null,
    fragment: null,
  );
}

/// Decoding, JSON parsing, and episode mapping can be sizeable for a provider's
/// series response. Keep that bounded work out of the caller/UI isolate.
Future<SeriesInfo> parseSeriesInfoBytesInWorker(Uint8List bytes) {
  return Isolate.run(() => _decodeSeriesInfo(bytes));
}

SeriesInfo _decodeSeriesInfo(Uint8List bytes) {
  return parseSeriesInfo(jsonDecode(utf8.decode(bytes)));
}

Future<Uint8List> _readBounded(HttpClientResponse response) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response) {
    if (bytes.length + chunk.length > seriesInfoResponseByteLimit) {
      throw const _SeriesResponseTooLarge();
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

SeriesInfo parseSeriesInfo(Object? raw) {
  if (raw is! Map || raw['episodes'] is! Map) {
    throw const FormatException();
  }
  final seasons = <SeriesSeason>[];
  for (final entry in (raw['episodes'] as Map).entries) {
    if (entry.key is! String || entry.value is! List) continue;
    final episodes = <SeriesEpisode>[];
    for (final rawEpisode in entry.value as List) {
      if (rawEpisode is! Map) continue;
      final id = rawEpisode['id'];
      final title = rawEpisode['title'] ?? rawEpisode['name'];
      final extension = rawEpisode['container_extension'];
      if (id is! String && id is! num) continue;
      if (title is! String || title.trim().isEmpty) continue;
      if (extension != null &&
          (extension is! String || extension.trim().isEmpty)) {
        continue;
      }
      episodes.add(
        SeriesEpisode(
          providerItemId: '$id',
          title: title,
          extension: (extension as String?) ?? 'mp4',
        ),
      );
    }
    seasons.add(SeriesSeason(name: entry.key as String, episodes: episodes));
  }
  seasons.sort((a, b) => _seasonOrder(a.name).compareTo(_seasonOrder(b.name)));
  return SeriesInfo(seasons: List.unmodifiable(seasons));
}

int _seasonOrder(String name) => int.tryParse(name) ?? 1 << 30;

class _SeriesResponseTooLarge implements Exception {
  const _SeriesResponseTooLarge();
}
