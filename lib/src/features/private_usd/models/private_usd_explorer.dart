import '../../../core/config/zcash_explorer.dart';

/// [txHash] on one of the deployment's explorers, after the prefix it pins
/// (Etherscan's or Railscan's); null without one.
Uri? privateUsdExplorerUri(String? explorerTxPrefix, String txHash) =>
    explorerTxPrefix == null ? null : Uri.tryParse('$explorerTxPrefix$txHash');

/// An explorer a Private USD transaction opens on.
enum PrivateUsdExplorer {
  /// Railgun's explorer, for an Ethereum transaction.
  railscan,
  etherscan,

  /// The wallet's own Zcash explorer (Settings).
  zcash,
}

/// Where Private USD's transactions open: an Ethereum one on Railscan and
/// Etherscan, at the prefixes the deployment pins for its chain (Sepolia's
/// on testnet, mainnet's on mainnet); a Zcash one on the wallet's explorer.
class PrivateUsdExplorers {
  const PrivateUsdExplorers({
    required this.zcashNetworkName,
    this.zcashExplorerTemplate = '',
    this.etherscanTxPrefix,
    this.railscanTxPrefix,
  });

  /// The deployment's; null without one.
  final String? etherscanTxPrefix;
  final String? railscanTxPrefix;
  final String zcashNetworkName;

  /// The wallet's explorer setting; empty for the default.
  final String zcashExplorerTemplate;

  /// [hash] on [explorer]: a Zcash one in the wallet's internal byte order,
  /// as records carry it. Null without the explorer, or for a setting that
  /// no longer reads.
  Uri? uri(String hash, PrivateUsdExplorer explorer) {
    switch (explorer) {
      case PrivateUsdExplorer.railscan:
        return privateUsdExplorerUri(railscanTxPrefix, hash);
      case PrivateUsdExplorer.etherscan:
        return privateUsdExplorerUri(etherscanTxPrefix, hash);
      case PrivateUsdExplorer.zcash:
        try {
          return zcashExplorerTransactionUri(
            networkName: zcashNetworkName,
            txidHex: hash,
            txidOrder: ZcashExplorerTxidOrder.protocol,
            customTemplate: zcashExplorerTemplate,
          );
        } on FormatException {
          return null;
        }
    }
  }
}
