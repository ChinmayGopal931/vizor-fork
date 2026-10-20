import 'package:flutter/painting.dart';

import '../../layout/app_form_factor.dart';
import '../primitives.dart';

const _mobile = kAppFormFactor == AppFormFactor.mobile;

/// Sync-specific sidebar colors retained from the OLDSemantic sync tokens.
class AppSyncColors {
  const AppSyncColors({
    required this.text,
    required this.textSyncing,
    required this.textError,
    required this.glow,
    required this.lightSuccess,
    required this.lightError,
  });

  final Color text;
  final Color textSyncing;
  final Color textError;
  final Color glow;
  final Color lightSuccess;
  final Color lightError;

  static const dark = _mobile ? neonDark : figmaDark;
  static const light = _mobile ? neonLight : figmaLight;

  static const figmaDark = AppSyncColors(
    text: GreenPrimitives.p900Dark,
    textSyncing: GreenPrimitives.p900Alpha65Dark,
    textError: Primitives.p900Alpha50Dark,
    glow: Primitives.p500Dark,
    lightSuccess: GreenPrimitives.p300Dark,
    lightError: Primitives.p600Dark,
  );

  static const figmaLight = AppSyncColors(
    text: GreenPrimitives.p700Light,
    textSyncing: GreenPrimitives.p900Alpha65Light,
    textError: Primitives.p900Alpha50Light,
    glow: GreenPrimitives.p200Light,
    lightSuccess: GreenPrimitives.p400Light,
    lightError: Primitives.p500Light,
  );

  /// Synced is white light; a failure lights the bar red.
  static const neonDark = AppSyncColors(
    text: NeonPrimitives.n800Dark,
    textSyncing: NeonPrimitives.white60,
    textError: NeonPrimitives.white50,
    glow: NeonPrimitives.n500Dark,
    lightSuccess: NeonPrimitives.white,
    lightError: NeonPrimitives.red,
  );

  static const neonLight = AppSyncColors(
    text: NeonPrimitives.n800Light,
    textSyncing: NeonPrimitives.ink60,
    textError: NeonPrimitives.ink50,
    glow: NeonPrimitives.n400Light,
    lightSuccess: NeonPrimitives.n800Light,
    lightError: NeonPrimitives.redOnLight,
  );
}
