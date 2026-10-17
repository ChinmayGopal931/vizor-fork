import 'package:flutter/painting.dart';

import '../../layout/app_form_factor.dart';
import '../primitives.dart';

const _neon = kAppFormFactor == AppFormFactor.mobile;

/// Button colors grouped by variant.
///
/// Each variant owns its own sub-palette so widgets reference them as
/// `button.primary.bg`, `button.ghost.bgHover`, etc.
class AppButtonColors {
  const AppButtonColors({
    required this.primary,
    required this.secondary,
    required this.ghost,
    required this.disabled,
    required this.destructive,
  });

  final AppPrimaryButtonColors primary;
  final AppSecondaryButtonColors secondary;
  final AppGhostButtonColors ghost;
  final AppDisabledButtonColors disabled;
  final AppDestructiveButtonColors destructive;

  /// Figma faces on desktop, the neon redesign on mobile builds.
  static const dark = _neon ? neonDark : figmaDark;
  static const light = _neon ? neonLight : figmaLight;

  static const figmaDark = AppButtonColors(
    primary: AppPrimaryButtonColors.figmaDark,
    secondary: AppSecondaryButtonColors.figmaDark,
    ghost: AppGhostButtonColors.figmaDark,
    disabled: AppDisabledButtonColors.figmaDark,
    destructive: AppDestructiveButtonColors.figmaDark,
  );

  static const figmaLight = AppButtonColors(
    primary: AppPrimaryButtonColors.figmaLight,
    secondary: AppSecondaryButtonColors.figmaLight,
    ghost: AppGhostButtonColors.figmaLight,
    disabled: AppDisabledButtonColors.figmaLight,
    destructive: AppDestructiveButtonColors.figmaLight,
  );

  static const neonDark = AppButtonColors(
    primary: AppPrimaryButtonColors.neonDark,
    secondary: AppSecondaryButtonColors.neonDark,
    ghost: AppGhostButtonColors.neonDark,
    disabled: AppDisabledButtonColors.neonDark,
    destructive: AppDestructiveButtonColors.neonDark,
  );

  static const neonLight = AppButtonColors(
    primary: AppPrimaryButtonColors.neonLight,
    secondary: AppSecondaryButtonColors.neonLight,
    ghost: AppGhostButtonColors.neonLight,
    disabled: AppDisabledButtonColors.neonLight,
    destructive: AppDestructiveButtonColors.neonLight,
  );
}

class AppPrimaryButtonColors {
  const AppPrimaryButtonColors({
    required this.bg,
    required this.bgHover,
    required this.bgPressed,
    required this.border,
    required this.borderHover,
    required this.borderPressed,
    required this.label,
    required this.labelHover,
  });

  final Color bg;
  final Color bgHover;
  final Color bgPressed;
  final Color border;
  final Color borderHover;
  final Color borderPressed;
  final Color label;
  final Color labelHover;

  /// Figma faces on desktop, the neon redesign on mobile builds.
  static const dark = _neon ? neonDark : figmaDark;
  static const light = _neon ? neonLight : figmaLight;

  static const figmaDark = AppPrimaryButtonColors(
    bg: Primitives.p800Dark,
    bgHover: CrimsonPrimitives.p300Dark,
    bgPressed: CrimsonPrimitives.p300Dark,
    border: Primitives.p900Alpha10Dark,
    borderHover: Primitives.p900Alpha10Dark,
    borderPressed: Primitives.p900Alpha10Dark,
    label: Primitives.p50Dark,
    labelHover: Primitives.p800Dark,
  );

  static const figmaLight = AppPrimaryButtonColors(
    bg: Primitives.p800Light,
    bgHover: CrimsonPrimitives.p400Light,
    bgPressed: CrimsonPrimitives.p400Light,
    border: Primitives.p0Alpha10Light,
    borderHover: Primitives.p900Alpha5Light,
    borderPressed: Primitives.p900Alpha5Light,
    label: Primitives.p100Light,
    labelHover: Primitives.p100Light,
  );

  /// A lit red slab with a black label; the hairline edge reads as the
  /// tube's highlight.
  static const neonDark = AppPrimaryButtonColors(
    bg: NeonPrimitives.red,
    bgHover: NeonPrimitives.redHot,
    bgPressed: NeonPrimitives.redPressed,
    border: NeonPrimitives.white14,
    borderHover: NeonPrimitives.white14,
    borderPressed: NeonPrimitives.white14,
    label: NeonPrimitives.n0Dark,
    labelHover: NeonPrimitives.n0Dark,
  );

  static const neonLight = AppPrimaryButtonColors(
    bg: NeonPrimitives.redOnLight,
    bgHover: NeonPrimitives.red,
    bgPressed: NeonPrimitives.redOnLightPressed,
    border: NeonPrimitives.ink10,
    borderHover: NeonPrimitives.ink5,
    borderPressed: NeonPrimitives.ink5,
    label: NeonPrimitives.white,
    labelHover: NeonPrimitives.white,
  );
}

class AppSecondaryButtonColors {
  const AppSecondaryButtonColors({
    required this.bg,
    required this.bgHover,
    required this.bgPressed,
    required this.label,
  });

  final Color bg;
  final Color bgHover;
  final Color bgPressed;
  final Color label;

  /// Figma faces on desktop, the neon redesign on mobile builds.
  static const dark = _neon ? neonDark : figmaDark;
  static const light = _neon ? neonLight : figmaLight;

  static const figmaDark = AppSecondaryButtonColors(
    bg: Primitives.p150Dark,
    bgHover: Primitives.p200Dark,
    bgPressed: Primitives.p200Dark,
    label: Primitives.p800Dark,
  );

  static const figmaLight = AppSecondaryButtonColors(
    bg: Primitives.p0Light,
    bgHover: Primitives.p100Light,
    bgPressed: Primitives.p100Light,
    label: Primitives.p900Light,
  );

  /// Glass: the backdrop's light shows through.
  static const neonDark = AppSecondaryButtonColors(
    bg: NeonPrimitives.white6,
    bgHover: NeonPrimitives.white14,
    bgPressed: NeonPrimitives.white14,
    label: NeonPrimitives.n800Dark,
  );

  static const neonLight = AppSecondaryButtonColors(
    bg: NeonPrimitives.n0Light,
    bgHover: NeonPrimitives.n100Light,
    bgPressed: NeonPrimitives.n100Light,
    label: NeonPrimitives.n800Light,
  );
}

class AppGhostButtonColors {
  const AppGhostButtonColors({
    required this.bg,
    required this.bgHover,
    required this.border,
    required this.label,
  });

  // Transparent-looking base; the concrete token equals ground so the fill
  // reads as "no fill" against Scaffold.
  final Color bg;
  final Color bgHover;
  final Color border;
  final Color label;

  /// Figma faces on desktop, the neon redesign on mobile builds.
  static const dark = _neon ? neonDark : figmaDark;
  static const light = _neon ? neonLight : figmaLight;

  static const figmaDark = AppGhostButtonColors(
    bg: Primitives.p0Dark,
    // p100Dark equals the raised/modal surface (#232828), which made the
    // hover fill invisible on modal panels — one step up stays visible on
    // both ground and raised surfaces.
    bgHover: Primitives.p150Dark,
    border: Primitives.p300Dark,
    label: Primitives.p700Dark,
  );

  static const figmaLight = AppGhostButtonColors(
    bg: Primitives.p0Light,
    bgHover: Primitives.p100Light,
    border: Primitives.p300Light,
    label: Primitives.p800Light,
  );

  static const neonDark = AppGhostButtonColors(
    bg: NeonPrimitives.n0Dark,
    bgHover: NeonPrimitives.n150Dark,
    border: NeonPrimitives.n300Dark,
    label: NeonPrimitives.n700Dark,
  );

  static const neonLight = AppGhostButtonColors(
    bg: NeonPrimitives.n0Light,
    bgHover: NeonPrimitives.n100Light,
    border: NeonPrimitives.n300Light,
    label: NeonPrimitives.n700Light,
  );
}

class AppDisabledButtonColors {
  const AppDisabledButtonColors({required this.bg, required this.label});

  final Color bg;
  final Color label;

  /// Figma faces on desktop, the neon redesign on mobile builds.
  static const dark = _neon ? neonDark : figmaDark;
  static const light = _neon ? neonLight : figmaLight;

  static const figmaDark = AppDisabledButtonColors(
    bg: Primitives.p300Alpha20Dark,
    label: Primitives.p500Alpha50Dark,
  );

  static const figmaLight = AppDisabledButtonColors(
    bg: Primitives.p300Alpha20Light,
    label: Primitives.p500Alpha50Light,
  );

  static const neonDark = AppDisabledButtonColors(
    bg: NeonPrimitives.n300Alpha40Dark,
    label: NeonPrimitives.n500Alpha60Dark,
  );

  static const neonLight = AppDisabledButtonColors(
    bg: NeonPrimitives.n300Alpha20Light,
    label: NeonPrimitives.n500Alpha50Light,
  );
}

class AppDestructiveButtonColors {
  const AppDestructiveButtonColors({
    required this.bg,
    required this.bgHover,
    required this.bgPressed,
    required this.border,
    required this.borderHover,
    required this.borderPressed,
    required this.label,
  });

  final Color bg;
  final Color bgHover;
  final Color bgPressed;
  final Color border;
  final Color borderHover;
  final Color borderPressed;
  final Color label;

  /// Figma faces on desktop, the neon redesign on mobile builds.
  static const dark = _neon ? neonDark : figmaDark;
  static const light = _neon ? neonLight : figmaLight;

  static const figmaDark = AppDestructiveButtonColors(
    bg: PlumPrimitives.p200Dark,
    bgHover: PlumPrimitives.p150Dark,
    bgPressed: PlumPrimitives.p150Dark,
    border: Primitives.p900Alpha10Dark,
    borderHover: Primitives.p900Alpha10Dark,
    borderPressed: Primitives.p900Alpha10Dark,
    label: PlumPrimitives.p800Dark,
  );

  static const figmaLight = AppDestructiveButtonColors(
    bg: PlumPrimitives.p500Light,
    bgHover: PlumPrimitives.p600Light,
    bgPressed: PlumPrimitives.p600Light,
    border: Primitives.p900Alpha5Light,
    borderHover: Primitives.p900Alpha5Light,
    borderPressed: Primitives.p900Alpha5Light,
    label: PlumPrimitives.p50Light,
  );

  /// Outlined red on a dark red ground, so it never reads as the solid
  /// primary slab.
  static const neonDark = AppDestructiveButtonColors(
    bg: NeonPrimitives.redSubtle,
    bgHover: NeonPrimitives.redDeep,
    bgPressed: NeonPrimitives.redDeep,
    border: NeonPrimitives.red,
    borderHover: NeonPrimitives.redHot,
    borderPressed: NeonPrimitives.redHot,
    label: NeonPrimitives.redCore,
  );

  static const neonLight = AppDestructiveButtonColors(
    bg: NeonPrimitives.redSubtleOnLight,
    bgHover: NeonPrimitives.redOnLight18,
    bgPressed: NeonPrimitives.redOnLight18,
    border: NeonPrimitives.redOnLight,
    borderHover: NeonPrimitives.redOnLightPressed,
    borderPressed: NeonPrimitives.redOnLightPressed,
    label: NeonPrimitives.redOnLightPressed,
  );
}
