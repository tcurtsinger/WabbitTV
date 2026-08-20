import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/sources/epg_models.dart';
import 'package:wabbit_tv/src/features/sources/xtream_epg_service.dart';

void main() {
  final now = DateTime.utc(2026, 8, 19, 12);

  test('parses bounded Base64 short EPG with UTC epoch truth', () {
    final programs = parseXtreamEpgResponse(
      _json({
        'epg_listings': [
          {
            'title': base64.encode(utf8.encode('  Morning   News  ')),
            'description': base64.encode(utf8.encode('Headlines')),
            'start_timestamp': '${now.millisecondsSinceEpoch ~/ 1000}',
            'stop_timestamp':
                '${now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}',
          },
        ],
      }),
      catalogItemId: 'source:live:one',
      nowUtc: now,
    );

    expect(programs, hasLength(1));
    expect(programs.single.title, 'Morning News');
    expect(programs.single.description, 'Headlines');
    expect(programs.single.startUtc, now);
    expect(programs.single.endUtc, now.add(const Duration(hours: 1)));
    expect(programs.single.startUtc.isUtc, isTrue);
    expect(programs.single.toString(), isNot(contains('Morning News')));
  });

  test(
    'accepts milliseconds and explicit-offset ISO but rejects naive local time',
    () {
      final programs = parseXtreamEpgResponse(
        _json([
          {
            'title': 'Plain title',
            'start_timestamp': now.millisecondsSinceEpoch,
            'stop_timestamp': now
                .add(const Duration(minutes: 30))
                .millisecondsSinceEpoch,
          },
          {
            'title': 'Offset title',
            'start': '2026-08-19T08:30:00-04:00',
            'end': '2026-08-19T09:00:00-04:00',
          },
          {
            'title': 'Must be rejected',
            'start': '2026-08-19 13:00:00',
            'end': '2026-08-19 14:00:00',
          },
        ]),
        catalogItemId: 'source:live:one',
        nowUtc: now,
      );

      expect(programs.map((program) => program.title), [
        'Plain title',
        'Offset title',
      ]);
      expect(programs.last.startUtc, DateTime.utc(2026, 8, 19, 12, 30));
    },
  );

  test('accepts genuine empty list and empty listings wrapper', () {
    for (final payload in <Object>[
      <Object?>[],
      {'epg_listings': <Object?>[]},
    ]) {
      expect(
        parseXtreamEpgResponse(
          _json(payload),
          catalogItemId: 'source:live:one',
          nowUtc: now,
        ),
        isEmpty,
      );
    }
  });

  test(
    'accepts structurally valid rows outside the retained horizon as empty',
    () {
      final programs = parseXtreamEpgResponse(
        _json({
          'epg_listings': [
            {
              'title': 'Future programme',
              'start_timestamp':
                  now.add(const Duration(days: 2)).millisecondsSinceEpoch ~/
                  1000,
              'stop_timestamp':
                  now
                      .add(const Duration(days: 2, hours: 1))
                      .millisecondsSinceEpoch ~/
                  1000,
            },
            {
              'title': 'Expired programme',
              'start_timestamp':
                  now
                      .subtract(const Duration(hours: 5))
                      .millisecondsSinceEpoch ~/
                  1000,
              'stop_timestamp':
                  now
                      .subtract(const Duration(hours: 4))
                      .millisecondsSinceEpoch ~/
                  1000,
            },
          ],
        }),
        catalogItemId: 'source:live:one',
        nowUtc: now,
      );

      expect(programs, isEmpty);
    },
  );

  test('rejects nonempty listings with no structurally valid required row', () {
    expect(
      () => parseXtreamEpgResponse(
        _json({
          'epg_listings': [
            {
              'title': 'Naive only',
              'start': '2026-08-19 13:00:00',
              'end': '2026-08-19 14:00:00',
            },
            {
              'title': 'Missing end',
              'start_timestamp': now.millisecondsSinceEpoch ~/ 1000,
            },
            'not-a-row',
          ],
        }),
        catalogItemId: 'source:live:one',
        nowUtc: now,
      ),
      throwsFormatException,
    );
  });

  test('deduplicates intervals, rejects invalid/out-of-window rows, and caps results', () {
    final rows = <Map<String, Object?>>[];
    for (var index = 0; index < 40; index++) {
      final start = now.add(Duration(minutes: index * 10));
      rows.add({
        'title': 'Programme $index',
        'start_timestamp': start.millisecondsSinceEpoch ~/ 1000,
        'stop_timestamp':
            start.add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/
            1000,
      });
    }
    rows.add({...rows.first, 'title': 'Duplicate'});
    rows.add({
      'title': 'Invalid',
      'start_timestamp': now.millisecondsSinceEpoch ~/ 1000,
      'stop_timestamp':
          now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/
          1000,
    });
    rows.add({
      'title': 'Too far',
      'start_timestamp':
          now.add(const Duration(days: 2)).millisecondsSinceEpoch ~/ 1000,
      'stop_timestamp':
          now.add(const Duration(days: 2, hours: 1)).millisecondsSinceEpoch ~/
          1000,
    });

    final programs = parseXtreamEpgResponse(
      _json({'epg_listings': rows}),
      catalogItemId: 'source:live:one',
      nowUtc: now,
    );
    expect(programs, hasLength(xtreamEpgMaximumProgramsPerChannel));
    expect(programs.first.title, 'Programme 0');
    expect(
      programs.map((program) => program.title),
      isNot(contains('Duplicate')),
    );
  });

  test('malformed wrapper and invalid UTF-8 fail without guessing', () {
    for (final payload in <Object>[
      {'message': 'no listings shape'},
      {'epg_listings': null},
      {'epg_listings': false},
    ]) {
      expect(
        () => parseXtreamEpgResponse(
          _json(payload),
          catalogItemId: 'source:live:one',
          nowUtc: now,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => parseXtreamEpgResponse(
        Uint8List.fromList([0xff, 0xfe]),
        catalogItemId: 'source:live:one',
        nowUtc: now,
      ),
      throwsFormatException,
    );
  });

  test('rejects implausibly long programme intervals', () {
    final programs = parseXtreamEpgResponse(
      _json({
        'epg_listings': [
          {
            'title': 'Plausible all-day block',
            'start_timestamp': now.millisecondsSinceEpoch ~/ 1000,
            'stop_timestamp':
                now.add(epgMaximumProgramDuration).millisecondsSinceEpoch ~/
                1000,
          },
          {
            'title': 'Implausible interval',
            'start_timestamp':
                now.add(const Duration(minutes: 1)).millisecondsSinceEpoch ~/
                1000,
            'stop_timestamp':
                now
                    .add(epgMaximumProgramDuration)
                    .add(const Duration(minutes: 2))
                    .millisecondsSinceEpoch ~/
                1000,
          },
        ],
      }),
      catalogItemId: 'source:live:one',
      nowUtc: now,
    );

    expect(programs.map((program) => program.title), [
      'Plausible all-day block',
    ]);
  });
}

Uint8List _json(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
