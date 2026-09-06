import 'package:flutter/material.dart';

/// One accent, everywhere. Depth comes from moving between these three
/// surface tones (canvas -> parchment -> pearl), never from a shadow or a
/// second color - see AppRadius/AppSpacing for the rest of the system.
class AppColors {
  AppColors._();

  // Accent - the ONLY interactive color. Links, primary actions, focus,
  // progress fills, selection. Nothing else in the app uses it decoratively.
  static const Color primary = Color(0xFF165E59);
  static const Color primaryFocus = Color(0xFF1F7A73);
  static const Color onPrimary = Color(0xFFFFFFFF);

  // Text - a warm near-black, not pure black.
  static const Color ink = Color(0xFF1A1D1C);
  static const Color ink80 = Color(0xFF3D4240);
  static const Color ink48 = Color(0xFF7C8280);

  // Hairlines - the only separators. Never a heavy border.
  static const Color hairline = Color(0xFFE2E4E1);
  static const Color dividerSoft = Color(0xFFEFF1EE);

  // Surfaces - the three tones sections move between.
  static const Color canvas = Color(0xFFFFFFFF);
  static const Color parchment = Color(0xFFF4F6F3);
  static const Color pearl = Color(0xFFFAFBFA);

  // Status - for state only, never as decoration or a second brand color.
  static const Color danger = Color(0xFFB14032);
}
