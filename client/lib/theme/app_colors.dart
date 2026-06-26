import 'package:flutter/widgets.dart';

/// Centralized color tokens for the zeb Echo client.
///
/// These match the real **zeb brand** (zeb.co): a dark green-charcoal canvas,
/// a lime/sage green accent, warm cream text, and a terracotta secondary accent
/// — NOT the electric-blue-on-black values from the original brief (those were
/// corrected to match the actual brand; see CLAUDE.md §5).
///
/// This is the ONLY place raw hex values may appear — widgets must reference
/// these tokens (or the [ThemeData] built from them) and never hardcode colors.
abstract final class AppColors {
  AppColors._();

  // --- Backgrounds ---------------------------------------------------------
  /// Deepest surface — near-black green used behind bars / chrome.
  static const Color backgroundBlack = Color(0xFF11160F);

  /// Primary background — zeb's dark green-charcoal hero canvas.
  static const Color background = Color(0xFF1A211D);

  /// Secondary background / raised surface.
  static const Color surface = Color(0xFF222B26);

  /// Slightly lighter elevated surface (chips, hovered cards).
  static const Color surfaceElevated = Color(0xFF2B342E);

  // --- Text ----------------------------------------------------------------
  /// Primary text — warm cream/paper (zeb uses off-white, not pure white).
  static const Color textPrimary = Color(0xFFF0EDE4);

  /// Secondary / muted text — desaturated sage gray.
  static const Color textSecondary = Color(0xFFA7B0A6);

  // --- Accents -------------------------------------------------------------
  /// Primary accent — zeb's signature lime/sage green. Used sparingly for
  /// actions, highlights, and the live/active state.
  static const Color accent = Color(0xFFB6E08A);

  /// Foreground for content placed ON the [accent] (the accent is light, so
  /// on-accent text/icons must be dark for contrast).
  static const Color onAccent = Color(0xFF15200F);

  /// Secondary accent — terracotta, for emphasis and the warm-tone highlights
  /// zeb pairs with the green.
  static const Color accentSecondary = Color(0xFFC4794A);

  // --- Borders / dividers --------------------------------------------------
  /// Border / divider — subtle green-tinted line.
  static const Color border = Color(0xFF313A33);

  // --- Status colors (minimal, low-distraction) ----------------------------
  /// Healthy / connected indicator — leans on the brand green.
  static const Color statusOk = Color(0xFF9CCF6B);

  /// Warning / degraded indicator (e.g. provider loading) — terracotta family.
  static const Color statusWarning = Color(0xFFD89A4A);

  /// Error indicator (e.g. mic failed, backend disconnected).
  static const Color statusError = Color(0xFFE0685E);
}
