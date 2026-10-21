import 'package:flutter/painting.dart';

import '../../layout/app_form_factor.dart';

const _mobile = kAppFormFactor == AppFormFactor.mobile;

/// macOS utility colors from the Desktop color-token export.
class AppMacosUtilityColors {
  const AppMacosUtilityColors({
    required this.window,
    required this.windowTransparent,
    required this.navPanel,
    required this.font,
    required this.thinBorder,
    required this.innerBorder,
  });

  final Color window;
  final Color windowTransparent;
  final Color navPanel;
  final Color font;
  final Color thinBorder;
  final Color innerBorder;

  static const dark = _mobile ? neonDark : figmaDark;
  static const light = _mobile ? neonLight : figmaLight;

  static const figmaDark = AppMacosUtilityColors(
    window: Color(0xFF0F0F0F),
    windowTransparent: Color(0x000F0F0F),
    navPanel: Color(0x4D1A1A1A),
    font: Color(0xCCFFFFFF),
    thinBorder: Color(0x3B1A1A1A),
    // The glass panel's inner ring is a white highlight in both Figma
    // modes (inner shadow #FFFFFF @ 15%), not a dark outline.
    innerBorder: Color(0x26FFFFFF),
  );

  static const figmaLight = AppMacosUtilityColors(
    window: Color(0xFFF7F7F7),
    windowTransparent: Color(0x00F5F5F5),
    navPanel: Color(0x4DFFFFFF),
    font: Color(0xD91A1A1A),
    thinBorder: Color(0x8CFFFFFF),
    innerBorder: Color(0x26FFFFFF),
  );

  static const neonDark = AppMacosUtilityColors(
    window: Color(0xFF000000),
    windowTransparent: Color(0x00000000),
    navPanel: Color(0xE6050506),
    font: Color(0xCCFFFFFF),
    thinBorder: Color(0xFF2D2D34),
    innerBorder: Color(0x0FFFFFFF),
  );

  static const neonLight = AppMacosUtilityColors(
    window: Color(0xFFEAEAE6),
    windowTransparent: Color(0x00EAEAE6),
    navPanel: Color(0xE6FAFAF8),
    font: Color(0xD90B0B0D),
    thinBorder: Color(0xFFD3D3CE),
    innerBorder: Color(0x24FFFFFF),
  );
}
