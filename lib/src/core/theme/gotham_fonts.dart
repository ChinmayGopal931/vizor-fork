/// Registers the bundled Gotham typeface, the only family the app uses.
///
/// Gotham is deliberately **not** declared under `fonts:` in `pubspec.yaml`.
/// Flutter's text stack builds each face's style from the font file itself
/// and ignores the `weight:` written in the pubspec, and the OS/2 weight
/// classes in these Gotham files are not on the CSS scale (Light 300, Book
/// 325, Medium 350, Bold 400, Black 425, Ultra 450). Declared in the pubspec,
/// `FontWeight.w400` would resolve to the Bold file and `w500` and above to
/// Ultra, so ordinary body text would render bold.
///
/// [loadGothamFonts] therefore reads the files as plain assets and rewrites
/// each face's `usWeightClass` in memory to the CSS weight in [gothamFaces]
/// before registering the family. The files on disk are never modified, so
/// they can be replaced by the vendor's originals without a conversion step.
///
/// Gotham has no SemiBold and no upright Extra Light, so `FontWeight.w600`
/// resolves to Bold and `FontWeight.w200` to Thin. It has no monospace
/// companion either; addresses and mnemonics use the same family.
///
/// Call [loadGothamFonts] before the first frame (the app does it in
/// `initializeZcashWalletRuntime`) and from any widget test or capture that
/// needs real glyphs instead of the square test font.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The family name every `TextStyle` in the app uses.
const kGothamFamily = 'Gotham';

/// The bundled faces and the CSS weight each one must resolve as.
const gothamFaces = <({String asset, int weight})>[
  (asset: 'assets/fonts/Gotham-Thin.otf', weight: 100),
  (asset: 'assets/fonts/Gotham-ThinItalic.otf', weight: 100),
  (asset: 'assets/fonts/Gotham-ExtraLightItalic.otf', weight: 200),
  (asset: 'assets/fonts/Gotham-Light.otf', weight: 300),
  (asset: 'assets/fonts/Gotham-Book.otf', weight: 400),
  (asset: 'assets/fonts/Gotham-Medium.otf', weight: 500),
  (asset: 'assets/fonts/Gotham-Bold.otf', weight: 700),
  (asset: 'assets/fonts/Gotham-Black.otf', weight: 800),
  (asset: 'assets/fonts/Gotham-Ultra.otf', weight: 900),
];

/// Set once the faces are registered. A plain flag rather than a cached
/// [Future]: widget tests run each test in its own fake-async zone, and a
/// completed future created in one zone is never delivered in another.
bool _loaded = false;

/// Registers the [kGothamFamily] faces with the engine, once per process.
///
/// Reads the files from [bundle] (the root bundle by default). Calls made
/// while another is still loading register the faces again, which is
/// harmless. A failure is rethrown and leaves the family unregistered, so a
/// later call may try again.
Future<void> loadGothamFonts({AssetBundle? bundle}) async {
  if (_loaded) return;
  await _load(bundle ?? rootBundle);
  _loaded = true;
}

Future<void> _load(AssetBundle bundle) async {
  final loader = FontLoader(kGothamFamily);
  for (final face in gothamFaces) {
    final data = await bundle.load(face.asset);
    final font = withOpenTypeWeightClass(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      face.weight,
    );
    loader.addFont(Future.value(ByteData.sublistView(font)));
  }
  await loader.load();
}

/// Returns a copy of the sfnt [font] whose OS/2 `usWeightClass` is [weight].
///
/// The OS/2 table checksum and the `head.checkSumAdjustment` are recomputed,
/// so the result stays a valid font for loaders that verify them. Nothing
/// else changes. Throws a [FormatException] for a collection or a font
/// without OS/2 and `head` tables.
@visibleForTesting
Uint8List withOpenTypeWeightClass(Uint8List font, int weight) {
  final bytes = Uint8List.fromList(font);
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 12) throw const FormatException('Not an sfnt font.');
  final tag = String.fromCharCodes(bytes, 0, 4);
  if (tag == 'ttcf') {
    throw const FormatException('Font collections are not supported.');
  }

  int? os2Record;
  int? headRecord;
  final tableCount = data.getUint16(4);
  for (var i = 0; i < tableCount; i += 1) {
    final record = 12 + 16 * i;
    if (record + 16 > bytes.length) break;
    switch (String.fromCharCodes(bytes, record, record + 4)) {
      case 'OS/2':
        os2Record = record;
      case 'head':
        headRecord = record;
    }
  }
  if (os2Record == null || headRecord == null) {
    throw const FormatException('The font has no OS/2 or head table.');
  }

  final os2Offset = data.getUint32(os2Record + 8);
  final os2Length = data.getUint32(os2Record + 12);
  final headOffset = data.getUint32(headRecord + 8);
  if (os2Length < 6 || os2Offset + os2Length > bytes.length) {
    throw const FormatException('The OS/2 table is truncated.');
  }

  // usWeightClass follows version (uint16) and xAvgCharWidth (int16).
  data.setUint16(os2Offset + 4, weight);
  data.setUint32(os2Record + 4, _checksum(data, os2Offset, os2Length));

  // The adjustment is the value that makes the whole font sum to 0xB1B0AFBA.
  data.setUint32(headOffset + 8, 0);
  final total = _checksum(data, 0, bytes.length);
  data.setUint32(headOffset + 8, (0xB1B0AFBA - total) & 0xFFFFFFFF);
  return bytes;
}

/// Sum of the big-endian uint32 words of a range, zero padded to a multiple
/// of four bytes, modulo 2^32.
int _checksum(ByteData data, int offset, int length) {
  var sum = 0;
  final end = offset + length;
  var i = offset;
  for (; i + 4 <= end; i += 4) {
    sum = (sum + data.getUint32(i)) & 0xFFFFFFFF;
  }
  if (i < end) {
    var tail = 0;
    for (var shift = 24; i < end; i += 1, shift -= 8) {
      tail |= data.getUint8(i) << shift;
    }
    sum = (sum + tail) & 0xFFFFFFFF;
  }
  return sum;
}
