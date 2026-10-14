// Renders the launcher icons, TV banner and Windows icon from
// WabbitMarkPainter. Run: flutter test tool/render_brand_assets.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/cinema.dart';

const _tile = Color(0xFF0E0E12);

Future<Uint8List> _png(
  int width,
  int height,
  void Function(Canvas) draw,
) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

/// The mark on a rounded dark tile, as in the approved icon design.
Future<Uint8List> _icon(int size) => _png(size, size, (canvas) {
  final side = size.toDouble();
  canvas.drawRRect(
    RRect.fromLTRBR(0, 0, side, side, Radius.circular(side * 112 / 512)),
    Paint()..color = _tile,
  );
  const WabbitMarkPainter(backdrop: _tile).paint(canvas, Size.square(side));
});

/// 320x180 Android TV / Fire TV banner: the mark, then the name.
Future<Uint8List> _banner() => _png(320, 180, (canvas) {
  canvas.drawRect(const Rect.fromLTWH(0, 0, 320, 180), Paint()..color = _tile);
  canvas
    ..save()
    ..translate(22, 34)
    ..scale(112 / 512);
  const WabbitMarkPainter(backdrop: _tile)
      .paint(canvas, const Size.square(512));
  canvas.restore();
  final name = TextPainter(
    text: const TextSpan(
      text: 'Wabbit TV',
      style: TextStyle(
        color: Cinema.text,
        fontFamily: Cinema.display,
        fontSize: 31,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  name.paint(canvas, Offset(144, 90 - name.height / 2));
});

/// An .ico holding PNG images, which Windows reads from Vista on.
Uint8List _ico(Map<int, Uint8List> pngs) {
  final header = ByteData(6 + 16 * pngs.length)
    ..setUint16(2, 1, Endian.little)
    ..setUint16(4, pngs.length, Endian.little);
  var offset = header.lengthInBytes;
  for (final (index, MapEntry(key: size, value: png)) in pngs.entries.indexed) {
    final entry = 6 + 16 * index;
    header
      ..setUint8(entry, size % 256)
      ..setUint8(entry + 1, size % 256)
      ..setUint16(entry + 4, 1, Endian.little)
      ..setUint16(entry + 6, 32, Endian.little)
      ..setUint32(entry + 8, png.length, Endian.little)
      ..setUint32(entry + 12, offset, Endian.little);
    offset += png.length;
  }
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add([for (final png in pngs.values) ...png]))
      .takeBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('render brand assets', () async {
    final font = FontLoader(Cinema.display)
      ..addFont(
        File('assets/fonts/BricolageGrotesque-ExtraBold.ttf')
            .readAsBytes()
            .then(ByteData.sublistView),
      );
    await font.load();

    const res = 'android/app/src/main/res';
    for (final (folder, size) in [
      ('mdpi', 48),
      ('hdpi', 72),
      ('xhdpi', 96),
      ('xxhdpi', 144),
      ('xxxhdpi', 192),
    ]) {
      await File('$res/mipmap-$folder/ic_launcher.png')
          .writeAsBytes(await _icon(size));
    }
    await File('$res/drawable-xhdpi/tv_banner.png')
        .writeAsBytes(await _banner());
    await File('assets/branding/wabbit-tv-icon.png')
        .writeAsBytes(await _icon(1024));
    await File('windows/runner/resources/app_icon.ico').writeAsBytes(
      _ico({
        for (final size in [16, 24, 32, 48, 64, 128, 256])
          size: await _icon(size),
      }),
    );
  });
}
