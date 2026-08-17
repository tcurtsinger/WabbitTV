import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/spikes/phase0/sqlite_fts5_probe.dart';

void main() {
  test(
    'background SQLite probe creates and queries an FTS5 database',
    () async {
      final result = await SqliteFts5Probe.run();

      expect(result.sqliteVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
      expect(
        result.matches
            .map((match) => (title: match.title, kind: match.kind))
            .toList(),
        [
          (title: 'Night Signal', kind: 'Live'),
          (title: 'Signal Path', kind: 'Movie'),
        ],
      );
    },
  );

  test(
    'background SQLite probe returns control before its result is available',
    () async {
      var completed = false;
      final pending = SqliteFts5Probe.run().then((result) {
        completed = true;
        return result;
      });

      // This deliberately checks the asynchronous isolate contract rather
      // than asserting an elapsed-time threshold.
      expect(completed, isFalse);
      expect((await pending).matches, isNotEmpty);
      expect(completed, isTrue);
    },
  );
}
