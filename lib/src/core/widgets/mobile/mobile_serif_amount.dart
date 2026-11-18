/// The large serif amount of the mobile Home balance card, shared with the
/// pages that show an amount the same way (the Request ZEC QR step).
library;

import 'package:flutter/widgets.dart';

import '../../theme/gotham_fonts.dart' show kGothamFamily;

/// The amount: Young Serif 40 / 44 with tabular figures in Figma, drawn in
/// Gotham Thin like every display numeral on Veylor's mobile.
const kMobileSerifAmountStyle = TextStyle(
  fontFamily: kGothamFamily,
  fontWeight: FontWeight.w100,
  fontSize: 40,
  height: 44 / 40,
  letterSpacing: -1.35,
  fontFeatures: [FontFeature.enable('case'), FontFeature.tabularFigures()],
);

/// The ticker beside [kMobileSerifAmountStyle]: Young Serif 28 / 31 in Figma,
/// Gotham Thin here.
const kMobileSerifTickerStyle = TextStyle(
  fontFamily: kGothamFamily,
  fontWeight: FontWeight.w100,
  fontSize: 28,
  height: 31 / 28,
  letterSpacing: -1.35,
  fontFeatures: [FontFeature.enable('case')],
);
