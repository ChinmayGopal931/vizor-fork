import '../../../../core/formatting/date_format.dart';
import '../../../../core/formatting/sync_status_label.dart';
import '../../../../core/l10n/l10n.dart';
import '../../../../core/layout/mobile/neon_sync_backdrop.dart';
import '../../../../providers/network_privacy_provider.dart';
import '../../models/private_usd_screening_status.dart';
import '../../services/private_usd_balance_repository.dart';

/// Railgun's sync drawn as Home's sync line, for the Private USD screen. It
/// follows the balance's own syncs, on open and on refresh; nothing here
/// starts one.
///
/// A first sync climbs over the content with its percentage, or the Tor
/// readout while the page waits for Tor. So does a refresh the user waits on
/// ([PrivateUsdBalanceState.refreshPercent]: one asked for, or the screen's
/// own as it opens), with the page's progress. A wallet that synced before
/// stays synced through the automatic refreshes, as Home's catch-up does,
/// except while the page catches up on Railgun's transaction list
/// ([txidCatchUp], reported only 1,000 or more behind): screening a send's
/// change waits on that list, so the line climbs with its percentage. Screen
/// readers hear the load's or the update's progress, the update, the last
/// update's time, or the failure.
NeonSyncLine privateUsdSyncLine(
  AppLocalizations l10n,
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
          ? NeonSyncReadout.torOffline(l10n)
          : l10n.privateUsdSyncReadoutFailed,
      semanticsLabel: balances == null
          ? l10n.privateUsdLoadFailed
          : l10n.privateUsdRefreshFailed,
      failed: true,
      readoutStyle: _railgunFailedReadout,
    );
  }
  final refreshPercent = state.refreshPercent;
  if (balances != null && refreshPercent != null && state.isRefreshing) {
    if (refreshPercent == 0 && _waitsForTor(networkPrivacy)) {
      return _torWaiting(l10n);
    }
    final whole = refreshPercent.clamp(0, 99);
    return NeonSyncLine(
      progress: _climbed(whole),
      readout: l10n.privateUsdSyncReadoutProgress(whole),
      semanticsLabel: l10n.privateUsdUpdatingProgress(whole),
      climbing: true,
      readoutStyle: _railgunReadout,
    );
  }
  if (balances != null && txidCatchUp != null && txidCatchUp < 1) {
    final whole = privateUsdScreeningPercent(txidCatchUp).clamp(0, 99);
    return NeonSyncLine(
      progress: _climbed(whole),
      readout: l10n.privateUsdSyncReadoutProgress(whole),
      semanticsLabel: l10n.privateUsdScreeningSyncingList(whole),
      climbing: true,
      readoutStyle: _railgunReadout,
    );
  }
  if (balances != null) {
    final updatedAt = state.updatedAt;
    return NeonSyncLine(
      progress: 1,
      readout: l10n.privateUsdSyncReadoutSynced,
      semanticsLabel: state.isRefreshing
          ? l10n.privateUsdUpdating
          : updatedAt == null
          ? ''
          : l10n.privateUsdUpdated(
              formatDayMonthTime(updatedAt, l10n.localeName),
            ),
      scanning: state.isRefreshing,
      readoutStyle: _railgunReadout,
    );
  }
  if (state.isRefreshing && _waitsForTor(networkPrivacy)) {
    return _torWaiting(l10n);
  }
  final percent = state.firstSyncPercent;
  final whole = (percent ?? 0).clamp(0, 99);
  return NeonSyncLine(
    progress: _climbed(whole),
    readout: l10n.privateUsdSyncReadoutProgress(whole),
    semanticsLabel: percent == null
        ? l10n.privateUsdFirstLoad
        : l10n.privateUsdFirstLoadProgress(whole),
    climbing: true,
    readoutStyle: _railgunReadout,
  );
}

// The page waits for the bridge, which waits out a Tor bootstrap.
bool _waitsForTor(NetworkPrivacyState? networkPrivacy) =>
    networkPrivacy != null &&
    torIsTargetRoute(networkPrivacy) &&
    networkPrivacy.status == NetworkPrivacyConnectionStatus.connecting;

NeonSyncLine _torWaiting(AppLocalizations l10n) => NeonSyncLine(
  progress: _climbed(0),
  readout: NeonSyncReadout.torWaiting(l10n),
  semanticsLabel: l10n.syncConnectingToTorSemantics,
  climbing: true,
  readoutStyle: _railgunReadout,
);

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
