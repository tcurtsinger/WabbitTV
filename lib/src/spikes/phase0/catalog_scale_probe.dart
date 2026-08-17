import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

const catalogScaleProbeRecordCount = 50000;
const catalogScaleProbeAnchorCount = 10;
const _anchorToken = 'wabbit_scale_anchor';

/// A generated-only Phase 0 baseline for one large, file-backed FTS5 catalog.
/// It deliberately has no production schema or catalog behavior.
class CatalogScaleProbe {
  const CatalogScaleProbe._();

  static Future<CatalogScaleProbeResult> run() async {
    var mainIsolateTicks = 0;
    final background = Isolate.run(_runInBackground);
    final heartbeat = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => mainIsolateTicks++,
    );
    try {
      final payload = await background;
      return CatalogScaleProbeResult.fromJson(
        payload,
        mainIsolateTicks: mainIsolateTicks,
      );
    } catch (_) {
      throw const CatalogScaleProbeException();
    } finally {
      heartbeat.cancel();
    }
  }
}

class CatalogScaleProbeException implements Exception {
  const CatalogScaleProbeException();

  @override
  String toString() => 'Catalog scale probe failed';
}

class CatalogScaleProbeResult {
  const CatalogScaleProbeResult({
    required this.recordCount,
    required this.liveCount,
    required this.movieCount,
    required this.seriesCount,
    required this.importElapsedMs,
    required this.ftsSearchElapsedMs,
    required this.anchorMatchCount,
    required this.anchorSample,
    required this.databaseBytes,
    required this.mainIsolateTicks,
  });

  final int recordCount;
  final int liveCount;
  final int movieCount;
  final int seriesCount;
  final int importElapsedMs;
  final int ftsSearchElapsedMs;
  final int anchorMatchCount;
  final List<CatalogScaleProbeMatch> anchorSample;
  final int databaseBytes;
  final int mainIsolateTicks;

  factory CatalogScaleProbeResult.fromJson(
    Map<String, Object?> json, {
    required int mainIsolateTicks,
  }) {
    final rawSample = json['anchorSample']! as List<Object?>;
    return CatalogScaleProbeResult(
      recordCount: json['recordCount']! as int,
      liveCount: json['liveCount']! as int,
      movieCount: json['movieCount']! as int,
      seriesCount: json['seriesCount']! as int,
      importElapsedMs: json['importElapsedMs']! as int,
      ftsSearchElapsedMs: json['ftsSearchElapsedMs']! as int,
      anchorMatchCount: json['anchorMatchCount']! as int,
      anchorSample: rawSample
          .map((entry) => CatalogScaleProbeMatch.fromJson(entry! as Map))
          .toList(growable: false),
      databaseBytes: json['databaseBytes']! as int,
      mainIsolateTicks: mainIsolateTicks,
    );
  }

  Map<String, Object?> toJson() => {
    'recordCount': recordCount,
    'liveCount': liveCount,
    'movieCount': movieCount,
    'seriesCount': seriesCount,
    'importElapsedMs': importElapsedMs,
    'ftsSearchElapsedMs': ftsSearchElapsedMs,
    'anchorMatchCount': anchorMatchCount,
    'anchorSample': anchorSample
        .map((entry) => entry.toJson())
        .toList(growable: false),
    'databaseBytes': databaseBytes,
    'mainIsolateTicks': mainIsolateTicks,
  };
}

class CatalogScaleProbeMatch {
  const CatalogScaleProbeMatch({required this.title, required this.kind});

  final String title;
  final String kind;

  factory CatalogScaleProbeMatch.fromJson(Map<Object?, Object?> json) {
    return CatalogScaleProbeMatch(
      title: json['title']! as String,
      kind: json['kind']! as String,
    );
  }

  Map<String, String> toJson() => {'title': title, 'kind': kind};
}

Future<Map<String, Object?>> _runInBackground() async {
  final directory = await Directory.systemTemp.createTemp(
    'wabbit_catalog_scale_probe_',
  );
  final databasePath = '${directory.path}${Platform.pathSeparator}catalog.db';
  Database? database;

  try {
    database = sqlite3.open(databasePath);
    database.execute(
      'CREATE VIRTUAL TABLE catalog_search USING fts5(title, kind, group_name)',
    );

    final importWatch = Stopwatch()..start();
    final insert = database.prepare(
      'INSERT INTO catalog_search (rowid, title, kind, group_name) VALUES (?, ?, ?, ?)',
    );
    try {
      database.execute('BEGIN');
      for (var index = 0; index < catalogScaleProbeRecordCount; index++) {
        final kind = _kindFor(index);
        insert.execute([
          index + 1,
          _titleFor(index, kind),
          kind,
          'Synthetic $kind Group ${index % 100}',
        ]);
      }
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    } finally {
      insert.close();
    }
    importWatch.stop();

    final searchWatch = Stopwatch()..start();
    final matches = database.select(
      '''
        SELECT title, kind
        FROM catalog_search
        WHERE catalog_search MATCH ?
        ORDER BY rowid ASC
      ''',
      [_anchorToken],
    );
    searchWatch.stop();

    final recordCount =
        database
                .select('SELECT COUNT(*) AS count FROM catalog_search')
                .single['count']!
            as int;
    final kindCounts = database.select(
      'SELECT kind, COUNT(*) AS count FROM catalog_search GROUP BY kind',
    );
    database.close();
    database = null;
    final databaseBytes = await File(databasePath).length();

    final counts = <String, int>{
      for (final row in kindCounts)
        row['kind']! as String: row['count']! as int,
    };
    return {
      'recordCount': recordCount,
      'liveCount': counts['Live'] ?? 0,
      'movieCount': counts['Movie'] ?? 0,
      'seriesCount': counts['Series'] ?? 0,
      'importElapsedMs': importWatch.elapsedMilliseconds,
      'ftsSearchElapsedMs': searchWatch.elapsedMilliseconds,
      'anchorMatchCount': matches.length,
      'anchorSample': matches
          .take(3)
          .map(
            (row) => <String, String>{
              'title': row['title']! as String,
              'kind': row['kind']! as String,
            },
          )
          .toList(growable: false),
      'databaseBytes': databaseBytes,
    };
  } finally {
    database?.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

String _kindFor(int index) => switch (index % 3) {
  0 => 'Live',
  1 => 'Movie',
  _ => 'Series',
};

String _titleFor(int index, String kind) {
  final ordinal = (index + 1).toString().padLeft(5, '0');
  final anchor =
      index % (catalogScaleProbeRecordCount ~/ catalogScaleProbeAnchorCount) ==
          0
      ? ' $_anchorToken'
      : '';
  return 'Synthetic $kind Catalog Record $ordinal$anchor';
}
