import '../../../../core/formatting/date_format.dart';
import '../../../../core/formatting/sync_status_label.dart';
import '../../../../core/layout/mobile/neon_sync_backdrop.dart';
import '../../../../providers/network_privacy_provider.dart';
import '../../models/private_usd_screening_status.dart';
import '../../private_usd_copy.dart';
import '../../services/private_usd_balance_repository.dart';

/// Railgun's sync drawn as Home's sync line, for the Private USD screen. It
/// follows the balance's own syncs, on open and on refresh; nothing here
/// starts one.
///
/// A first sync climbs over the content with its percentage, or the Tor
/// readout while the page waits for Tor. A wallet that synced before stays
/// synced through a refresh, as Home's catch-up does, except while the page
/// catches up on Railgun's transaction list ([txidCatchUp], reported only
/// 1,000 or more behind): screening a send's change waits on that list, so
/// the line climbs with its percentage. Screen readers hear the first load's
/// progress, the update, the last update's time, or the failure.
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
      progress: balances != null
          ? _climbTop
          : _climbed(state.firstSyncPercent ?? 0),
      readout: torFailed
          ? NeonSyncReadout.torOffline
          : PrivateUsdCopy.syncReadoutFailed,
      semanticsLabel: balances == null
          ? PrivateUsdCopy.loadFailed
          : PrivateUsdCopy.refreshFailed,
      failed: true,
      readoutStyle: _railgunFailedReadout,
    );
  }
  if (balances != null && txidCatchUp != null && txidCatchUp < 1) {
    final whole = privateUsdScreeningPercent(txidCatchUp).clamp(0, 99);
    return NeonSyncLine(
      progress: _climbed(whole),
      readout: PrivateUsdCopy.syncReadoutProgress(whole),
      semanticsLabel: PrivateUsdCopy.screeningSyncingList(whole),
      climbing: true,
      readoutStyle: _railgunReadout,
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
      readoutStyle: _railgunReadout,
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
      readoutStyle: _railgunReadout,
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
    readoutStyle: _railgunReadout,
  );
}

// As Home's: a climbing line always shows a stub, and never reaches the top.
const _climbStub = 0.03;
const _climbTop = 0.99;

double _climbed(int percent) => (percent / 100).clamp(_climbStub, _climbTop);

// Smaller than Home's, so the longer Railgun readouts end above the total
// card, which starts close under the top; the failure, the longest, smaller
// still.
final _railgunReadout = kNeonSyncReadoutStyle.copyWith(
  fontSize: 7,
  letterSpacing: 1.4,
);
final _railgunFailedReadout = kNeonSyncReadoutStyle.copyWith(
  fontSize: 5.5,
  letterSpacing: 0.8,
);
