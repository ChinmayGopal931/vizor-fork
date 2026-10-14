/// What a wallet's private dollars are doing (zapp `PrivateUsdSpendGuard`,
/// reference §6.7): one outgoing Railgun payment at a time per wallet,
/// conversions included (plan §3.5, invariant 16).
///
/// As built in M6 it is minimal: it knows only the payments running now in
/// this process, which are reverse fundings (`converting`). M7 extends it
/// with sends (`sending`) and with the send log, which carries an unsettled
/// send across restarts (`checking`, `unreadable`). A funding needs no such
/// record: once Rust keeps it, the loop follows it and it is never proved
/// again.
enum PrivateUsdSpendStatus {
  checking,
  available,
  sending,
  converting,
  unreadable,
}

/// Another outgoing payment of the wallet is under way: nothing was started.
class PrivateUsdSpendBusyException implements Exception {
  const PrivateUsdSpendBusyException(this.status);

  final PrivateUsdSpendStatus status;

  @override
  String toString() => 'A private USD payment is already under way.';
}

/// One outgoing Railgun payment at a time per wallet (one Railgun wallet per
/// software account, D6).
class PrivateUsdSpendGuard {
  final _spending = <String, PrivateUsdSpendStatus>{};

  /// [accountUuid]'s wallet now.
  PrivateUsdSpendStatus statusFor(String accountUuid) =>
      _spending[accountUuid] ?? PrivateUsdSpendStatus.available;

  /// Whether a conversion may start paying now.
  bool canStartConversion(String accountUuid) =>
      statusFor(accountUuid) == PrivateUsdSpendStatus.available;

  /// Runs [pay], a conversion's funding, as the wallet's one outgoing
  /// payment; throws [PrivateUsdSpendBusyException] while another runs.
  Future<T> startConversion<T>(
    String accountUuid,
    Future<T> Function() pay,
  ) async {
    final current = statusFor(accountUuid);
    if (current != PrivateUsdSpendStatus.available) {
      throw PrivateUsdSpendBusyException(current);
    }
    _spending[accountUuid] = PrivateUsdSpendStatus.converting;
    try {
      return await pay();
    } finally {
      _spending.remove(accountUuid);
    }
  }
}
