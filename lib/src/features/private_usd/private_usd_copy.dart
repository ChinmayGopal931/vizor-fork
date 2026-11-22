import '../../core/l10n/l10n.dart';

/// Shielded USD text that is not a single message: names and formats that
/// are never translated, and the messages that choose between keys. Every
/// other string is an ARB message whose key starts with `privateUsd`.
/// "Shielded USD" is the feature's name: capitalized at the start of a
/// sentence and as a title, "shielded USD" mid-sentence.
abstract final class PrivateUsdCopy {
  static const unknown = '—';
  static const usdcSymbol = 'USDC'; // l10n-ignore: currency ticker
  static const ethereum = 'Ethereum'; // l10n-ignore: product name
  static const tokenUsdc = 'USD Coin'; // l10n-ignore: product name
  static const explorerRailscan = 'Railscan'; // l10n-ignore: product name
  static const explorerEtherscan = 'Etherscan'; // l10n-ignore: product name
  static const convertAssetZec = 'ZEC'; // l10n-ignore: currency ticker
  static const rpcNetworkSepolia = 'Sepolia'; // l10n-ignore: product name
  static const sendHintPrivate = '0zk1…'; // l10n-ignore: address format
  static const sendHintWithdraw = '0x…'; // l10n-ignore: address format
  static const rpcHint = 'https://'; // l10n-ignore: URL scheme

  static String receiveShieldedTab(String symbol) =>
      '0zk$symbol'; // l10n-ignore: currency ticker
  static String homeZecEquivalent(String zec) =>
      '≈ $zec ZEC'; // l10n-ignore: amount format

  /// An amount known only roughly: "≈ 0.25 ZEC".
  static String approximately(String amount) =>
      '≈ $amount'; // l10n-ignore: amount format
  static String activityIn(String usd) => '+$usd';
  static String activityOut(String usd) => '−$usd';
  static String activityDetail(String a, String b) => '$a · $b';

  /// A ZEC amount's market value, on its panel's right: "(≈ $9.80)".
  static String convertMarketValue(String usd) => '(≈ $usd)';

  static String about(AppLocalizations l10n, Duration duration) {
    final minutes = duration.inMinutes < 1 ? 1 : duration.inMinutes;
    return minutes < 60
        ? l10n.privateUsdAboutMinutes(minutes)
        : l10n.privateUsdAboutHours(minutes ~/ 60);
  }

  /// [percent] is null while the files' size is unknown.
  static String screeningDownloading(AppLocalizations l10n, int? percent) =>
      percent == null
      ? l10n.privateUsdScreeningDownloading
      : l10n.privateUsdScreeningDownloadingPercent(percent);

  static String screeningProving(
    AppLocalizations l10n,
    int index,
    int count,
    int percent,
  ) => count > 1
      ? l10n.privateUsdScreeningProvingStep(index, count, percent)
      : l10n.privateUsdScreeningProving(percent);

  /// The rest of a long sync, once the balance shows: Railgun's transaction
  /// list, which the change from the wallet's own sends waits on.
  static String syncingRest(AppLocalizations l10n, int? percent) =>
      percent == null
      ? l10n.privateUsdSyncingRest
      : l10n.privateUsdSyncingRestPercent(percent);
}

/// Text that a provider, a result or an error keeps until a widget shows it,
/// in that widget's language.
typedef PrivateUsdText = String Function(AppLocalizations l10n);
