import 'package:flutter/material.dart';

/// The app-wide focus edge for Material buttons: a 2 px amber border while
/// keyboard-focused (warm white when the button is filled amber), otherwise
/// [rest]. Material's default focus overlay alone is too faint to see.
WidgetStateProperty<BorderSide> focusEdge({
  BorderSide rest = BorderSide.none,
  bool onAmber = false,
}) => WidgetStateProperty.resolveWith(
  (states) => states.contains(WidgetState.focused)
      ? BorderSide(
          color: onAmber ? const Color(0xFFF4F0E7) : const Color(0xFFFFB347),
          width: 2,
        )
      : rest,
);
