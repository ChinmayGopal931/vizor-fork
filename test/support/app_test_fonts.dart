import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/gotham_fonts.dart';

/// Real glyphs for widget tests whose layout depends on them: Gotham, the
/// app's only family, registered as the app does, and the Material icons.
Future<void> loadAppTestFonts() async {
  await loadGothamFonts();
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}
