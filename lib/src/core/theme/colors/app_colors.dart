import '../../layout/app_form_factor.dart';
import 'app_background_colors.dart';
import 'app_border_colors.dart';
import 'app_button_colors.dart';
import 'app_fade_colors.dart';
import 'app_icon_colors.dart';
import 'app_macos_utility_colors.dart';
import 'app_nav_panel_colors.dart';
import 'app_neon_colors.dart';
import 'app_shadow_colors.dart';
import 'app_state_colors.dart';
import 'app_surface_colors.dart';
import 'app_sync_colors.dart';
import 'app_text_colors.dart';

export 'app_background_colors.dart';
export 'app_border_colors.dart';
export 'app_button_colors.dart';
export 'app_fade_colors.dart';
export 'app_icon_colors.dart';
export 'app_macos_utility_colors.dart';
export 'app_nav_panel_colors.dart';
export 'app_neon_colors.dart';
export 'app_shadow_colors.dart';
export 'app_state_colors.dart';
export 'app_surface_colors.dart';
export 'app_sync_colors.dart';
export 'app_text_colors.dart';

const _neon = kAppFormFactor == AppFormFactor.mobile;

/// Aggregated semantic color palette for the app. Sourced from the Zcash
/// design system Figma spec; organized into semantic categories that mirror
/// the Figma sheet structure (Background / Surface / Border / Text /
/// Icon / Button / State / Fade / Nav Panel / Shadows / Sync).
///
/// Do not read [AppColors] directly from widgets — it will be surfaced via an
/// [AppTheme] InheritedWidget wired up in a later step.
class AppColors {
  const AppColors({
    required this.background,
    required this.surface,
    required this.border,
    required this.text,
    required this.icon,
    required this.button,
    required this.state,
    required this.fade,
    required this.navPanel,
    required this.shadows,
    required this.sync,
    required this.macosUtility,
    required this.neon,
  });

  final AppBackgroundColors background;
  final AppSurfaceColors surface;
  final AppBorderColors border;
  final AppTextColors text;
  final AppIconColors icon;
  final AppButtonColors button;
  final AppStateColors state;
  final AppFadeColors fade;
  final AppNavPanelColors navPanel;
  final AppShadowColors shadows;
  final AppSyncColors sync;
  final AppMacosUtilityColors macosUtility;
  final AppNeonColors neon;

  /// Figma faces on desktop, the neon redesign on mobile builds. Tests that
  /// must pin one design regardless of lane read the named sets below.
  static const dark = _neon ? neonDark : figmaDark;
  static const light = _neon ? neonLight : figmaLight;

  static const figmaDark = AppColors(
    background: AppBackgroundColors.figmaDark,
    surface: AppSurfaceColors.figmaDark,
    border: AppBorderColors.figmaDark,
    text: AppTextColors.figmaDark,
    icon: AppIconColors.figmaDark,
    button: AppButtonColors.figmaDark,
    state: AppStateColors.figmaDark,
    fade: AppFadeColors.figmaDark,
    navPanel: AppNavPanelColors.figmaDark,
    shadows: AppShadowColors.figmaDark,
    sync: AppSyncColors.figmaDark,
    macosUtility: AppMacosUtilityColors.figmaDark,
    neon: AppNeonColors.figmaDark,
  );

  static const figmaLight = AppColors(
    background: AppBackgroundColors.figmaLight,
    surface: AppSurfaceColors.figmaLight,
    border: AppBorderColors.figmaLight,
    text: AppTextColors.figmaLight,
    icon: AppIconColors.figmaLight,
    button: AppButtonColors.figmaLight,
    state: AppStateColors.figmaLight,
    fade: AppFadeColors.figmaLight,
    navPanel: AppNavPanelColors.figmaLight,
    shadows: AppShadowColors.figmaLight,
    sync: AppSyncColors.figmaLight,
    macosUtility: AppMacosUtilityColors.figmaLight,
    neon: AppNeonColors.figmaLight,
  );

  /// Veylor's mobile look: true black, neon red, white light.
  static const neonDark = AppColors(
    background: AppBackgroundColors.neonDark,
    surface: AppSurfaceColors.neonDark,
    border: AppBorderColors.neonDark,
    text: AppTextColors.neonDark,
    icon: AppIconColors.neonDark,
    button: AppButtonColors.neonDark,
    state: AppStateColors.neonDark,
    fade: AppFadeColors.neonDark,
    navPanel: AppNavPanelColors.neonDark,
    shadows: AppShadowColors.neonDark,
    sync: AppSyncColors.neonDark,
    macosUtility: AppMacosUtilityColors.neonDark,
    neon: AppNeonColors.neonDark,
  );

  static const neonLight = AppColors(
    background: AppBackgroundColors.neonLight,
    surface: AppSurfaceColors.neonLight,
    border: AppBorderColors.neonLight,
    text: AppTextColors.neonLight,
    icon: AppIconColors.neonLight,
    button: AppButtonColors.neonLight,
    state: AppStateColors.neonLight,
    fade: AppFadeColors.neonLight,
    navPanel: AppNavPanelColors.neonLight,
    shadows: AppShadowColors.neonLight,
    sync: AppSyncColors.neonLight,
    macosUtility: AppMacosUtilityColors.neonLight,
    neon: AppNeonColors.neonLight,
  );
}
