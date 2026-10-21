import 'package:flutter/painting.dart';

import '../../layout/app_form_factor.dart';
import '../primitives.dart';

const _mobile = kAppFormFactor == AppFormFactor.mobile;

/// Shadow colors from the Figma `Semantic/Shadows` tokens.
class AppShadowColors {
  const AppShadowColors({
    required this.shadow1,
    required this.shadow2,
    required this.shadow3,
    required this.subtle,
    required this.regular,
  });

  final Color shadow1;
  final Color shadow2;
  final Color shadow3;
  final Color subtle;
  final Color regular;

  static const dark = _mobile ? neonDark : figmaDark;
  static const light = _mobile ? neonLight : figmaLight;

  static const figmaDark = AppShadowColors(
    shadow1: Primitives.p0Alpha0Dark,
    shadow2: Primitives.p0Alpha0Dark,
    shadow3: Primitives.p0Alpha0Dark,
    subtle: Primitives.p0Alpha0Dark,
    regular: Primitives.p0Alpha0Dark,
  );

  static const figmaLight = AppShadowColors(
    shadow1: Primitives.p150Light,
    shadow2: Primitives.p300Light,
    shadow3: Primitives.p900Alpha20Light,
    subtle: Primitives.p900Alpha5Light,
    regular: Primitives.p900Alpha10Light,
  );

  static const neonDark = AppShadowColors(
    shadow1: NeonPrimitives.black0,
    shadow2: NeonPrimitives.black0,
    shadow3: NeonPrimitives.black0,
    subtle: NeonPrimitives.black0,
    regular: NeonPrimitives.black0,
  );

  static const neonLight = AppShadowColors(
    shadow1: NeonPrimitives.n150Light,
    shadow2: NeonPrimitives.n300Light,
    shadow3: NeonPrimitives.ink10,
    subtle: NeonPrimitives.ink5,
    regular: NeonPrimitives.ink10,
  );
}
