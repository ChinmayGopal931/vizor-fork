import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/gotham_fonts.dart';

/// Checksum written differently from the implementation under test: each byte
/// is shifted into its position in the 32-bit word.
int _sum(Uint8List bytes, int start, int length) {
  var sum = 0;
  for (var i = 0; i < length; i += 1) {
    sum += bytes[start + i] << (8 * (3 - (i % 4)));
  }
  return sum & 0xFFFFFFFF;
}

/// A minimal sfnt with OS/2 and head tables and valid checksums.
Uint8List _syntheticFont({required int weight}) {
  const os2Offset = 44;
  const os2Length = 96;
  const headOffset = os2Offset + os2Length;
  const headLength = 54;
  final bytes = Uint8List(headOffset + 56);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0x4F54544F); // 'OTTO'
  data.setUint16(4, 2);
  void record(int index, String tag, int offset, int length) {
    final at = 12 + 16 * index;
    bytes.setRange(at, at + 4, tag.codeUnits);
    data.setUint32(at + 8, offset);
    data.setUint32(at + 12, length);
  }

  record(0, 'OS/2', os2Offset, os2Length);
  record(1, 'head', headOffset, headLength);
  for (var i = 0; i < os2Length; i += 1) {
    bytes[os2Offset + i] = (i * 7 + 3) & 0xFF;
  }
  for (var i = 0; i < headLength; i += 1) {
    bytes[headOffset + i] = (i * 5 + 1) & 0xFF;
  }
  data.setUint16(os2Offset + 4, weight);
  data.setUint32(headOffset + 8, 0);
  data.setUint32(12 + 4, _sum(bytes, os2Offset, os2Length));
  data.setUint32(28 + 4, _sum(bytes, headOffset, headLength));
  data.setUint32(
    headOffset + 8,
    (0xB1B0AFBA - _sum(bytes, 0, bytes.length)) & 0xFFFFFFFF,
  );
  return bytes;
}

void _expectValidChecksums(Uint8List font) {
  final data = ByteData.sublistView(font);
  final os2Offset = data.getUint32(12 + 8);
  final os2Length = data.getUint32(12 + 12);
  expect(data.getUint32(12 + 4), _sum(font, os2Offset, os2Length));

  final headOffset = data.getUint32(28 + 8);
  final headLength = data.getUint32(28 + 12);
  final adjustment = data.getUint32(headOffset + 8);
  final head = Uint8List.fromList(font);
  ByteData.sublistView(head).setUint32(headOffset + 8, 0);
  expect(data.getUint32(28 + 4), _sum(head, headOffset, headLength));
  expect(_sum(font, 0, font.length), 0xB1B0AFBA, reason: 'whole-font sum');
  expect(adjustment, isNot(0));
}

class _MissingBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) =>
      Future.error(FlutterError('missing asset $key'));
}

void main() {
  test('withOpenTypeWeightClass changes only the weight and checksums', () {
    final original = _syntheticFont(weight: 325);
    _expectValidChecksums(original);

    final patched = withOpenTypeWeightClass(original, 400);

    _expectValidChecksums(patched);
    expect(ByteData.sublistView(patched).getUint16(44 + 4), 400);
    final changed = <int>{
      for (var i = 0; i < original.length; i += 1)
        if (original[i] != patched[i]) i,
    };
    final allowed = <int>{
      44 + 4, 44 + 5, // OS/2 usWeightClass
      12 + 4, 12 + 5, 12 + 6, 12 + 7, // OS/2 directory checksum
      140 + 8, 140 + 9, 140 + 10, 140 + 11, // head checkSumAdjustment
    };
    expect(allowed.containsAll(changed), isTrue, reason: '$changed');
    expect(changed, containsAll([44 + 5]));
    expect(original, isNot(same(patched)));
  });

  test('withOpenTypeWeightClass rejects fonts it cannot patch', () {
    expect(
      () => withOpenTypeWeightClass(Uint8List(4), 400),
      throwsFormatException,
    );
    final collection = Uint8List(64)..setRange(0, 4, 'ttcf'.codeUnits);
    expect(
      () => withOpenTypeWeightClass(collection, 400),
      throwsFormatException,
    );
    final noTables = Uint8List(64);
    expect(() => withOpenTypeWeightClass(noTables, 400), throwsFormatException);
  });

  // Runs before the real load: a failed load must not stick.
  testWidgets('a failed load can be retried', (tester) async {
    await expectLater(
      loadGothamFonts(bundle: _MissingBundle()),
      throwsA(isA<FlutterError>()),
    );
  });

  testWidgets('each FontWeight resolves to the intended Gotham face', (
    tester,
  ) async {
    const sample = 'Hamburgefonstiv 0123456789 Quick';
    double widthOf(String family, FontWeight weight) {
      final painter = TextPainter(
        text: TextSpan(
          text: sample,
          style: TextStyle(
            fontFamily: family,
            fontWeight: weight,
            fontSize: 100,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      return painter.width;
    }

    // Each file under its own family: the width a given face renders at,
    // whatever its weight class says.
    const faces = {
      'Thin': 'Gotham-Thin.otf',
      'Light': 'Gotham-Light.otf',
      'Book': 'Gotham-Book.otf',
      'Medium': 'Gotham-Medium.otf',
      'Bold': 'Gotham-Bold.otf',
      'Black': 'Gotham-Black.otf',
      'Ultra': 'Gotham-Ultra.otf',
    };
    final reference = <String, double>{};
    for (final entry in faces.entries) {
      final family = 'GothamReference${entry.key}';
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/${entry.value}'))).load();
      reference[entry.key] = widthOf(family, FontWeight.w400);
    }
    expect(
      reference.values.toSet(),
      hasLength(faces.length),
      reason: 'the sample must tell the faces apart',
    );

    await loadGothamFonts();
    await loadGothamFonts(); // idempotent

    final expected = <FontWeight, String>{
      FontWeight.w100: 'Thin',
      FontWeight.w200: 'Thin',
      FontWeight.w300: 'Light',
      FontWeight.w400: 'Book',
      FontWeight.w500: 'Medium',
      FontWeight.w600: 'Bold',
      FontWeight.w700: 'Bold',
      FontWeight.w800: 'Black',
      FontWeight.w900: 'Ultra',
    };
    for (final entry in expected.entries) {
      expect(
        widthOf(kGothamFamily, entry.key),
        closeTo(reference[entry.value]!, 0.001),
        reason: '${entry.key} should render as Gotham ${entry.value}',
      );
    }
  });
}
