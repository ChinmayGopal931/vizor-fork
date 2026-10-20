import '../../../../core/formatting/date_format.dart';
import '../../../../core/formatting/sync_status_label.dart';
import '../../../../core/layout/mobile/neon_sync_backdrop.dart';
import '../../../../providers/network_privacy_provider.dart';
import '../../models/private_usd_screening_status.dart';
import '../../private_usd_copy.dart';
import '../../services/private_usd_balance_repository.dart';

/// Railgun's sync as Home's sync line, for the Private USD screen (iOS
/// progress VI-19), standing where Home's does (owner, 2026-10-19). It
/// follows the balance's own syncs, on open and on refresh; nothing here
/// starts one.
///
/// - A first sync (nothing shown yet) climbs over the content with its
///   percentage ("Railgun sync n%"), or reads "Tor …" while the page waits
///   for Tor to come up.
/// - A wallet that synced before stays synced ("Railgun synced") through a
///   refresh, behind the content, with the floor flowing: like Home's
///   catch-up, the line never drops to 0 and climbs again. Except while the
///   page catches up on Railgun's transaction list ([txidCatchUp], which it
///   reports only 1,000 or more behind): screening a send's change waits on
///   that list, so it climbs with its percentage (owner, 2026-10-19). A
///   phone's list once sat 13,000 behind for days under "Railgun synced".
/// - A failure reads "Railgun sync failed", or "Tor offline" when Tor failed.
///
/// Screen readers hear what the card used to show: the first-load progress,
/// "Updating…", the last update's time, or the failure.
NeonSyncLine privateUsdSyncLine(
  PrivateUsdBalanceState state, {
  NetworkPrivacyState? networkPrivacy,
  double? txidCatchUp,
}) {
  final balances = state.balances;
  if (state.refreshFailed && !state.isRefreshing) {
    final torFailed =
        networkPrivacy != null &&
        networkPrivacy.torRouteRetained &&
        networkPrivacy.status == NetworkPrivacyConnectionStatus.failed;
    return NeonSyncLine(
      progress: balances != null ? 0.99 : _climbed(state.firstSyncPercent ?? 0),
      readout: torFailed
          ? NeonSyncReadout.torOffline
          : PrivateUsdCopy.syncReadoutFailed,
      semanticsLabel: balances == null
          ? PrivateUsdCopy.loadFailed
          : PrivateUsdCopy.refreshFailed,
      failed: true,
      readoutType: _railgunFailedReadout,
    );
  }
  if (balances != null && txidCatchUp != null && txidCatchUp < 1) {
    final whole = privateUsdScreeningPercent(txidCatchUp).clamp(0, 99);
    return NeonSyncLine(
      progress: _climbed(whole),
      readout: PrivateUsdCopy.syncReadoutProgress(whole),
      semanticsLabel: PrivateUsdCopy.screeningSyncingList(whole),
      climbing: true,
      readoutType: _railgunReadout,
    );
  }
  if (balances != null) {
    final updatedAt = state.updatedAt;
    return NeonSyncLine(
      progress: 1,
      readout: PrivateUsdCopy.syncReadoutSynced,
      semanticsLabel: state.isRefreshing
          ? PrivateUsdCopy.updating
          : updatedAt == null
          ? ''
          : PrivateUsdCopy.updated(formatDayMonthTime(updatedAt)),
      scanning: state.isRefreshing,
      readoutType: _railgunReadout,
    );
  }
  // The page waits for the bridge, which waits out a Tor bootstrap.
  if (state.isRefreshing &&
      networkPrivacy != null &&
      torIsTargetRoute(networkPrivacy) &&
      networkPrivacy.status == NetworkPrivacyConnectionStatus.connecting) {
    return NeonSyncLine(
      progress: _climbed(0),
      readout: NeonSyncReadout.torWaiting,
      semanticsLabel: kSyncStatusConnectingToTorSemanticsLabel,
      climbing: true,
      readoutType: _railgunReadout,
    );
  }
  final percent = state.firstSyncPercent;
  final whole = (percent ?? 0).clamp(0, 99);
  return NeonSyncLine(
    progress: _climbed(whole),
    readout: PrivateUsdCopy.syncReadoutProgress(whole),
    semanticsLabel: percent == null
        ? PrivateUsdCopy.firstLoad
        : PrivateUsdCopy.firstLoadProgress(whole),
    climbing: true,
    readoutType: _railgunReadout,
  );
}

// As Home's: a climbing line always shows a stub, and never reaches the top.
double _climbed(int percent) => (percent / 100).clamp(0.03, 0.99);

// Smaller than Home's, so the longer Railgun readouts end above the total
// card, which starts close under the top; the failure, the longest, smaller
// still (owner, 2026-10-18).
const _railgunReadout = (fontSize: 7.0, letterSpacing: 1.4);
const _railgunFailedReadout = (fontSize: 5.5, letterSpacing: 0.8);
