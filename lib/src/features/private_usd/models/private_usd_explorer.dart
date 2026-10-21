/// [txHash] on the deployment's Ethereum explorer ([explorerTxPrefix]);
/// null without one.
Uri? privateUsdExplorerUri(String? explorerTxPrefix, String txHash) =>
    explorerTxPrefix == null ? null : Uri.tryParse('$explorerTxPrefix$txHash');
