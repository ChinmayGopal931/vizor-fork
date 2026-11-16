import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/gotham_fonts.dart';

bool _fontsLoaded = false;

/// Real glyphs for widget tests whose layout depends on them: Gotham, the
/// app's only family, registered as the app does, the shipped Korean and
/// Chinese UI subsets that fall back behind it, and the Material icons.
Future<void> loadAppTestFonts() async {
  // Cache completion, not a Future from another widget test's FakeAsync zone.
  if (_fontsLoaded) return;
  await loadGothamFonts();
  const fonts = <String, List<String>>{
    // Load the actual shipped subsets, never alias a system family to a
    // different test font: capture metrics must match the app's UI fonts.
    'Vizor Korean UI': ['assets/fonts/VizorKoreanUI-VF.ttf'],
    'Vizor Chinese UI': ['assets/fonts/VizorChineseUI-VF.ttf'],
    'MaterialIcons': ['fonts/MaterialIcons-Regular.otf'],
  };

  for (final entry in fonts.entries) {
    final loader = FontLoader(entry.key);
    for (final asset in entry.value) {
      loader.addFont(rootBundle.load(asset));
    }
    await loader.load();
  }
  _fontsLoaded = true;
}
