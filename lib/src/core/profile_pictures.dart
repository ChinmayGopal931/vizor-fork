import 'l10n/l10n.dart';

const kDefaultProfilePictureId = 'pfp-01';
const _kProfilePictureAssetRoot = 'assets/profile_pictures';
final _legacyKnightVariantPattern = RegExp(r'^knight-(\d{2})$');
const _legacyKnightVariantMap = {'04': 'pfp-04', '05': 'pfp-05'};
const _legacyProfilePictureIdMap = {
  'knight': 'pfp-01',
  'viking': 'pfp-02',
  'samurai': 'pfp-03',
  'wizard': 'pfp-04',
  'chest': kDefaultProfilePictureId,
  'dragon': kDefaultProfilePictureId,
  'shield-1': kDefaultProfilePictureId,
  'shield-2': kDefaultProfilePictureId,
};

class ProfilePictureOption {
  const ProfilePictureOption({required this.id, required this.assetPath});

  final String id;
  final String assetPath;

  /// The character's name. The id (`pfp-01`) is what gets saved.
  String label(AppLocalizations l10n) =>
      l10n.profilePictureName('p${id.substring('pfp-'.length)}');
}

/// The neon portraits. Ids stay `pfp-NN` so stored accounts and contacts
/// keep theirs. Later portraits number on from `16`, since the retired
/// knights' ids (below) still land on the first seven.
const _kProfilePictureSuffixes = [
  '01',
  '02',
  '03',
  '04',
  '05',
  '06',
  '07',
  '16',
  '17',
  '18',
];

/// The knight set had fifteen pictures; a stored id from the retired eight
/// lands on a portrait of the new set, so nobody falls back to one default.
const _retiredProfilePictureIdMap = {
  'pfp-08': 'pfp-01',
  'pfp-09': 'pfp-02',
  'pfp-10': 'pfp-03',
  'pfp-11': 'pfp-04',
  'pfp-12': 'pfp-05',
  'pfp-13': 'pfp-06',
  'pfp-14': 'pfp-07',
  'pfp-15': 'pfp-01',
};

final kProfilePictureOptions = <ProfilePictureOption>[
  for (final suffix in _kProfilePictureSuffixes)
    ProfilePictureOption(
      id: 'pfp-$suffix',
      assetPath: '$_kProfilePictureAssetRoot/profile_picture_$suffix.webp',
    ),
];

ProfilePictureOption? findProfilePictureOption(String id) {
  final normalizedId = _knownProfilePictureId(id);
  if (normalizedId == null) return null;

  for (final option in kProfilePictureOptions) {
    if (option.id == normalizedId) return option;
  }
  return null;
}

ProfilePictureOption resolveProfilePictureOption(String id) {
  return findProfilePictureOption(id) ??
      findProfilePictureOption(kDefaultProfilePictureId)!;
}

String normalizeProfilePictureId(String id) {
  return findProfilePictureOption(id)?.id ?? kDefaultProfilePictureId;
}

bool isKnownProfilePictureId(String id) {
  return findProfilePictureOption(id) != null;
}

String? _knownProfilePictureId(String id) {
  final trimmed = id.trim();
  for (final option in kProfilePictureOptions) {
    if (option.id == trimmed) return option.id;
  }
  final retired = _retiredProfilePictureIdMap[trimmed];
  if (retired != null) return retired;
  final knightVariant = _legacyKnightVariantPattern.firstMatch(trimmed);
  if (knightVariant != null) {
    return _legacyKnightVariantMap[knightVariant.group(1)] ??
        kDefaultProfilePictureId;
  }
  return _legacyProfilePictureIdMap[trimmed];
}
