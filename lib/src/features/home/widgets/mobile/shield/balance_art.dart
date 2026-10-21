import 'dart:math' as math;
import 'package:flutter/painting.dart';
import '../../../../../core/theme/app_theme.dart';
import 'shield_motion.dart';

enum BalanceLook { transparent, shielded, solid }

/// The amount as Home's balance sign draws it: Thin numerals in the sign's
/// white-hot core over a Light unit in its red, both glowing. The solid look
/// is plain white, for particle sampling.
/// Painting and particle sampling share this geometry at every handover.
class BalanceArt {
  BalanceArt(
    String amount, {
    required this.look,
    required this.unitTop,
    this.fontSize = 84,
    Color glow = _white,
    Color core = _white,
    double light = 1,
  }) : _drawn = (amount, look, unitTop, fontSize, glow, core, light),
       _amount = TextPainter(
         text: TextSpan(
           text: amount,
           style: digits(fontSize).copyWith(
             color: look == BalanceLook.solid ? _white : core,
             shadows: look == BalanceLook.solid || light <= 0
                 ? null
                 : Neon.textGlow(glow, intensity: light),
           ),
         ),
         textDirection: TextDirection.ltr,
       )..layout(),
       _zec = TextPainter(
         text: TextSpan(
           text: 'ZEC',
           style: VText.display.copyWith(
             color: look == BalanceLook.solid ? _white : glow,
             shadows: look == BalanceLook.solid || light <= 0
                 ? null
                 : Neon.textGlow(glow, intensity: 0.6 * light),
             fontSize: 48 * fontSize / 84,
             fontWeight: FontWeight.w300,
             letterSpacing: 0,
             height: 1,
           ),
         ),
         textDirection: TextDirection.ltr,
       )..layout();

  final BalanceLook look;
  final double unitTop;
  final double fontSize;
  final (String, BalanceLook, double, double, Color, Color, double) _drawn;
  double get unitY => unitTop * fontSize / 84;
  double get unitFrom => unitY - 5 * fontSize / 84;
  final TextPainter _amount;
  final TextPainter _zec;
  static const unitOffset = 80.0;
  static const _white = Color(0xFFFFFFFF);
  Size get size =>
      Size(math.max(_amount.width, _zec.width), unitY + _zec.height);

  /// The numerals at [fontSize]. Thin strokes leave wide gaps between
  /// figures, so the tracking stays near Home's sign.
  static TextStyle digits(double fontSize) => VText.display.copyWith(
    fontSize: fontSize,
    letterSpacing: -0.015 * fontSize,
    height: 1,
  );

  /// Whether [paint] draws what [other]'s does: the glow is costly to redraw
  /// every frame.
  bool paintsLike(BalanceArt other) => _drawn == other._drawn;

  void paint(Canvas canvas) {
    _amount.paint(canvas, Offset((size.width - _amount.width) / 2, 0));
    _zec.paint(canvas, Offset((size.width - _zec.width) / 2, unitY));
  }
}
