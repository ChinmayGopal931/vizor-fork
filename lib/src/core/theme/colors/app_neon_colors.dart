import 'package:flutter/painting.dart';

import '../../layout/app_form_factor.dart';
import '../primitives.dart';

const _neon = kAppFormFactor == AppFormFactor.mobile;

/// Light for the neon redesign's lit elements (mobile).
///
/// * [glow] / [core] — a lit tube on the page: its coloured halo and its
///   white-hot centre. Light mode keeps them dark enough to read on steel.
/// * [signGlow] / [signCore] / [signPanel] — the balance sign, which is
///   black in both modes, so its light never changes.
/// * [grid] — floor and chart grid lines.
/// * [frameGlow] / [frameCore] — the balance sign's frame: white light, as
///   the headlights against the red tail lights inside it.
///
/// Desktop has no neon elements; its set mirrors the brand crimson so a
/// stray use still reads as the brand accent.
class AppNeonColors {
  const AppNeonColors({
    required this.glow,
    required this.core,
    required this.signGlow,
    required this.signCore,
    required this.signPanel,
    required this.grid,
    required this.frameGlow,
    required this.frameCore,
  });

  final Color glow;
  final Color core;
  final Color signGlow;
  final Color signCore;
  final Color signPanel;
  final Color grid;
  final Color frameGlow;
  final Color frameCore;

  /// Figma faces on desktop, the neon redesign on mobile builds.
  static const dark = _neon ? neonDark : figmaDark;
  static const light = _neon ? neonLight : figmaLight;

  static const figmaDark = AppNeonColors(
    glow: CrimsonPrimitives.p400Dark,
    core: CrimsonPrimitives.p900Dark,
    signGlow: CrimsonPrimitives.p400Dark,
    signCore: CrimsonPrimitives.p900Dark,
    signPanel: Primitives.p50Dark,
    grid: CrimsonPrimitives.p300Alpha15Dark,
    frameGlow: CrimsonPrimitives.p400Dark,
    frameCore: CrimsonPrimitives.p900Dark,
  );

  static const figmaLight = AppNeonColors(
    glow: CrimsonPrimitives.p300Light,
    core: CrimsonPrimitives.p600Light,
    signGlow: CrimsonPrimitives.p400Dark,
    signCore: CrimsonPrimitives.p900Dark,
    signPanel: Primitives.p800Light,
    grid: CrimsonPrimitives.p300Alpha15Light,
    frameGlow: CrimsonPrimitives.p400Dark,
    frameCore: CrimsonPrimitives.p900Dark,
  );

  static const neonDark = AppNeonColors(
    glow: NeonPrimitives.red,
    core: NeonPrimitives.redCore,
    signGlow: NeonPrimitives.red,
    signCore: NeonPrimitives.redCore,
    signPanel: NeonPrimitives.black,
    grid: NeonPrimitives.red14,
    frameGlow: NeonPrimitives.headlight,
    frameCore: NeonPrimitives.white,
  );

  static const neonLight = AppNeonColors(
    glow: NeonPrimitives.redOnLight,
    core: NeonPrimitives.redOnLightPressed,
    signGlow: NeonPrimitives.red,
    signCore: NeonPrimitives.redCore,
    signPanel: NeonPrimitives.black,
    grid: NeonPrimitives.redOnLight10,
    frameGlow: NeonPrimitives.headlight,
    frameCore: NeonPrimitives.white,
  );
}
