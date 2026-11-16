import '../private_usd_copy.dart';
import 'private_usd_balances.dart';
import 'railgun_models.dart';
import '../../../core/l10n/l10n.dart';

/// The Processing row's live line: what the page's screening work is doing
/// now, the step furthest along first, or else what the funds wait on. Null
/// when there is nothing to say.
String? privateUsdScreeningStatus(
  AppLocalizations l10n, {
  required RailgunScreeningEvent? activity,
  required PrivateUsdBalances balances,
}) {
  final proving = activity?.proving;
  if (proving != null) {
    return PrivateUsdCopy.screeningProving(
      l10n,
      proving.index,
      proving.count,
      privateUsdScreeningPercent(proving.progress),
    );
  }
  if (activity != null && activity.downloading) {
    final share = activity.download;
    return PrivateUsdCopy.screeningDownloading(
      l10n,
      share == null ? null : privateUsdScreeningPercent(share),
    );
  }
  final txids = activity?.txids;
  if (txids != null) {
    return l10n.privateUsdScreeningSyncingList(
      privateUsdScreeningPercent(txids),
    );
  }
  final checks = activity?.checks;
  if (checks != null) {
    return l10n.privateUsdScreeningChecking(checks.done, checks.count);
  }
  if (balances.submitted > BigInt.zero) return l10n.privateUsdScreeningWaiting;
  return null;
}

/// A share as a whole percent, rounded down and kept at 99 until it is done,
/// so it never claims done early.
int privateUsdScreeningPercent(double share) =>
    share >= 1 ? 100 : (share * 100).floor().clamp(0, 99);
