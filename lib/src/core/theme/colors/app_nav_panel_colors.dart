import 'package:flutter/painting.dart';

import '../../layout/app_form_factor.dart';
import '../primitives.dart';

const _mobile = kAppFormFactor == AppFormFactor.mobile;

/// Navigation-panel colors from the Figma `Semantic/Nav Panel` tokens.
class AppNavPanelColors {
  const AppNavPanelColors({
    required this.badgeBg,
    required this.activeBg,
    required this.activeIcon,
    required this.activeLabel,
  });

  final Color badgeBg;
  final Color activeBg;
  final Color activeIcon;
  final Color activeLabel;

  static const dark = _mobile ? neonDark : figmaDark;
  static const light = _mobile ? neonLight : figmaLight;

  static const figmaDark = AppNavPanelColors(
    badgeBg: CrimsonPrimitives.p300Dark,
    activeBg: CrimsonPrimitives.p400Alpha15Dark,
    activeIcon: CrimsonPrimitives.p400Dark,
    activeLabel: CrimsonPrimitives.p900Dark,
  );

  static const figmaLight = AppNavPanelColors(
    badgeBg: CrimsonPrimitives.p300Light,
    activeBg: CrimsonPrimitives.p300Alpha10Light,
    activeIcon: CrimsonPrimitives.p300Light,
    activeLabel: CrimsonPrimitives.p800Light,
  );

  static const neonDark = AppNavPanelColors(
    badgeBg: NeonPrimitives.red,
    activeBg: NeonPrimitives.red14,
    activeIcon: NeonPrimitives.red,
    activeLabel: NeonPrimitives.redCore,
  );

  static const neonLight = AppNavPanelColors(
    badgeBg: NeonPrimitives.redOnLight,
    activeBg: NeonPrimitives.redOnLight10,
    activeIcon: NeonPrimitives.redOnLight,
    activeLabel: NeonPrimitives.redOnLightPressed,
  );
}
