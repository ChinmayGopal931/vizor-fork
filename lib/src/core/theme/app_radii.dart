/// Corner-radius scale.
///
/// Figma names these `XS / S / SM / M / L / Full`; Dart exposes full words so
/// callers read like the rest of the design-system API.
///
/// [full] is the pill/stadium radius. Flutter's `StadiumBorder` is usually
/// a better choice than `BorderRadius.circular(AppRadii.full)` since it
/// adapts automatically to any element height. Keep [full] available for
/// the few places where a literal radius is more convenient.
///
/// Both form factors resolve to the near-square [AppRadiiNeon] of Veylor's
/// neon look; [AppRadiiDesktop] keeps upstream's Figma scale for the tooling
/// and tests that pin it.
abstract final class AppRadii {
  static const double xSmall = AppRadiiNeon.xSmall;
  static const double small = AppRadiiNeon.small;
  static const double medium = AppRadiiNeon.medium;
  static const double large = AppRadiiNeon.large;
  static const double xLarge = AppRadiiNeon.xLarge;
  static const double full = AppRadiiNeon.full;
}

/// The Figma radii (upstream's desktop design).
abstract final class AppRadiiDesktop {
  static const double xSmall = 8;
  static const double small = 12;
  static const double medium = 16;
  static const double large = 24;
  static const double xLarge = 32;
  static const double full = 999;
}

/// The neon radii: flat planes and near-square corners. Even a "pill" is a
/// slab with a 4px edge.
abstract final class AppRadiiNeon {
  static const double xSmall = 2;
  static const double small = 2;
  static const double medium = 3;
  static const double large = 4;
  static const double xLarge = 4;
  static const double full = 4;
}

/// 45° corner cuts for the neon surfaces (buttons, panels, badges, avatars),
/// drawn with `BeveledRectangleBorder`. A value is how far the cut reaches
/// along each edge.
abstract final class AppChamfer {
  static const double small = 4;
  static const double medium = 8;
  static const double large = 12;
  static const double xLarge = 18;
}
