import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

/// A deliberately small Phase 0 proof that the packaged SQLite build supports
/// file-backed FTS5 work outside Flutter's UI isolate.
class SqliteFts5Probe {
  const SqliteFts5Probe._();

  /// Opens a temporary, file-backed database in a background isolate and
  /// removes only that probe's temporary directory before completing.
  static Future<SqliteFts5ProbeResult> run() async {
    final payload = await Isolate.run(_runInBackground);
    return SqliteFts5ProbeResult.fromJson(payload);
  }
}

class SqliteFts5ProbeResult {
  const SqliteFts5ProbeResult({
    required this.sqliteVersion,
    required this.matches,
  });

  final String sqliteVersion;
  final List<SqliteFts5ProbeMatch> matches;

  factory SqliteFts5ProbeResult.fromJson(Map<String, Object?> json) {
    final rawMatches = json['matches']! as List<Object?>;
    return SqliteFts5ProbeResult(
      sqliteVersion: json['sqliteVersion']! as String,
      matches: rawMatches
          .map((match) => SqliteFts5ProbeMatch.fromJson(match! as Map))
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() => {
    'sqliteVersion': sqliteVersion,
    'matches': matches.map((match) => match.toJson()).toList(growable: false),
  };
}

class SqliteFts5ProbeMatch {
  const SqliteFts5ProbeMatch({required this.title, required this.kind});

  final String title;
  final String kind;

  factory SqliteFts5ProbeMatch.fromJson(Map<Object?, Object?> json) {
    return SqliteFts5ProbeMatch(
      title: json['title']! as String,
      kind: json['kind']! as String,
    );
  }

  Map<String, String> toJson() => {'title': title, 'kind': kind};
}

Future<Map<String, Object?>> _runInBackground() async {
  final directory = await Directory.systemTemp.createTemp(
    'wabbit_sqlite_fts5_probe_',
  );
  final databasePath = '${directory.path}${Platform.pathSeparator}catalog.db';
  Database? database;

  try {
    database = sqlite3.open(databasePath);
    database.execute(
      'CREATE VIRTUAL TABLE catalog_search USING fts5(title, kind)',
    );
    database
      ..execute(
        'INSERT INTO catalog_search (rowid, title, kind) VALUES (?, ?, ?)',
        [1, 'Night Signal', 'Live'],
      )
      ..execute(
        'INSERT INTO catalog_search (rowid, title, kind) VALUES (?, ?, ?)',
        [2, 'Signal Path', 'Movie'],
      )
      ..execute(
        'INSERT INTO catalog_search (rowid, title, kind) VALUES (?, ?, ?)',
        [3, 'Sunday Desk', 'Series'],
      );

    final version =
        database.select('SELECT sqlite_version() AS version').single['version']!
            as String;
    final matches = database.select(
      '''
        SELECT title, kind
        FROM catalog_search
        WHERE catalog_search MATCH ?
        ORDER BY title ASC
      ''',
      ['signal'],
    );

    return {
      'sqliteVersion': version,
      'matches': matches
          .map(
            (row) => <String, String>{
              'title': row['title']! as String,
              'kind': row['kind']! as String,
            },
          )
          .toList(growable: false),
    };
  } finally {
    database?.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
