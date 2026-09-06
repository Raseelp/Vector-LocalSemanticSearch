/// 8pt-ish scale. Structural layout snaps to sm/md/base/lg/xl - use gap-style
/// spacing (SizedBox between children) over per-widget padding so rhythm
/// can't silently drift between screens.
class AppSpacing {
  AppSpacing._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double base = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
  static const double huge = 64;
}
