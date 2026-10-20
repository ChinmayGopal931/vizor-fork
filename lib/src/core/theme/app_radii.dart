import '../layout/app_form_factor.dart';

const _mobile = kAppFormFactor == AppFormFactor.mobile;

/// Corner-radius scale from the Figma token export (Mode 1 / Radii).
///
/// Figma names these `XS / S / SM / M / L / Full`; Dart exposes full words so
/// callers read like the rest of the design-system API.
///
/// [full] is the pill/stadium radius. Flutter's `StadiumBorder` is usually
/// a better choice than `BorderRadius.circular(AppRadii.full)` since it
/// adapts automatically to any element height. Keep [full] available for
/// the few places where a literal radius is more convenient.
///
/// Mobile builds resolve to the near-square [AppRadiiMobile]; desktop keeps
/// the Figma scale in [AppRadiiDesktop].
abstract final class AppRadii {
  static const double xSmall = _mobile
      ? AppRadiiMobile.xSmall
      : AppRadiiDesktop.xSmall;
  static const double small = _mobile
      ? AppRadiiMobile.small
      : AppRadiiDesktop.small;
  static const double medium = _mobile
      ? AppRadiiMobile.medium
      : AppRadiiDesktop.medium;
  static const double large = _mobile
      ? AppRadiiMobile.large
      : AppRadiiDesktop.large;
  static const double xLarge = _mobile
      ? AppRadiiMobile.xLarge
      : AppRadiiDesktop.xLarge;
  static const double full = _mobile
      ? AppRadiiMobile.full
      : AppRadiiDesktop.full;
}

/// The Figma radii (desktop).
abstract final class AppRadiiDesktop {
  static const double xSmall = 8;
  static const double small = 12;
  static const double medium = 16;
  static const double large = 24;
  static const double xLarge = 32;
  static const double full = 999;
}

/// The mobile radii: flat planes and near-square corners. Even a "pill" is a
/// slab with a 4px edge.
abstract final class AppRadiiMobile {
  static const double xSmall = 2;
  static const double small = 2;
  static const double medium = 3;
  static const double large = 4;
  static const double xLarge = 4;
  static const double full = 4;
}

/// 45° corner cuts for the mobile surfaces (buttons, panels, badges,
/// avatars), drawn with `BeveledRectangleBorder`. A value is how far the cut
/// reaches along each edge.
abstract final class AppChamfer {
  static const double small = 4;
  static const double medium = 8;
  static const double large = 12;
  static const double xLarge = 18;
}
