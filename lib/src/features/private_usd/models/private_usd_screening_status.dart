import '../private_usd_copy.dart';
import 'private_usd_balances.dart';
import 'railgun_models.dart';

/// The Processing row's live line (owner, 2026-10-19): what the page's
/// screening work is doing now, the step furthest along first, or else what
/// the funds wait on. Null when there is nothing to say.
String? privateUsdScreeningStatus({
  required RailgunScreeningEvent? activity,
  required PrivateUsdBalances balances,
}) {
  final proving = activity?.proving;
  if (proving != null) {
    return PrivateUsdCopy.screeningProving(
      proving.index,
      proving.count,
      privateUsdScreeningPercent(proving.progress),
    );
  }
  if (activity != null && activity.downloading) {
    final share = activity.download;
    return PrivateUsdCopy.screeningDownloading(
      share == null ? null : privateUsdScreeningPercent(share),
    );
  }
  final txids = activity?.txids;
  if (txids != null) {
    return PrivateUsdCopy.screeningSyncingList(
      privateUsdScreeningPercent(txids),
    );
  }
  if (balances.submitted > BigInt.zero) return PrivateUsdCopy.screeningWaiting;
  return null;
}

/// A share as a whole percent, rounded down and kept at 99 until it is done,
/// so it never claims done early.
int privateUsdScreeningPercent(double share) =>
    share >= 1 ? 100 : (share * 100).floor().clamp(0, 99);
