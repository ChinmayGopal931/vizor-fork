import 'package:flutter/painting.dart';

import '../../layout/app_form_factor.dart';
import '../primitives.dart';

const _mobile = kAppFormFactor == AppFormFactor.mobile;

/// Icon color hierarchy retained from the OLDSemantic icon tokens.
///
/// * [accent] — Active, selected, primary icons.
/// * [regular] — Standard UI icons. (Named `regular` instead of `default`
///   because `default` is a reserved word in Dart.)
/// * [muted] — Inactive, decorative icons. Theme-invariant.
/// * [disabled] — Icons on disabled controls.
/// * [inverse] — Icons on inverted surfaces.
/// * [onPrimary] — Icons placed inside a primary button.
/// * [warning] — Caution icons. Backed by the current gold utility token for
///   compatibility with existing warning call sites.
/// * [destructive] — Destructive-state icons.
/// * [destructiveLight] — Softer destructive icon for secondary error affordances.
/// * [success] — Positive / success utility icons.
/// * [brandCrimson] — Brand-colored icons.
class AppIconColors {
  const AppIconColors({
    required this.accent,
    required this.regular,
    required this.muted,
    required this.disabled,
    required this.inverse,
    required this.onPrimary,
    required this.warning,
    required this.destructive,
    required this.destructiveLight,
    required this.success,
    required this.brandCrimson,
  });

  final Color accent;
  final Color regular;
  final Color muted;
  final Color disabled;
  final Color inverse;
  final Color onPrimary;
  final Color warning;
  final Color destructive;
  final Color destructiveLight;
  final Color success;
  final Color brandCrimson;

  static const dark = _mobile ? neonDark : figmaDark;
  static const light = _mobile ? neonLight : figmaLight;

  static const figmaDark = AppIconColors(
    accent: Primitives.p800Dark,
    regular: Primitives.p700Dark,
    muted: Primitives.p500Dark,
    disabled: Primitives.p300Dark,
    inverse: Primitives.p0Dark,
    onPrimary: Primitives.p0Dark,
    warning: GoldPrimitives.p500Dark,
    destructive: PlumPrimitives.p400Dark,
    destructiveLight: PlumPrimitives.p300Dark,
    success: GreenPrimitives.p300Dark,
    brandCrimson: CrimsonPrimitives.p400Dark,
  );

  static const figmaLight = AppIconColors(
    accent: Primitives.p900Light,
    regular: Primitives.p700Light,
    muted: Primitives.p500Light,
    disabled: Primitives.p300Light,
    inverse: Primitives.p0Light,
    onPrimary: Primitives.p0Light,
    warning: GoldPrimitives.p300Light,
    destructive: PlumPrimitives.p300Light,
    destructiveLight: PlumPrimitives.p200Light,
    success: GreenPrimitives.p500Light,
    brandCrimson: CrimsonPrimitives.p300Light,
  );

  static const neonDark = AppIconColors(
    accent: NeonPrimitives.n800Dark,
    regular: NeonPrimitives.n700Dark,
    muted: NeonPrimitives.n500Dark,
    disabled: NeonPrimitives.n300Dark,
    inverse: NeonPrimitives.n0Dark,
    onPrimary: NeonPrimitives.n0Dark,
    warning: GoldPrimitives.p500Dark,
    destructive: NeonPrimitives.red,
    destructiveLight: NeonPrimitives.redPressed,
    success: GreenPrimitives.p300Dark,
    brandCrimson: NeonPrimitives.red,
  );

  static const neonLight = AppIconColors(
    accent: NeonPrimitives.n800Light,
    regular: NeonPrimitives.n700Light,
    muted: NeonPrimitives.n500Dark,
    disabled: NeonPrimitives.n300Light,
    inverse: NeonPrimitives.n0Light,
    onPrimary: NeonPrimitives.white,
    warning: GoldPrimitives.p300Light,
    destructive: NeonPrimitives.redOnLight,
    destructiveLight: NeonPrimitives.redHot,
    success: GreenPrimitives.p500Light,
    brandCrimson: NeonPrimitives.redOnLight,
  );
}
