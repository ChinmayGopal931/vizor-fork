import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/profile_pictures.dart';

void main() {
  test(
    'profile picture options use stable ids and labels in display order',
    () {
      // The seven neon portraits; ids stay `pfp-NN` so stored picks survive.
      expect(kProfilePictureOptions, hasLength(7));
      expect(kProfilePictureOptions.map((option) => option.id), [
        'pfp-01',
        'pfp-02',
        'pfp-03',
        'pfp-04',
        'pfp-05',
        'pfp-06',
        'pfp-07',
      ]);
      expect(kProfilePictureOptions.map((option) => option.label), [
        'Light cycle',
        'Halo',
        'Red line',
        'Crosshair',
        'Scanner',
        'Goggles',
        'Frame',
      ]);
      expect(
        kProfilePictureOptions.first.assetPath,
        'assets/profile_pictures/profile_picture_01.webp',
      );
    },
  );

  test('findProfilePictureOption resolves numbered ids', () {
    final option = findProfilePictureOption('pfp-02');

    expect(option, isNotNull);
    expect(option!.id, 'pfp-02');
    expect(option.label, 'Halo');
    expect(option.assetPath, 'assets/profile_pictures/profile_picture_02.webp');
  });

  test('retired knight ids land on a portrait of the new set', () {
    expect(
      {
        for (final id in [
          'pfp-08',
          'pfp-09',
          'pfp-10',
          'pfp-11',
          'pfp-12',
          'pfp-13',
          'pfp-14',
          'pfp-15',
        ])
          id: normalizeProfilePictureId(id),
      },
      {
        'pfp-08': 'pfp-01',
        'pfp-09': 'pfp-02',
        'pfp-10': 'pfp-03',
        'pfp-11': 'pfp-04',
        'pfp-12': 'pfp-05',
        'pfp-13': 'pfp-06',
        'pfp-14': 'pfp-07',
        'pfp-15': 'pfp-01',
      },
    );
    expect(isKnownProfilePictureId('pfp-15'), isTrue);
    expect(resolveProfilePictureOption('pfp-09').id, 'pfp-02');
  });

  test('legacy semantic ids normalize to the closest numbered option', () {
    expect(normalizeProfilePictureId('knight'), 'pfp-01');
    expect(normalizeProfilePictureId('knight-04'), 'pfp-04');
    expect(normalizeProfilePictureId('knight-05'), 'pfp-05');
    expect(normalizeProfilePictureId('samurai'), 'pfp-03');
    expect(normalizeProfilePictureId('viking'), 'pfp-02');
    // The wizard was the retired pfp-11, which now lands on pfp-04.
    expect(normalizeProfilePictureId('wizard'), 'pfp-04');
    expect(resolveProfilePictureOption('samurai').id, 'pfp-03');
  });

  test('legacy ids without a clear successor normalize to default', () {
    expect(normalizeProfilePictureId('chest'), kDefaultProfilePictureId);
    expect(normalizeProfilePictureId('dragon'), kDefaultProfilePictureId);
    expect(normalizeProfilePictureId('shield-1'), kDefaultProfilePictureId);
    expect(normalizeProfilePictureId('shield-2'), kDefaultProfilePictureId);
  });

  test('malformed ids normalize to default and are not known options', () {
    expect(findProfilePictureOption('knight-'), isNull);
    expect(findProfilePictureOption('knight-2'), isNull);
    expect(findProfilePictureOption('pfp-2'), isNull);
    expect(findProfilePictureOption('unknown'), isNull);
    expect(normalizeProfilePictureId('unknown'), kDefaultProfilePictureId);
  });
}
