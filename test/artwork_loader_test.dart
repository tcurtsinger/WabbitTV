import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/artwork/artwork_loader.dart';
import 'package:wabbit_tv/src/features/artwork/source_artwork.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  late Directory cache;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('wabbit-artwork-test-');
  });

  tearDown(() async {
    if (await cache.exists()) await cache.delete(recursive: true);
  });

  test('accepts only absolute HTTP(S) source locators', () {
    final loader = ArtworkLoader(cacheDirectory: () async => cache);
    addTearDown(loader.close);

    expect(loader.supportedUri('https://art.example/channel.png'), isNotNull);
    expect(loader.supportedUri('http://art.example/channel.png'), isNotNull);
    expect(loader.supportedUri('/channel.png'), isNull);
    expect(loader.supportedUri('file:///channel.png'), isNull);
    expect(loader.supportedUri('data:image/png;base64,AA=='), isNull);
  });

  testWidgets(
    'passive scrolling is network-inert and focus dwell cancels rapid traversal',
    (tester) async {
      final loader = _FakeArtworkProvider(
        focusDwell: const Duration(milliseconds: 60),
      );
      String locator(String name) => 'https://art.example/$name';

      await tester.pumpWidget(
        MaterialApp(
          home: ListView.builder(
            itemCount: 80,
            itemExtent: 48,
            itemBuilder: (_, index) => SourceArtwork(
              locator: locator('passive-$index'),
              kind: SourceMediaKind.live,
              loader: loader,
            ),
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pump(const Duration(milliseconds: 100));
      expect(loader.paths, isEmpty);

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SourceArtwork(
              key: const ValueKey('art'),
              locator: locator('first'),
              kind: SourceMediaKind.movies,
              loader: loader,
              focused: true,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SourceArtwork(
              key: const ValueKey('art'),
              locator: locator('second'),
              kind: SourceMediaKind.movies,
              loader: loader,
              focused: true,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 90));
      await tester.pump();
      await tester.pump();

      expect(loader.paths, ['/second']);
      expect(
        tester.getSize(find.byKey(const ValueKey('art'))),
        const Size(50, 36),
      );
      await tester.pumpAndSettle();
      expect(loader.evictedPaths, contains('/second'));
    },
  );

  testWidgets('mounted virtual rows opt in to artwork without click or focus', (
    tester,
  ) async {
    final loader = _FakeArtworkProvider(
      focusDwell: const Duration(milliseconds: 40),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            for (var index = 0; index < 4; index++)
              SourceArtwork(
                key: ValueKey('visible-art-$index'),
                locator: 'https://art.example/visible-$index',
                kind: SourceMediaKind.series,
                loader: loader,
                loadWhenVisible: true,
              ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(loader.paths, isEmpty);

    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump();

    expect(loader.paths, [
      '/visible-0',
      '/visible-1',
      '/visible-2',
      '/visible-3',
    ]);
  });

  testWidgets('expanded artwork omits non-finite decode cache dimensions', (
    tester,
  ) async {
    final loader = _FakeArtworkProvider(focusDwell: Duration.zero);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 172,
          height: 180,
          child: Stack(
            children: [
              Positioned.fill(
                child: SourceArtwork(
                  locator: 'https://art.example/expanded',
                  kind: SourceMediaKind.movies,
                  loader: loader,
                  explicitlyActivated: true,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  test(
    'coalesces requests and reuses a sanitized bounded file cache',
    () async {
      var requests = 0;
      Future<Uint8List?> fetch(
        Uri uri,
        Duration deadline,
        int maximumBodyBytes,
        Future<void> cancelled,
      ) async {
        requests++;
        return Uint8List.fromList([requests, 2, 3, 4]);
      }

      final loader = ArtworkLoader(
        cacheDirectory: () async => cache,
        fetch: fetch,
        maximumCacheEntries: 1,
        maximumCacheBytes: 64,
        maximumBodyBytes: 32,
      );
      addTearDown(loader.close);
      const root = 'https://art.example';

      final first = loader.load('$root/private/channel?token=secret')!;
      final joined = loader.load('$root/private/channel?token=secret')!;
      final results = await Future.wait([first.bytes, joined.bytes]);
      expect(requests, 1);
      expect(results[0], results[1]);
      expect(
        await loader.cached('$root/private/channel?token=secret'),
        results[0],
      );

      await loader.load('$root/second')!.bytes;
      final files = await cache
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.art'))
          .cast<File>()
          .toList();
      expect(files, hasLength(1));
      expect(
        files.single.uri.pathSegments.last,
        matches(RegExp(r'^[a-f0-9]{64}\.art$')),
      );
      expect(files.single.path, isNot(contains('secret')));
      expect(files.single.path, isNot(contains('channel')));
    },
  );

  test(
    'passive cache misses share one directory index without file probes',
    () async {
      var directoryLookups = 0;
      final loader = ArtworkLoader(
        cacheDirectory: () async {
          directoryLookups++;
          return cache;
        },
      );
      addTearDown(loader.close);

      final misses = await Future.wait([
        for (var index = 0; index < 500; index++)
          loader.cached('https://art.example/missing-$index'),
      ]);

      expect(misses.where((bytes) => bytes != null), isEmpty);
      expect(directoryLookups, 1);
    },
  );

  test('same URL is fetched again after the bounded cache age', () async {
    var requests = 0;
    final loader = ArtworkLoader(
      cacheDirectory: () async => cache,
      maximumCacheAge: const Duration(days: 1),
      fetch: (uri, deadline, maximumBodyBytes, cancelled) async {
        requests++;
        return Uint8List.fromList([requests]);
      },
    );
    addTearDown(loader.close);
    const locator = 'https://art.example/reused-logo';

    expect(await loader.load(locator)!.bytes, [1]);
    final file = await cache
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .single;
    await file.setLastModified(
      DateTime.now().subtract(const Duration(days: 2)),
    );

    expect(await loader.load(locator)!.bytes, [2]);
    expect(requests, 2);
  });

  test(
    'limits concurrency and removes oversized or failed partial work',
    () async {
      var active = 0;
      var peak = 0;
      final gates = <String, Completer<void>>{
        '/one': Completer<void>(),
        '/two': Completer<void>(),
        '/three': Completer<void>(),
      };
      Future<Uint8List?> fetch(
        Uri uri,
        Duration deadline,
        int maximumBodyBytes,
        Future<void> cancelled,
      ) async {
        if (gates.containsKey(uri.path)) {
          active++;
          peak = active > peak ? active : peak;
          var wasCancelled = false;
          await Future.any<void>([
            gates[uri.path]!.future,
            cancelled.then((_) => wasCancelled = true),
          ]);
          active--;
          return wasCancelled ? null : Uint8List.fromList(const [1, 2, 3]);
        }
        if (uri.path == '/oversized') {
          return Uint8List.fromList(List<int>.filled(80, 1));
        }
        return null;
      }

      final loader = ArtworkLoader(
        cacheDirectory: () async => cache,
        fetch: fetch,
        maximumConcurrent: 2,
        maximumBodyBytes: 32,
        maximumCacheBytes: 128,
        requestDeadline: const Duration(seconds: 2),
      );
      addTearDown(loader.close);
      const root = 'https://art.example';

      final one = loader.load('$root/one')!;
      final two = loader.load('$root/two')!;
      final three = loader.load('$root/three')!;
      await _waitFor(() => peak == 2);
      expect(active, 2);
      gates['/one']!.complete();
      await _waitFor(() => active == 2 && gates['/one']!.isCompleted);
      gates['/two']!.complete();
      gates['/three']!.complete();
      await Future.wait([one.bytes, two.bytes, three.bytes]);
      expect(peak, 2);

      expect(await loader.load('$root/oversized')!.bytes, isNull);
      expect(await loader.load('$root/failure')!.bytes, isNull);
      final partials = await cache
          .list()
          .where(
            (entity) =>
                entity is File &&
                (entity.path.endsWith('.tmp') || entity.path.endsWith('.part')),
          )
          .toList();
      expect(partials, isEmpty);
    },
  );

  test(
    'cancels an unobserved active download without leaving cache work',
    () async {
      var started = 0;
      var cancelled = 0;
      Future<Uint8List?> fetch(
        Uri uri,
        Duration deadline,
        int maximumBodyBytes,
        Future<void> cancellation,
      ) async {
        started++;
        await cancellation;
        cancelled++;
        return null;
      }

      final loader = ArtworkLoader(
        cacheDirectory: () async => cache,
        fetch: fetch,
        maximumConcurrent: 1,
      );
      addTearDown(loader.close);
      final request = loader.load('https://art.example/slow')!;
      await _waitFor(() => started == 1);
      request.cancel();

      expect(await request.bytes, isNull);
      await _waitFor(() => cancelled == 1);
      expect(await cache.list().toList(), isEmpty);
    },
  );

  test('applies one absolute deadline to stalled transport work', () async {
    var cancelled = false;
    Future<Uint8List?> fetch(
      Uri uri,
      Duration deadline,
      int maximumBodyBytes,
      Future<void> cancellation,
    ) async {
      await cancellation;
      cancelled = true;
      return null;
    }

    final loader = ArtworkLoader(
      cacheDirectory: () async => cache,
      fetch: fetch,
      requestDeadline: const Duration(milliseconds: 30),
    );
    addTearDown(loader.close);

    expect(await loader.load('https://art.example/stalled')!.bytes, isNull);
    await _waitFor(() => cancelled);
    expect(await cache.list().toList(), isEmpty);
  });
}

class _FakeArtworkProvider implements ArtworkProvider {
  _FakeArtworkProvider({required this.focusDwell});

  @override
  final Duration focusDwell;
  final List<String> paths = [];
  final List<String> evictedPaths = [];

  @override
  Future<Uint8List?> cached(String? locator) async => null;

  @override
  Future<void> evict(String? locator) async {
    evictedPaths.add(Uri.parse(locator!).path);
  }

  @override
  ArtworkRequest? load(String? locator) {
    final uri = Uri.tryParse(locator ?? '');
    if (uri == null || !uri.isAbsolute) return null;
    paths.add(uri.path);
    return ArtworkRequest(
      Future<Uint8List?>.value(Uint8List.fromList(const [1, 2, 3, 4])),
      () {},
    );
  }
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
