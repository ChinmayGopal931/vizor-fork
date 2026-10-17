import 'package:flutter/painting.dart';

import '../../layout/app_form_factor.dart';
import '../primitives.dart';

const _neon = kAppFormFactor == AppFormFactor.mobile;

/// Border / divider weights.
///
/// * [subtle] — Hairline dividers, row separators.
/// * [subtleOpacity] — Alpha border used on strong filled controls.
/// * [inverseOpacity] — Alpha border used over inverted / strong fills.
/// * [regular] — Default field/card/chip border. (Named `regular` instead of
///   Figma's `default` because `default` is a reserved word in Dart.)
/// * [medium] — Active/filled field border.
/// * [strong] — Max-contrast border.
/// * [utilityDestructive] — Validation / destructive emphasis.
/// * [utilityDestructiveSubtle] — Soft destructive border.
/// * [utilitySuccess] — Success emphasis.
/// * [utilityPositiveStrong] — Positive-state emphasis on the green ramp.
/// * [brandCrimsonStrong] — Brand feedback / accent border.
class AppBorderColors {
  const AppBorderColors({
    required this.subtle,
    required this.subtleOpacity,
    required this.inverseOpacity,
    required this.regular,
    required this.medium,
    required this.strong,
    required this.utilityDestructive,
    required this.utilityDestructiveSubtle,
    required this.utilitySuccess,
    required this.utilityPositiveStrong,
    required this.brandCrimsonStrong,
  });

  final Color subtle;
  final Color subtleOpacity;
  final Color inverseOpacity;
  final Color regular;
  final Color medium;
  final Color strong;
  final Color utilityDestructive;
  final Color utilityDestructiveSubtle;
  final Color utilitySuccess;
  final Color utilityPositiveStrong;
  final Color brandCrimsonStrong;

  /// Figma faces on desktop, the neon redesign on mobile builds.
  static const dark = _neon ? neonDark : figmaDark;
  static const light = _neon ? neonLight : figmaLight;

  static const figmaDark = AppBorderColors(
    subtle: Primitives.p150Dark,
    subtleOpacity: Primitives.p900Alpha10Dark,
    inverseOpacity: Primitives.p150Alpha15Dark,
    regular: Primitives.p300Dark,
    medium: Primitives.p400Dark,
    strong: Primitives.p800Dark,
    utilityDestructive: PlumPrimitives.p400Dark,
    utilityDestructiveSubtle: PlumPrimitives.p100Dark,
    utilitySuccess: GoldPrimitives.p500Dark,
    utilityPositiveStrong: GreenPrimitives.p300Dark,
    brandCrimsonStrong: CrimsonPrimitives.p400Dark,
  );

  static const figmaLight = AppBorderColors(
    subtle: Primitives.p150Light,
    subtleOpacity: Primitives.p900Alpha5Light,
    inverseOpacity: Primitives.p0Alpha10Light,
    regular: Primitives.p200Light,
    medium: Primitives.p300Light,
    strong: Primitives.p900Light,
    utilityDestructive: PlumPrimitives.p300Light,
    utilityDestructiveSubtle: PlumPrimitives.p100Light,
    utilitySuccess: GoldPrimitives.p400Light,
    utilityPositiveStrong: GreenPrimitives.p500Light,
    brandCrimsonStrong: CrimsonPrimitives.p300Light,
  );

  static const neonDark = AppBorderColors(
    subtle: NeonPrimitives.n200Dark,
    subtleOpacity: NeonPrimitives.white8,
    inverseOpacity: NeonPrimitives.black15,
    regular: NeonPrimitives.n300Dark,
    medium: NeonPrimitives.n400Dark,
    strong: NeonPrimitives.n800Dark,
    utilityDestructive: NeonPrimitives.red,
    utilityDestructiveSubtle: NeonPrimitives.redDeep,
    utilitySuccess: GoldPrimitives.p500Dark,
    utilityPositiveStrong: GreenPrimitives.p300Dark,
    brandCrimsonStrong: NeonPrimitives.red,
  );

  static const neonLight = AppBorderColors(
    subtle: NeonPrimitives.n150Light,
    subtleOpacity: NeonPrimitives.ink5,
    inverseOpacity: NeonPrimitives.white8,
    regular: NeonPrimitives.n200Light,
    medium: NeonPrimitives.n300Light,
    strong: NeonPrimitives.n800Light,
    utilityDestructive: NeonPrimitives.redOnLight,
    utilityDestructiveSubtle: NeonPrimitives.redSubtleOnLight,
    utilitySuccess: GoldPrimitives.p400Light,
    utilityPositiveStrong: GreenPrimitives.p500Light,
    brandCrimsonStrong: NeonPrimitives.redOnLight,
  );
}
