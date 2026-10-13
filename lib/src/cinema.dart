import 'dart:math' show pi;

import 'package:flutter/widgets.dart';

/// Night Cinema design tokens shared by the redesigned screens: an ink
/// ground, warm-white text, and amber as the one accent and focus signal.
abstract final class Cinema {
  static const ink = Color(0xFF0B0B0E);
  static const card = Color(0xF0141419);
  static const text = Color(0xFFF5F1E8);
  static const quiet = Color(0xFFC9C3B8);
  static const faint = Color(0xFFA9A397);
  static const amber = Color(0xFFFFB547);
  static const amberInk = Color(0xFF1A1206);

  /// Fill for round and pill buttons that sit over video or artwork.
  static const glass = Color(0x1AF5F1E8);
  static const glassFocused = Color(0x33F5F1E8);

  static const display = 'Bricolage Grotesque';

  /// The ring and glow a focused control wears.
  static const focusGlow = [
    BoxShadow(color: Color(0xD9FFB547), spreadRadius: 3),
    BoxShadow(color: Color(0x40FFB547), blurRadius: 24, offset: Offset(0, 8)),
  ];

  /// Scrim behind chrome that floats over video, darkest at the edge.
  static LinearGradient scrim({required bool fromTop}) => LinearGradient(
    begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
    end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
    colors: const [Color(0xE6040407), Color(0x00040407)],
  );
}

/// The Wabbit TV mark: two amber ears over a TV with a play triangle,
/// drawn in a 512 box scaled to fit. [backdrop] fills the screen so the
/// ears tuck behind it.
class WabbitMarkPainter extends CustomPainter {
  const WabbitMarkPainter({this.backdrop = Cinema.ink});

  final Color backdrop;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 512;
    canvas
      ..save()
      ..translate(
        (size.width - 512 * scale) / 2,
        (size.height - 512 * scale) / 2,
      )
      ..scale(scale);
    final amber = Paint()
      ..color = Cinema.amber
      ..style = PaintingStyle.stroke
      ..strokeWidth = 28
      ..strokeCap = StrokeCap.round;
    for (final (left, degrees) in [(150.0, -16.0), (300.0, 16.0)]) {
      canvas
        ..save()
        ..translate(left + 31, 142)
        ..rotate(degrees * pi / 180)
        ..translate(-(left + 31), -142)
        ..drawRRect(
          RRect.fromLTRBR(left, 62, left + 62, 222, const Radius.circular(31)),
          amber,
        )
        ..restore();
    }
    final screen = RRect.fromLTRBR(
      96,
      204,
      416,
      420,
      const Radius.circular(58),
    );
    canvas
      ..drawRRect(screen, Paint()..color = backdrop)
      ..drawRRect(screen, amber);
    amber.strokeWidth = 26;
    canvas
      ..drawLine(const Offset(178, 436), const Offset(152, 470), amber)
      ..drawLine(const Offset(334, 436), const Offset(360, 470), amber);
    final play = Path()
      ..moveTo(228, 268)
      ..lineTo(228, 360)
      ..lineTo(306, 314)
      ..close();
    canvas
      ..drawPath(
        play,
        Paint()
          ..color = Cinema.text
          ..style = PaintingStyle.stroke
          ..strokeWidth = 18
          ..strokeJoin = StrokeJoin.round,
      )
      ..drawPath(play, Paint()..color = Cinema.text)
      ..restore();
  }

  @override
  bool shouldRepaint(WabbitMarkPainter oldDelegate) =>
      oldDelegate.backdrop != backdrop;
}
