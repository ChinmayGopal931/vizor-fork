import 'package:flutter/painting.dart';

import '../../layout/app_form_factor.dart';
import '../primitives.dart';

const _neon = kAppFormFactor == AppFormFactor.mobile;

/// Component-level surface colors.
///
/// * [card] — Card components, list rows.
/// * [input] — Text input surface colors.
/// * [nav] — Navigation rail background.
/// * [navActive] — Active nav item indicator.
/// * [tooltip] — Tooltip / popover background. Theme-invariant.
/// * [qrCode] — QR code backing surface. Theme-invariant for scan contrast.
/// * [scrollbarThumb] — Desktop pane overlay scrollbar thumb. Solid (fully
///   opaque) per the Figma Scrollbar component: `#393E3E` dark / `#E1E1E1`
///   light. Distinct from the sidebar accounts scrollbar, which uses the
///   semi-transparent `background.neutralStrongOpacity` token.
class AppSurfaceColors {
  const AppSurfaceColors({
    required this.card,
    required this.input,
    required this.nav,
    required this.navActive,
    required this.tooltip,
    required this.qrCode,
    required this.scrollbarThumb,
  });

  final Color card;
  final AppInputSurfaceColors input;
  final Color nav;
  final Color navActive;
  final Color tooltip;
  final Color qrCode;
  final Color scrollbarThumb;

  /// Figma faces on desktop, the neon redesign on mobile builds.
  static const dark = _neon ? neonDark : figmaDark;
  static const light = _neon ? neonLight : figmaLight;

  static const figmaDark = AppSurfaceColors(
    card: Primitives.p100Dark,
    input: AppInputSurfaceColors.figmaDark,
    nav: Primitives.p50Dark,
    navActive: Primitives.p150Dark,
    tooltip: Primitives.p200Dark,
    qrCode: Primitives.p0Light,
    scrollbarThumb: Primitives.p200Dark,
  );

  static const figmaLight = AppSurfaceColors(
    card: Primitives.p50Light,
    input: AppInputSurfaceColors.figmaLight,
    nav: Primitives.p0Light,
    navActive: Primitives.p100Light,
    // Tooltip is the same concrete value in both modes; picking p800Light here
    // keeps the expression inside the light-face lookup.
    tooltip: Primitives.p800Light,
    qrCode: Primitives.p0Light,
    scrollbarThumb: Primitives.p150Light,
  );

  static const neonDark = AppSurfaceColors(
    card: NeonPrimitives.n100Dark,
    input: AppInputSurfaceColors.neonDark,
    nav: NeonPrimitives.n50Dark,
    navActive: NeonPrimitives.n150Dark,
    tooltip: NeonPrimitives.n200Dark,
    qrCode: NeonPrimitives.white,
    scrollbarThumb: NeonPrimitives.n200Dark,
  );

  static const neonLight = AppSurfaceColors(
    card: NeonPrimitives.n50Light,
    input: AppInputSurfaceColors.neonLight,
    nav: NeonPrimitives.n0Light,
    navActive: NeonPrimitives.n100Light,
    tooltip: NeonPrimitives.n200Dark,
    qrCode: NeonPrimitives.white,
    scrollbarThumb: NeonPrimitives.n150Light,
  );
}

/// Text input surface colors grouped by field variant/state.
class AppInputSurfaceColors {
  const AppInputSurfaceColors({
    required this.primary,
    required this.secondary,
    required this.focus,
  });

  final Color primary;
  final Color secondary;
  final Color focus;

  /// Figma faces on desktop, the neon redesign on mobile builds.
  static const dark = _neon ? neonDark : figmaDark;
  static const light = _neon ? neonLight : figmaLight;

  static const figmaDark = AppInputSurfaceColors(
    primary: Primitives.p50Dark,
    secondary: Primitives.p150Dark,
    focus: Primitives.p100Dark,
  );

  static const figmaLight = AppInputSurfaceColors(
    primary: Primitives.p0Light,
    secondary: Primitives.p100Light,
    focus: Primitives.p50Light,
  );

  static const neonDark = AppInputSurfaceColors(
    primary: NeonPrimitives.n50Dark,
    secondary: NeonPrimitives.n150Dark,
    focus: NeonPrimitives.n100Dark,
  );

  static const neonLight = AppInputSurfaceColors(
    primary: NeonPrimitives.n0Light,
    secondary: NeonPrimitives.n100Light,
    focus: NeonPrimitives.n50Light,
  );
}
