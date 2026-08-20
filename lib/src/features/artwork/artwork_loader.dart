import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

typedef ArtworkCacheDirectory = Future<Directory> Function();
typedef ArtworkFetch = Future<Uint8List?> Function(
  Uri uri,
  Duration deadline,
  int maximumBodyBytes,
  Future<void> cancelled,
);

abstract interface class ArtworkProvider {
  Duration get focusDwell;

  Future<Uint8List?> cached(String? locator);

  ArtworkRequest? load(String? locator);

  Future<void> evict(String? locator);
}

/// Small, source-only artwork pipeline for the catalog's fixed thumbnails.
///
/// Reading [cached] never starts a network request. Network work begins only
/// through [load], which the widget calls after a bounded mounted-row/focus
/// dwell or an explicit continuation activation.
class ArtworkLoader implements ArtworkProvider {
  ArtworkLoader({
    ArtworkCacheDirectory? cacheDirectory,
    ArtworkFetch? fetch,
    this.focusDwell = const Duration(milliseconds: 160),
    this.requestDeadline = const Duration(seconds: 5),
    this.maximumBodyBytes = 2 * 1024 * 1024,
    this.maximumCacheBytes = 12 * 1024 * 1024,
    this.maximumCacheEntries = 160,
    this.maximumCacheAge = const Duration(days: 7),
    int maximumConcurrent = 2,
  }) : assert(maximumBodyBytes > 0),
       assert(maximumCacheBytes >= maximumBodyBytes),
       assert(maximumCacheEntries > 0),
       assert(maximumCacheAge > Duration.zero),
       maximumConcurrent = maximumConcurrent < 1
           ? 1
           : (maximumConcurrent > 2 ? 2 : maximumConcurrent),
       _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory,
       _fetch = fetch ?? _fetchHttpArtwork;

  final ArtworkCacheDirectory _cacheDirectory;
  final ArtworkFetch _fetch;
  @override
  final Duration focusDwell;
  final Duration requestDeadline;
  final int maximumBodyBytes;
  final int maximumCacheBytes;
  final int maximumCacheEntries;
  final Duration maximumCacheAge;
  final int maximumConcurrent;

  final Map<String, _ArtworkOperation> _operations = {};
  final List<_ArtworkOperation> _waiting = [];
  int _active = 0;
  bool _closed = false;
  Future<Directory>? _directoryFuture;
  Future<Set<String>>? _cacheIndexFuture;
  Set<String>? _cacheKeys;

  static Future<Directory> _defaultCacheDirectory() async {
    final root = await getApplicationCacheDirectory();
    return Directory(_join(root.path, 'artwork'));
  }

  /// Returns a valid source artwork URI, or null for missing/unsupported input.
  Uri? supportedUri(String? locator) {
    if (locator == null || locator.trim().isEmpty) return null;
    final uri = Uri.tryParse(locator.trim());
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri;
  }

  /// Reads only the bounded application cache. It never falls through to HTTP.
  @override
  Future<Uint8List?> cached(String? locator) async {
    final uri = supportedUri(locator);
    if (uri == null || _closed) return null;
    return _readCache(_cacheKey(uri));
  }

  /// Starts or joins one bounded request for a supported source locator.
  @override
  ArtworkRequest? load(String? locator) {
    final uri = supportedUri(locator);
    if (uri == null || _closed) return null;
    final key = _cacheKey(uri);
    final operation = _operations.putIfAbsent(key, () {
      final created = _ArtworkOperation(key: key, uri: uri);
      _waiting.add(created);
      scheduleMicrotask(_drain);
      return created;
    });
    operation.listeners++;
    var cancelled = false;
    return ArtworkRequest(operation.completer.future, () {
      if (cancelled) return;
      cancelled = true;
      operation.listeners--;
      if (operation.listeners == 0) _cancelUnobserved(operation);
    });
  }

  /// Removes bytes that failed Flutter image decoding.
  @override
  Future<void> evict(String? locator) async {
    final uri = supportedUri(locator);
    if (uri == null) return;
    try {
      final directory = await _directory();
      final file = File(_join(directory.path, '${_cacheKey(uri)}.art'));
      if (await file.exists()) await file.delete();
      _cacheKeys?.remove(_cacheKey(uri));
    } catch (_) {
      // Artwork cache cleanup must never make the catalog unusable.
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final operation in [..._operations.values]) {
      operation.cancel();
      _finish(operation, null);
    }
    _waiting.clear();
  }

  String _cacheKey(Uri uri) =>
      sha256.convert(uri.toString().codeUnits).toString();

  Future<Directory> _directory() => _directoryFuture ??= _prepareDirectory();

  Future<Directory> _prepareDirectory() async {
    final directory = await _cacheDirectory();
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<Set<String>> _indexedKeys() async {
    final cached = _cacheKeys;
    if (cached != null) return cached;
    final pending = _cacheIndexFuture ??= _loadCacheIndex();
    return pending;
  }

  Future<Set<String>> _loadCacheIndex() async {
    final keys = <String>{};
    try {
      final directory = await _directory();
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.endsWith('.art')) continue;
        final separator = entity.path.lastIndexOf(Platform.pathSeparator);
        final name = entity.path.substring(separator + 1);
        keys.add(name.substring(0, name.length - 4));
      }
    } catch (_) {}
    _cacheKeys = keys;
    return keys;
  }

  Future<Uint8List?> _readCache(String key) async {
    try {
      final keys = await _indexedKeys();
      if (!keys.contains(key)) return null;
      final directory = await _directory();
      final file = File(_join(directory.path, '$key.art'));
      if (!await file.exists()) {
        keys.remove(key);
        return null;
      }
      final stat = await file.stat();
      final length = stat.size;
      if (length <= 0 || length > maximumBodyBytes) {
        await file.delete();
        keys.remove(key);
        return null;
      }
      if (DateTime.now().difference(stat.modified) > maximumCacheAge) {
        await file.delete();
        keys.remove(key);
        return null;
      }
      final bytes = await file.readAsBytes();
      return bytes;
    } catch (_) {
      return null;
    }
  }

  void _cancelUnobserved(_ArtworkOperation operation) {
    if (operation.started) {
      operation.cancel();
    } else {
      _waiting.remove(operation);
    }
    _finish(operation, null);
  }

  void _drain() {
    while (!_closed && _active < maximumConcurrent && _waiting.isNotEmpty) {
      final operation = _waiting.removeAt(0);
      if (operation.completed || operation.listeners == 0) continue;
      operation.started = true;
      _active++;
      unawaited(
        _run(operation).whenComplete(() {
          _active--;
          _drain();
        }),
      );
    }
  }

  Future<void> _run(_ArtworkOperation operation) async {
    final cachedBytes = await _readCache(operation.key);
    if (operation.completed) return;
    if (cachedBytes != null) {
      _finish(operation, cachedBytes);
      return;
    }
    if (operation.listeners == 0 || _closed) {
      _finish(operation, null);
      return;
    }

    try {
      // Reify the nullable result type before applying timeout. Test and
      // injected fetchers may return a covariant Future<Uint8List> at runtime;
      // calling timeout on that object would reject a null timeout result.
      final pending = _fetch(
        operation.uri,
        requestDeadline,
        maximumBodyBytes,
        operation.cancelled.future,
      ).then<Uint8List?>((bytes) => bytes);
      final downloaded = await pending.timeout(
        requestDeadline,
        onTimeout: () {
          operation.cancel();
          return null;
        },
      );
      if (operation.completed) return;
      if (downloaded == null ||
          downloaded.isEmpty ||
          downloaded.length > maximumBodyBytes ||
          operation.listeners == 0 ||
          _closed) {
        _finish(operation, null);
        return;
      }
      final stored = await _writeCache(operation.key, downloaded);
      _finish(operation, stored ? downloaded : null);
    } catch (_) {
      _finish(operation, null);
    }
  }

  static Future<Uint8List?> _fetchHttpArtwork(
    Uri uri,
    Duration deadlineDuration,
    int maximumBodyBytes,
    Future<void> cancelled,
  ) async {
    final client = HttpClient()..autoUncompress = true;
    HttpClientRequest? request;
    StreamSubscription<List<int>>? responseSubscription;
    final done = Completer<Uint8List?>();
    final bytes = BytesBuilder(copy: false);
    var received = 0;

    void fail() {
      if (!done.isCompleted) done.complete(null);
    }

    final deadline = Timer(deadlineDuration, () {
      request?.abort();
      responseSubscription?.cancel();
      client.close(force: true);
      fail();
    });
    unawaited(
      cancelled.then((_) {
        request?.abort();
        responseSubscription?.cancel();
        client.close(force: true);
        fail();
      }),
    );

    try {
      request = await client.getUrl(uri);
      final response = await request.close();
      final advertised = response.contentLength;
      if (response.statusCode != HttpStatus.ok ||
          advertised > maximumBodyBytes) {
        fail();
      } else {
        responseSubscription = response.listen(
          (chunk) {
            received += chunk.length;
            if (received > maximumBodyBytes) {
              request?.abort();
              responseSubscription?.cancel();
              fail();
            } else {
              bytes.add(chunk);
            }
          },
          onError: (_) => fail(),
          onDone: () {
            if (!done.isCompleted) {
              done.complete(received == 0 ? null : bytes.takeBytes());
            }
          },
          cancelOnError: true,
        );
      }
      return await done.future;
    } catch (_) {
      return null;
    } finally {
      deadline.cancel();
      await responseSubscription?.cancel();
      client.close(force: true);
    }
  }

  Future<bool> _writeCache(String key, Uint8List bytes) async {
    File? temporary;
    try {
      final directory = await _directory();
      final target = File(_join(directory.path, '$key.art'));
      temporary = File(_join(directory.path, '$key.tmp'));
      await temporary.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
      (await _indexedKeys()).add(key);
      await _trim(directory);
      return true;
    } catch (_) {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } catch (_) {}
      return false;
    }
  }

  Future<void> _trim(Directory directory) async {
    final entries = <({File file, DateTime modified, int size})>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.art')) continue;
      try {
        final stat = await entity.stat();
        entries.add((file: entity, modified: stat.modified, size: stat.size));
      } catch (_) {}
    }
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    var total = entries.fold<int>(0, (sum, entry) => sum + entry.size);
    while (entries.length > maximumCacheEntries || total > maximumCacheBytes) {
      final oldest = entries.removeAt(0);
      try {
        await oldest.file.delete();
        final name = oldest.file.path.substring(
          oldest.file.path.lastIndexOf(Platform.pathSeparator) + 1,
        );
        _cacheKeys?.remove(name.substring(0, name.length - 4));
      } catch (_) {}
      total -= oldest.size;
    }
  }

  void _finish(_ArtworkOperation operation, Uint8List? value) {
    if (operation.completed) return;
    operation.completed = true;
    _waiting.remove(operation);
    if (identical(_operations[operation.key], operation)) {
      _operations.remove(operation.key);
    }
    if (!operation.completer.isCompleted) operation.completer.complete(value);
  }

  static String _join(String directory, String name) =>
      '$directory${Platform.pathSeparator}$name';
}

class ArtworkRequest {
  ArtworkRequest(this.bytes, this._cancel);

  final Future<Uint8List?> bytes;
  final void Function() _cancel;

  void cancel() => _cancel();
}

class _ArtworkOperation {
  _ArtworkOperation({required this.key, required this.uri});

  final String key;
  final Uri uri;
  final Completer<Uint8List?> completer = Completer<Uint8List?>();
  final Completer<void> cancelled = Completer<void>();
  int listeners = 0;
  bool started = false;
  bool completed = false;

  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }
}
