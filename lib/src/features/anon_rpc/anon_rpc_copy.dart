/// Every user-facing Anonymous RPC string, sentence case, in one place.
abstract final class AnonRpcCopy {
  static const title = 'Anonymous RPC';
  static const body =
      'Every Ethereum request Shielded USD makes goes through an anonymizing '
      'network, so the RPC provider never sees your IP address. The network\'s '
      'code is checked against a hash kept on chain before it runs.';
  static const excluded =
      'Zcash, the screening nodes and the swap services keep their own route.';
  static const update = 'Update';
  static String saved(String network) => 'Anonymous RPC: $network';
  static const savedOff = 'Anonymous RPC off';
  static const saveFailed = "Couldn't update Anonymous RPC.";

  // The Settings row's status, after the network's name.
  static const statusOff = 'off';
  static const statusIdle = 'ready when needed';
  static const statusConnecting = 'connecting…';
  static const statusOn = 'on';
  static const statusFailed = 'not connected';

  static String rowValue(String network, String status) => '$network · $status';
  static String relayed(int count) => switch (count) {
    0 => 'No requests relayed yet',
    1 => '1 request relayed',
    _ => '$count requests relayed',
  };
}
