import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/sources/m3u_connector.dart';
import 'package:wabbit_tv/src/features/sources/xtream_connector.dart';

void main() {
  const connector = M3uConnector(maxBytes: 1024);

  test(
    'parses live M3U metadata and keeps locator and headers in playback ref',
    () {
      final stage = connector.parseBytes(
        utf8.encode('''#EXTM3U
#EXTINF:-1 tvg-id="news.one" tvg-name="News One" tvg-logo="https://art.example/news.png" group-title="News",News One HD
#EXTVLCOPT:http-user-agent=Fixture Agent
#KODIPROP:inputstream.adaptive.stream_headers=Referer=https%3A%2F%2Fexample.test&X-Token=abc
https://stream.example/live/news
'''),
        sourceId: 'source-a',
      );

      expect(stage.kind.name, 'live');
      expect(stage.categories.single.name, 'News');
      expect(stage.items.single.providerKey, 'm3u:source-a:tvg:news.one');
      expect(stage.items.single.title, 'News One HD');
      expect(stage.items.single.artworkLocator, 'https://art.example/news.png');
      final ref =
          jsonDecode(stage.items.single.playbackRef) as Map<String, dynamic>;
      expect(ref['url'], 'https://stream.example/live/news');
      expect(ref['headers'], {
        'User-Agent': 'Fixture Agent',
        'Referer': 'https://example.test',
        'X-Token': 'abc',
      });
    },
  );

  test(
    'skips malformed entries and derives stable source-scoped identities',
    () {
      const playlist =
          '#EXTINF:-1 group-title="News",Valid\n'
          'https://stream.example/live/one\n'
          '#EXTINF:-1,Missing locator\n'
          '#EXTINF:-1,Bad locator\n'
          'not a locator\n'
          '# ignored\n'
          '#EXTINF:-1 tvg-name="Named fallback", \n'
          'https://stream.example/live/two\n';
      final first = connector.parseBytes(
        utf8.encode(playlist),
        sourceId: 'alpha',
      );
      final repeat = connector.parseBytes(
        utf8.encode(playlist),
        sourceId: 'alpha',
      );
      final otherSource = connector.parseBytes(
        utf8.encode(playlist),
        sourceId: 'beta',
      );

      expect(first.items, hasLength(2));
      expect(first.items.first.providerKey, repeat.items.first.providerKey);
      expect(
        first.items.first.providerKey,
        isNot(otherSource.items.first.providerKey),
      );
      expect(first.items.last.title, 'Named fallback');
    },
  );

  test('uses a stable 64-bit fallback identity for entries without tvg-id', () {
    const playlist = '''#EXTINF:-1,One
https://stream.example/one
#EXTINF:-1,Two
https://stream.example/two
''';
    final first = connector.parseBytes(
      utf8.encode(playlist),
      sourceId: 'alpha',
    );
    final repeat = connector.parseBytes(
      utf8.encode(playlist),
      sourceId: 'alpha',
    );

    final fallback = RegExp(r'^m3u:alpha:item:([0-9a-f]{16})$');
    expect(first.items, hasLength(2));
    expect(first.items[0].providerKey, matches(fallback));
    expect(first.items[0].providerKey, isNot(first.items[1].providerKey));
    expect(
      first.items.map((item) => item.providerKey),
      repeat.items.map((item) => item.providerKey),
    );
  });
  test('keeps the first usable duplicate tvg-id deterministically', () {
    final stage = connector.parseBytes(
      utf8.encode('''#EXTINF:-1 tvg-id="shared",First
https://stream.example/first
#EXTINF:-1 tvg-id="shared",Later
https://stream.example/later
'''),
      sourceId: 'source-a',
    );

    expect(stage.items, hasLength(1));
    expect(stage.items.single.title, 'First');
    expect(stage.items.single.providerKey, 'm3u:source-a:tvg:shared');
  });
  test('acquires M3U from loopback URL and local file', () async {
    const body = '#EXTINF:-1 tvg-id="one",One\nhttps://stream.example/one\n';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      request.response.write(body);
      await request.response.close();
    });
    final temp = await Directory.systemTemp.createTemp('wabbit-m3u-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}${Platform.pathSeparator}fixture.m3u');
    await file.writeAsString(body);

    final fromUrl = await connector.importUrl(
      url: Uri.parse(
        'http://${server.address.address}:${server.port}/fixture.m3u',
      ),
      sourceId: 'url-source',
    );
    final fromFile = await connector.importFile(
      path: file.path,
      sourceId: 'file-source',
    );
    expect(fromUrl.items.single.title, 'One');
    expect(fromFile.items.single.title, 'One');
  });

  test('resolves URL playlist entries relative to the playlist location', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      request.response.write(
        '#EXTINF:-1 tvg-id="relative",Relative\n'
        '../streams/channel.m3u8?ticket=fixture\n',
      );
      await request.response.close();
    });
    final base = Uri.parse(
      'http://${server.address.address}:${server.port}/lists/fixture.m3u',
    );

    final stage = await connector.importUrl(url: base, sourceId: 'url-source');
    final ref =
        jsonDecode(stage.items.single.playbackRef) as Map<String, dynamic>;

    expect(
      ref['url'],
      'http://${server.address.address}:${server.port}/streams/channel.m3u8?ticket=fixture',
    );
  });

  test('bounds, cancellation, and failures are redacted', () async {
    final tooSmall = M3uConnector(maxBytes: 8);
    expect(
      () => tooSmall.parseBytes(
        utf8.encode('#EXTINF:-1,One\nhttps://stream.example/one\n'),
        sourceId: 's',
      ),
      throwsA(
        isA<SourceImportFailure>().having(
          (error) => error.kind,
          'kind',
          SourceImportFailureKind.tooLarge,
        ),
      ),
    );
    expect(
      () => connector.parseBytes(
        utf8.encode('#EXTINF:-1,One\nhttps://secret.example/token\n'),
        sourceId: 's',
        isCancelled: () => true,
      ),
      throwsA(
        isA<SourceImportFailure>().having(
          (error) => error.kind,
          'kind',
          SourceImportFailureKind.cancelled,
        ),
      ),
    );
    expect(
      () => connector.parseBytes(
        utf8.encode('#EXTINF:-1,Broken\nnot-a-url\n'),
        sourceId: 's',
      ),
      throwsA(
        isA<SourceImportFailure>().having(
          (error) => error.kind,
          'kind',
          SourceImportFailureKind.emptyResponse,
        ),
      ),
    );
    try {
      await connector.importFile(
        path:
            'Z:${Platform.pathSeparator}missing${Platform.pathSeparator}secret.m3u',
        sourceId: 's',
      );
      fail('expected a redacted failure');
    } on SourceImportFailure catch (error) {
      expect(error.kind, SourceImportFailureKind.unreachable);
      expect(error.toString(), isNot(contains('secret')));
    }
  });
}
