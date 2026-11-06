/// Every user-facing Anonymous RPC string, sentence case, in one place.
abstract final class AnonRpcCopy {
  /// The route section of Settings' Ethereum RPC sheet.
  static const routeHeading = 'Route';
  static const routeBody = "How Shielded USD's Ethereum requests travel.";
  static const saveFailed = "Couldn't change the route.";

  // The worker's status, after the network's name.
  static const statusIdle = 'ready when needed';
  static const statusConnecting = 'connecting…';
  static const statusOn = 'on';
  static const statusFailed = 'not connected';

  static String joined(String first, String second) => '$first · $second';
  static String relayed(int count) => switch (count) {
    0 => 'No requests relayed yet',
    1 => '1 request relayed',
    _ => '$count requests relayed',
  };
}
