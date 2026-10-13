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
    BoxShadow(color: Color(0x4DFFB547), spreadRadius: 4),
    BoxShadow(color: Color(0x40FFB547), blurRadius: 24, offset: Offset(0, 8)),
  ];

  /// Scrim behind chrome that floats over video, darkest at the edge.
  static LinearGradient scrim({required bool fromTop}) => LinearGradient(
    begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
    end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
    colors: const [Color(0xE6040407), Color(0x00040407)],
  );
}
