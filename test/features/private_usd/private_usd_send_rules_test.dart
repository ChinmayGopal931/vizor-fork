import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/address_book/models/address_format_validator.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_send.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_spend_guard.dart';
import 'package:zcash_wallet/src/rust/frb_generated.dart';
import 'package:zcash_wallet/widgetbook/private_usd_send_use_cases.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

/// Rust's `0zk` check, as the form reaches it (`private_usd_is_valid_railgun_
/// address`, a synchronous FRB call).
class _RailgunAddressRust implements RustLibApi {
  final valid = <String>{};
  final asked = <String>[];

  @override
  bool crateApiPrivateUsdPrivateUsdIsValidRailgunAddress({
    required String address,
  }) {
    asked.add(address);
    return valid.contains(address);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _rust = _RailgunAddressRust();
const _account = 'account-1';
const _checksummed = previewPrivateUsdWithdrawAddress;
const _zero = '0x0000000000000000000000000000000000000000';

void main() {
  setUpAll(() => RustLib.initMock(api: _rust));
  tearDownAll(RustLib.dispose);

  test('a 0zk recipient is whatever Rust accepts', () {
    _rust.valid.add(previewPrivateUsdRecipient);
    const mode = PrivateUsdSendMode.private;
    final to = privateUsdSendDestination(mode, ' $previewPrivateUsdRecipient ');
    expect(to, isA<RailgunPrivateDestination>());
    expect(to!.text, previewPrivateUsdRecipient);
    expect(_rust.asked, [previewPrivateUsdRecipient]);

    final truncated = previewPrivateUsdRecipient.substring(0, 40);
    expect(
      privateUsdRecipientError(mode, truncated),
      PrivateUsdCopy.sendInvalid0zk,
    );
    expect(_rust.asked.last, truncated);
    // A public address is no Railgun address; an empty field shows nothing.
    expect(
      privateUsdRecipientError(mode, _checksummed),
      PrivateUsdCopy.sendInvalid0zk,
    );
    expect(privateUsdRecipientError(mode, '  '), isNull);
  });

  test('a 0x recipient carries its EIP-55 checksum and is never the zero '
      'address; amounts follow the token and leave the network fee', () {
    expect(isValidEvmAddress(_checksummed), isTrue);
    expect(isValidEvmAddress(_checksummed.toLowerCase()), isTrue);
    // One letter's case flipped breaks the checksum.
    final mistyped = _checksummed.replaceFirst('aAeb', 'aaeb');
    expect(isValidEvmAddress(mistyped), isFalse);
    expect(isValidEvmAddress('0X${_checksummed.substring(2)}'), isFalse);
    expect(isValidEvmAddress(_zero), isFalse);
    expect(isZeroEvmAddress(_zero), isTrue);

    const mode = PrivateUsdSendMode.withdraw;
    expect(
      privateUsdSendDestination(mode, _checksummed),
      isA<RailgunPublicDestination>(),
    );
    expect(
      privateUsdRecipientError(mode, mistyped),
      PrivateUsdCopy.sendInvalid0x,
    );
    expect(
      privateUsdRecipientError(mode, _zero),
      PrivateUsdCopy.sendZeroAddress,
    );
    expect(
      privateUsdRecipientError(mode, previewPrivateUsdRecipient),
      PrivateUsdCopy.sendInvalid0x,
    );

    // $1,250.40 available; the relayer's floor, $0.50, stays behind.
    final balances = previewPrivateUsdSendBalances;
    PrivateUsdSendForm form(String amount) => PrivateUsdSendForm(
      mode: mode,
      token: previewPrivateUsdUsdc,
      amountText: amount,
      recipient: _checksummed,
      networkFee: PrivateUsdNetworkFee(
        token: previewPrivateUsdUsdc,
        minimum: BigInt.from(500000),
      ),
    );
    final asset = form('').asset(balances)!;
    expect(
      form('1.1234567').amountError(asset),
      PrivateUsdCopy.sendTooPrecise(6),
    );
    expect(form('1250.41').amountError(asset), PrivateUsdCopy.sendTooMuch);
    expect(
      form('1250.4').amountError(asset),
      PrivateUsdCopy.sendLeaveNetworkFee(r'$0.50'),
    );
    expect(form('1250.4').request(asset), isNull);
    expect(form('0.0').amountError(asset), isNull);
    final request = form('1249.9').request(asset);
    expect(request?.amount, BigInt.from(1249900000));
    expect(request?.isWithdrawal, isTrue);
    expect(
      privateUsdTokenText(form('').networkFee!.sendable(asset), 6),
      '1249.9',
    );
  });

  test('an unconfirmed send blocks the next payment across restarts', () async {
    // A send kept before the app restarted: a new guard reads it back.
    final kept = previewPrivateUsdSendRecord(confirmed: false);
    final guard = PrivateUsdSpendGuard(
      readLog: (_) async => [kept],
      unfinishedCount: (_) async => 0,
    );
    expect(guard.statusFor(_account), PrivateUsdSpendStatus.checking);
    await guard.check(_account);
    expect(guard.statusFor(_account), PrivateUsdSpendStatus.sending);
    var ran = false;
    Future<String> pay() async {
      ran = true;
      return 'paid';
    }

    final outcome = await guard.send(
      _account,
      pay,
      busy: (status) => 'busy ${status.name}',
      unreadable: () => 'unreadable',
    );
    expect(outcome, 'busy sending');
    await expectLater(
      guard.startConversion(_account, pay),
      throwsA(
        isA<PrivateUsdSpendBusyException>().having(
          (e) => e.status,
          'status',
          PrivateUsdSpendStatus.sending,
        ),
      ),
    );
    expect(ran, isFalse, reason: 'a payment started over an unsettled send');

    // Settled: free again. A conversion under way blocks a send (Rust's
    // count, read just before), never its own funding.
    guard.noteSends(_account, [previewPrivateUsdSendRecord()]);
    expect(guard.statusFor(_account), PrivateUsdSpendStatus.available);
    expect(
      guard.statusFor(_account, converting: true),
      PrivateUsdSpendStatus.converting,
    );
    final converting = PrivateUsdSpendGuard(
      readLog: (_) async => const [],
      unfinishedCount: (_) async => 1,
    );
    expect(
      await converting.send(
        _account,
        pay,
        busy: (status) => 'busy ${status.name}',
        unreadable: () => 'unreadable',
      ),
      'busy converting',
    );
    expect(ran, isFalse);
    expect(await converting.startConversion(_account, pay), 'paid');

    // A log that does not read keeps spending blocked.
    final garbled = PrivateUsdSpendGuard(
      readLog: (_) async => throw StateError('garbled'),
      retryAfter: const Duration(hours: 1),
    );
    await garbled.check(_account);
    expect(garbled.statusFor(_account), PrivateUsdSpendStatus.unreadable);
    expect(
      await garbled.send(
        _account,
        pay,
        busy: (status) => 'busy ${status.name}',
        unreadable: () => 'unreadable',
      ),
      'unreadable',
    );
    garbled.dispose();
  });
}
