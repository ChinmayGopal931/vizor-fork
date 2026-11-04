import '../../../providers/nym_broadcast_provider.dart';
import '../../swap/models/swap_status_presentation.dart';

/// What the light-wallet server saw for one of a bridge's ZEC transactions
/// (Free Society Hack, 2026-11-04): the Nym exit's address when the route
/// was Nym. Off Nym it says what is known without looking anything up: a Tor
/// exit, or the user's own address.
///
/// [showUnrecorded] adds a "Not recorded" row when this process did not
/// broadcast [displayTxid] (sent before a restart, or by someone else).
List<SwapStatusDetailRowData> privateUsdBroadcastRouteRows(
  String displayTxid, {
  bool showUnrecorded = true,
}) {
  final route = broadcastRouteForDisplayTxid(displayTxid);
  if (route == null) {
    if (!showUnrecorded) return const [];
    return const [
      SwapStatusDetailRowData(label: 'Server saw', value: 'Not recorded'),
    ];
  }
  switch (route.route) {
    case 'nym':
      final ip = route.exitIp ?? 'Unknown';
      final country = route.exitCountry;
      final seconds = (route.setupMillis.toInt() / 1000).round();
      return [
        SwapStatusDetailRowData(
          label: 'Server saw',
          value: country == null
              ? '$ip (Nym exit)'
              : '$ip (Nym exit, $country)',
          copyable: route.exitIp != null,
          copyText: route.exitIp,
        ),
        SwapStatusDetailRowData(
          label: 'Sent over',
          value: 'Nym mixnet, tunnel ${route.tunnelAttempt}, ${seconds}s',
        ),
      ];
    case 'tor':
      return const [
        SwapStatusDetailRowData(
          label: 'Server saw',
          value: 'A Tor exit, not your IP',
        ),
        SwapStatusDetailRowData(label: 'Sent over', value: 'Tor'),
      ];
    default:
      return const [
        SwapStatusDetailRowData(label: 'Server saw', value: 'Your IP address'),
        SwapStatusDetailRowData(label: 'Sent over', value: 'Direct connection'),
      ];
  }
}
