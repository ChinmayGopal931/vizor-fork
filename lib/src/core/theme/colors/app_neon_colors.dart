import 'package:flutter/painting.dart';

import '../primitives.dart';

/// Light for the neon look's lit elements.
///
/// * [glow] / [core] — a lit tube on the page: its coloured halo and its
///   white-hot centre. Light mode keeps them dark enough to read on steel.
/// * [signGlow] / [signCore] — the balance sign, which is black in both
///   modes, so its light never changes.
/// * [grid] — floor and chart grid lines.
/// * [frameGlow] — white light, as a headlight: the hairline between the
///   balance sign and the Private USD strip under it.
/// * [steelGlow] / [steelCore] — brushed-steel light for Railgun's sync,
///   beside the wallet's red one in the desktop sidebar.
///
/// The Figma sets, which upstream's design never lights, mirror the brand
/// crimson so a stray use still reads as the brand accent.
class AppNeonColors {
  const AppNeonColors({
    required this.glow,
    required this.core,
    required this.signGlow,
    required this.signCore,
    required this.grid,
    required this.frameGlow,
    required this.steelGlow,
    required this.steelCore,
  });

  final Color glow;
  final Color core;
  final Color signGlow;
  final Color signCore;
  final Color grid;
  final Color frameGlow;
  final Color steelGlow;
  final Color steelCore;

  static const dark = neonDark;
  static const light = neonLight;

  static const figmaDark = AppNeonColors(
    glow: CrimsonPrimitives.p400Dark,
    core: CrimsonPrimitives.p900Dark,
    signGlow: CrimsonPrimitives.p400Dark,
    signCore: CrimsonPrimitives.p900Dark,
    grid: CrimsonPrimitives.p300Alpha15Dark,
    frameGlow: CrimsonPrimitives.p400Dark,
    steelGlow: NeonPrimitives.n700Dark,
    steelCore: NeonPrimitives.white,
  );

  static const figmaLight = AppNeonColors(
    glow: CrimsonPrimitives.p300Light,
    core: CrimsonPrimitives.p600Light,
    signGlow: CrimsonPrimitives.p400Dark,
    signCore: CrimsonPrimitives.p900Dark,
    grid: CrimsonPrimitives.p300Alpha15Light,
    frameGlow: CrimsonPrimitives.p400Dark,
    steelGlow: NeonPrimitives.n400Dark,
    steelCore: NeonPrimitives.n200Dark,
  );

  static const neonDark = AppNeonColors(
    glow: NeonPrimitives.red,
    core: NeonPrimitives.redCore,
    signGlow: NeonPrimitives.red,
    signCore: NeonPrimitives.redCore,
    grid: NeonPrimitives.red14,
    frameGlow: NeonPrimitives.headlight,
    steelGlow: NeonPrimitives.n700Dark,
    steelCore: NeonPrimitives.white,
  );

  static const neonLight = AppNeonColors(
    glow: NeonPrimitives.redOnLight,
    core: NeonPrimitives.redOnLightPressed,
    signGlow: NeonPrimitives.red,
    signCore: NeonPrimitives.redCore,
    grid: NeonPrimitives.redOnLight10,
    frameGlow: NeonPrimitives.headlight,
    steelGlow: NeonPrimitives.n400Dark,
    steelCore: NeonPrimitives.n200Dark,
  );
}
