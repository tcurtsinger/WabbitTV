import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/spikes/phase0/catalog_scale_probe.dart';

void main() {
  test(
    'generated scale probe imports and searches 50,000 synthetic records',
    () async {
      final result = await CatalogScaleProbe.run();

      expect(result.recordCount, catalogScaleProbeRecordCount);
      expect(result.liveCount, 16667);
      expect(result.movieCount, 16667);
      expect(result.seriesCount, 16666);
      expect(result.anchorMatchCount, catalogScaleProbeAnchorCount);
      expect(
        result.anchorSample
            .map((match) => (title: match.title, kind: match.kind))
            .toList(),
        [
          (
            title: 'Synthetic Live Catalog Record 00001 wabbit_scale_anchor',
            kind: 'Live',
          ),
          (
            title: 'Synthetic Series Catalog Record 05001 wabbit_scale_anchor',
            kind: 'Series',
          ),
          (
            title: 'Synthetic Movie Catalog Record 10001 wabbit_scale_anchor',
            kind: 'Movie',
          ),
        ],
      );
      expect(result.importElapsedMs, greaterThanOrEqualTo(0));
      expect(result.ftsSearchElapsedMs, greaterThanOrEqualTo(0));
      expect(result.databaseBytes, greaterThan(0));
    },
  );

  test(
    'scale probe remains asynchronous while its background isolate runs',
    () async {
      var completed = false;
      final pending = CatalogScaleProbe.run().then((result) {
        completed = true;
        return result;
      });

      expect(completed, isFalse);
      final result = await pending;
      expect(completed, isTrue);
      expect(result.mainIsolateTicks, greaterThan(0));
    },
  );
}
