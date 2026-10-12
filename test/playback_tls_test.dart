import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/playback/playback_transport.dart';

void main() {
  test('player CA bundle ships as a declared asset', () {
    final bundle = File(bundledCaAsset).readAsStringSync();
    expect(
      RegExp('-----BEGIN CERTIFICATE-----').allMatches(bundle).length,
      greaterThan(100),
    );
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('- $bundledCaAsset'),
    );
  });

  test('CA bundle resolves under the Windows build flutter_assets', () {
    final sep = Platform.pathSeparator;
    expect(
      bundledCaFilePath(['C:', 'Apps', 'Wabbit', 'wabbit_tv.exe'].join(sep)),
      [
        'C:',
        'Apps',
        'Wabbit',
        'data',
        'flutter_assets',
        'assets',
        'tls',
        'cacert.pem',
      ].join(sep),
    );
  });
}
