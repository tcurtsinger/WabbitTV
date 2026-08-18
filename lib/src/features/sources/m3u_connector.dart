import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'source_models.dart';
import 'xtream_connector.dart';

/// A deliberately small acquisition and parsing boundary for M3U sources.
///
/// Call it from the import worker. It returns only live catalog records: M3U
/// does not reliably distinguish movies or series from live channels.
class M3uConnector {
  const M3uConnector({
    this.maxBytes = 64 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 120),
  });

  final int maxBytes;
  final Duration requestTimeout;

  Future<ImportedStage> importUrl({
    required Uri url,
    required String sourceId,
    bool Function()? isCancelled,
    HttpClient? httpClient,
  }) async {
    _throwIfCancelled(isCancelled);
    final client = httpClient ?? HttpClient();
    final ownsClient = httpClient == null;
    try {
      final request = await client.getUrl(url).timeout(requestTimeout);
      _throwIfCancelled(isCancelled);
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const SourceImportFailure(SourceImportFailureKind.unreachable);
      }
      return parseBytes(
        await _readBounded(response, isCancelled),
        sourceId: sourceId,
        baseUri: url,
        isCancelled: isCancelled,
      );
    } on SourceImportFailure {
      rethrow;
    } on SocketException {
      _throwIfCancelled(isCancelled);
      throw const SourceImportFailure(SourceImportFailureKind.unreachable);
    } on HttpException {
      _throwIfCancelled(isCancelled);
      throw const SourceImportFailure(SourceImportFailureKind.unreachable);
    } on TimeoutException {
      _throwIfCancelled(isCancelled);
      throw const SourceImportFailure(SourceImportFailureKind.timedOut);
    } catch (_) {
      _throwIfCancelled(isCancelled);
      throw const SourceImportFailure(SourceImportFailureKind.unreachable);
    } finally {
      if (ownsClient) {
        client.close(force: true);
      }
    }
  }

  Future<ImportedStage> importFile({
    required String path,
    required String sourceId,
    bool Function()? isCancelled,
  }) async {
    _throwIfCancelled(isCancelled);
    try {
      final file = File(path);
      if (await file.length() > maxBytes) {
        throw const SourceImportFailure(SourceImportFailureKind.tooLarge);
      }
      return parseBytes(
        await _readBounded(file.openRead(), isCancelled),
        sourceId: sourceId,
        isCancelled: isCancelled,
      );
    } on SourceImportFailure {
      rethrow;
    } on FileSystemException {
      throw const SourceImportFailure(SourceImportFailureKind.unreachable);
    } catch (_) {
      throw const SourceImportFailure(SourceImportFailureKind.unreachable);
    }
  }

  ImportedStage parseBytes(
    List<int> bytes, {
    required String sourceId,
    Uri? baseUri,
    bool Function()? isCancelled,
  }) {
    _throwIfCancelled(isCancelled);
    if (bytes.length > maxBytes) {
      throw const SourceImportFailure(SourceImportFailureKind.tooLarge);
    }
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const SourceImportFailure(SourceImportFailureKind.emptyResponse);
    }

    final categories = <String, ImportedCategory>{};
    final items = <ImportedCatalogItem>[];
    final providerKeys = <String>{};
    _Entry? pending;
    for (final rawLine in const LineSplitter().convert(text)) {
      _throwIfCancelled(isCancelled);
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF:')) {
        pending = _Entry.fromExtInf(line);
        continue;
      }
      if (line.startsWith('#')) {
        pending?.applyDirective(line);
        continue;
      }
      if (pending == null) continue;
      final entry = pending;
      pending = null;
      final locator = _resolveLocator(line, baseUri);
      if (locator == null || entry.title.isEmpty) continue;

      final categoryName = entry.groupTitle;
      final categoryKey = categoryName == null
          ? null
          : 'm3u:$sourceId:group:${_digest(categoryName.toLowerCase())}';
      if (categoryName != null) {
        categories.putIfAbsent(
          categoryKey!,
          () => ImportedCategory(providerKey: categoryKey, name: categoryName),
        );
      }
      final providerKey = entry.tvgId?.isNotEmpty == true
          ? 'm3u:$sourceId:tvg:${entry.tvgId}'
          : 'm3u:$sourceId:item:${_digest(_canonical(entry, locator))}';
      if (!providerKeys.add(providerKey)) continue;
      items.add(
        ImportedCatalogItem(
          providerKey: providerKey,
          title: entry.title,
          categoryKey: categoryKey,
          playbackRef: playbackReference({
            'url': locator,
            if (entry.headers.isNotEmpty) 'headers': entry.headers,
          }),
          artworkLocator: entry.tvgLogo,
        ),
      );
    }
    if (items.isEmpty) {
      throw const SourceImportFailure(SourceImportFailureKind.emptyResponse);
    }
    return ImportedStage(
      kind: SourceMediaKind.live,
      categories: categories.values.toList(growable: false),
      items: items,
    );
  }

  Future<Uint8List> _readBounded(
    Stream<List<int>> stream,
    bool Function()? isCancelled,
  ) async {
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in stream.timeout(requestTimeout)) {
        _throwIfCancelled(isCancelled);
        if (bytes.length + chunk.length > maxBytes) {
          throw const SourceImportFailure(SourceImportFailureKind.tooLarge);
        }
        bytes.add(chunk);
      }
    } on SourceImportFailure {
      rethrow;
    } on TimeoutException {
      _throwIfCancelled(isCancelled);
      throw const SourceImportFailure(SourceImportFailureKind.timedOut);
    }
    _throwIfCancelled(isCancelled);
    return bytes.takeBytes();
  }

  void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) {
      throw const SourceImportFailure(SourceImportFailureKind.cancelled);
    }
  }
}

class _Entry {
  _Entry({required this.title, this.groupTitle, this.tvgId, this.tvgLogo});

  factory _Entry.fromExtInf(String line) {
    final payload = line.substring('#EXTINF:'.length);
    final comma = _attributeComma(payload);
    final attributes = comma < 0 ? payload : payload.substring(0, comma);
    final suppliedTitle = comma < 0 ? '' : payload.substring(comma + 1).trim();
    final values = _attributes(attributes);
    final tvgName = values['tvg-name']?.trim();
    return _Entry(
      title: suppliedTitle.isNotEmpty ? suppliedTitle : (tvgName ?? ''),
      groupTitle: _nonEmpty(values['group-title']),
      tvgId: _nonEmpty(values['tvg-id']),
      tvgLogo: _nonEmpty(values['tvg-logo']),
    );
  }

  String title;
  final String? groupTitle;
  final String? tvgId;
  final String? tvgLogo;
  final Map<String, String> headers = {};

  void applyDirective(String line) {
    // Keep only the common per-item HTTP directives. Unknown comments are not
    // interpreted as headers, so they cannot accidentally affect playback.
    if (line.startsWith('#EXTVLCOPT:http-user-agent=')) {
      _putHeader(
        'User-Agent',
        line.substring('#EXTVLCOPT:http-user-agent='.length),
      );
    } else if (line.startsWith('#EXTVLCOPT:http-referrer=')) {
      _putHeader('Referer', line.substring('#EXTVLCOPT:http-referrer='.length));
    } else if (line.startsWith(
      '#KODIPROP:inputstream.adaptive.stream_headers=',
    )) {
      _parseHeaderList(
        line.substring('#KODIPROP:inputstream.adaptive.stream_headers='.length),
      );
    }
  }

  void _parseHeaderList(String value) {
    for (final segment in value.split('&')) {
      final separator = segment.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      final name = Uri.decodeComponent(segment.substring(0, separator)).trim();
      final headerValue = Uri.decodeComponent(segment.substring(separator + 1))
          .trim();
      if (_isSafeHeaderName(name) && headerValue.isNotEmpty) {
        headers[name] = headerValue;
      }
    }
  }

  void _putHeader(String name, String value) {
    value = value.trim();
    if (value.isNotEmpty) headers[name] = value;
  }
}

Map<String, String> _attributes(String value) {
  final result = <String, String>{};
  final expression = RegExp(
    r'''([A-Za-z0-9_-]+)=(?:"([^"]*)"|'([^']*)'|([^\s,]+))''',
  );
  for (final match in expression.allMatches(value)) {
    result[match.group(1)!.toLowerCase()] =
        match.group(2) ?? match.group(3) ?? match.group(4) ?? '';
  }
  return result;
}

int _attributeComma(String value) {
  var quote = '';
  for (var index = 0; index < value.length; index++) {
    final character = value[index];
    if ((character == '"' || character == "'") &&
        (quote.isEmpty || quote == character)) {
      quote = quote.isEmpty ? character : '';
    } else if (character == ',' && quote.isEmpty) {
      return index;
    }
  }
  return -1;
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String? _resolveLocator(String value, Uri? baseUri) {
  final parsed = Uri.tryParse(value);
  if (parsed == null) return null;
  final resolved = parsed.hasScheme ? parsed : baseUri?.resolveUri(parsed);
  if (resolved == null || !resolved.hasScheme || resolved.scheme == 'file') {
    return null;
  }
  return resolved.toString();
}

bool _isSafeHeaderName(String value) =>
    RegExp(r'^[A-Za-z0-9-]+$').hasMatch(value);

String _canonical(_Entry entry, String locator) =>
    '${entry.title}\n${entry.groupTitle ?? ''}\n$locator';

String _digest(String value) {
  // A 64-bit FNV-1a digest keeps provider identity compact without retaining
  // a locator or headers outside playback_ref.
  var hash = BigInt.parse('14695981039346656037');
  const prime = 1099511628211;
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final unit in utf8.encode(value)) {
    hash ^= BigInt.from(unit);
    hash = (hash * BigInt.from(prime)) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
