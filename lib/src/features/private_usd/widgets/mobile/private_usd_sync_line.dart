import '../../../../core/formatting/date_format.dart';
import '../../../../core/formatting/sync_status_label.dart';
import '../../../../core/layout/mobile/neon_sync_backdrop.dart';
import '../../../../providers/network_privacy_provider.dart';
import '../../private_usd_copy.dart';
import '../../services/private_usd_balance_repository.dart';

/// Railgun's sync as Home's sync line, for the Private USD screen (iOS
/// progress VI-19). It follows the balance's own syncs, on open and on
/// refresh; nothing here starts one.
///
/// - A first sync (nothing shown yet) climbs over the content with its
///   percentage, or reads "Tor …" while the page waits for Tor to come up.
/// - A wallet that synced before stays synced through a refresh, behind the
///   content, with the floor flowing: like Home's catch-up, the line never
///   drops to 0 and climbs again.
/// - A failure reads "Sync failed", or "Tor offline" when Tor failed.
///
/// Screen readers hear what the card used to show: the first-load progress,
/// "Updating…", the last update's time, or the failure.
NeonSyncLine privateUsdSyncLine(
  PrivateUsdBalanceState state, {
  NetworkPrivacyState? networkPrivacy,
}) {
  final balances = state.balances;
  if (state.refreshFailed && !state.isRefreshing) {
    final torFailed =
        networkPrivacy != null &&
        networkPrivacy.torRouteRetained &&
        networkPrivacy.status == NetworkPrivacyConnectionStatus.failed;
    return NeonSyncLine(
      progress: balances != null ? 0.99 : _climbed(state.firstSyncPercent ?? 0),
      readout: torFailed ? NeonSyncReadout.torOffline : NeonSyncReadout.failed,
      semanticsLabel: balances == null
          ? PrivateUsdCopy.loadFailed
          : PrivateUsdCopy.refreshFailed,
      failed: true,
    );
  }
  if (balances != null) {
    final updatedAt = state.updatedAt;
    return NeonSyncLine(
      progress: 1,
      readout: NeonSyncReadout.synced,
      semanticsLabel: state.isRefreshing
          ? PrivateUsdCopy.updating
          : updatedAt == null
          ? ''
          : PrivateUsdCopy.updated(formatDayMonthTime(updatedAt)),
      scanning: state.isRefreshing,
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
    );
  }
  final percent = state.firstSyncPercent;
  final whole = (percent ?? 0).clamp(0, 99);
  return NeonSyncLine(
    progress: _climbed(whole),
    readout: NeonSyncReadout.progress(whole),
    semanticsLabel: percent == null
        ? PrivateUsdCopy.firstLoad
        : PrivateUsdCopy.firstLoadProgress(whole),
    climbing: true,
  );
}

// As Home's: a climbing line always shows a stub, and never reaches the top.
double _climbed(int percent) => (percent / 100).clamp(0.03, 0.99);
