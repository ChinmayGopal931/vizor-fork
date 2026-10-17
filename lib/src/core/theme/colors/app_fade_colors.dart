import 'package:flutter/painting.dart';

import '../../layout/app_form_factor.dart';
import '../primitives.dart';

const _neon = kAppFormFactor == AppFormFactor.mobile;

/// Fade / scrim tokens retained from the OLDSemantic fade group.
///
/// * [illustration] — Gentle fade laid over a bottom-anchored
///   illustration so the art dissolves into the backdrop instead of
///   presenting a hard top edge. Dark mode uses a 50% overlay of the
///   ground color; light mode is fully transparent (the illustration
///   sits directly on the light surface and needs no darkening).
class AppFadeColors {
  const AppFadeColors({required this.illustration});

  final Color illustration;

  /// Figma faces on desktop, the neon redesign on mobile builds.
  static const dark = _neon ? neonDark : figmaDark;
  static const light = _neon ? neonLight : figmaLight;

  static const figmaDark = AppFadeColors(
    illustration: Primitives.p0Alpha50Dark,
  );

  // Fully transparent on light mode — keeps the same rgb anchor as the
  // dark face so fade animations between modes don't flicker through a
  // neutral color.
  static const figmaLight = AppFadeColors(
    illustration: Primitives.p0Alpha0Dark,
  );

  static const neonDark = AppFadeColors(illustration: NeonPrimitives.black50);

  static const neonLight = AppFadeColors(illustration: NeonPrimitives.black0);
}
