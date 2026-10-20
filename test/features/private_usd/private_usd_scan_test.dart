import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/address_scan/widgets/mobile_address_scan_view.dart'
    show MobileScanOutcome;
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_scan.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_send.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/widgetbook/private_usd_send_use_cases.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// The send form's scanner takes a 0zk address to send privately and a 0x one
// to withdraw, as typed ones are taken. An ethereum: request gives up its
// recipient, never its token, and one for another chain is refused.
void main() {
  const mainnet = 1;
  const zeroAddress = '0x0000000000000000000000000000000000000000';
  // USDC's contract on Ethereum, as a token transfer request names it.
  const token = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';

  MobileScanOutcome scan(
    String raw, {
    PrivateUsdSendMode mode = PrivateUsdSendMode.private,
    int? chainId = mainnet,
  }) => privateUsdScanOutcome(
    raw,
    mode: mode,
    chainId: chainId,
    isRailgunAddress: previewPrivateUsdIsRailgunAddress,
  );

  void expectAccepted(MobileScanOutcome outcome, String address) {
    expect(outcome.isAccepted, isTrue, reason: outcome.error);
    expect(outcome.address, address);
  }

  void expectRejected(MobileScanOutcome outcome, String error) {
    expect(outcome.isAccepted, isFalse);
    expect(outcome.error, error);
  }

  group('Send', () {
    test('takes a 0zk address, as the Receive sheet shows it', () {
      expectAccepted(
        scan(' $previewPrivateUsdRecipient\n'),
        previewPrivateUsdRecipient,
      );
    });

    test('takes a 0zk address a code carries in capitals', () {
      expectAccepted(
        scan(previewPrivateUsdRecipient.toUpperCase()),
        previewPrivateUsdRecipient,
      );
    });

    test('points a 0x address to Withdraw', () {
      expectRejected(
        scan(previewPrivateUsdEthereumAddress),
        PrivateUsdCopy.scanUseWithdraw,
      );
      expectRejected(
        scan('ethereum:$previewPrivateUsdEthereumAddress@1'),
        PrivateUsdCopy.scanUseWithdraw,
      );
    });

    test('refuses what is no address', () {
      expectRejected(scan('hello'), PrivateUsdCopy.scanNot0zk);
      expectRejected(
        scan(previewPrivateUsdRecipient.substring(0, 40)),
        PrivateUsdCopy.scanNot0zk,
      );
    });
  });

  group('Withdraw', () {
    const withdraw = PrivateUsdSendMode.withdraw;

    test('takes a 0x address, plain or as an ethereum: request', () {
      for (final raw in [
        previewPrivateUsdEthereumAddress,
        'ethereum:$previewPrivateUsdEthereumAddress',
        'ethereum:$previewPrivateUsdEthereumAddress@1',
        'ethereum:pay-$previewPrivateUsdEthereumAddress@1',
      ]) {
        expectAccepted(
          scan(raw, mode: withdraw),
          previewPrivateUsdEthereumAddress,
        );
      }
    });

    test("takes a token transfer's recipient, never the token", () {
      expectAccepted(
        scan(
          'ethereum:$token@1/transfer?address='
          '$previewPrivateUsdEthereumAddress&uint256=1000000',
          mode: withdraw,
        ),
        previewPrivateUsdEthereumAddress,
      );
    });

    test('refuses a request for another chain', () {
      expectRejected(
        scan('ethereum:$previewPrivateUsdEthereumAddress@137', mode: withdraw),
        PrivateUsdCopy.scanOtherNetwork,
      );
      expectRejected(
        scan(
          'ethereum:$token@137/transfer?address='
          '$previewPrivateUsdEthereumAddress',
          mode: withdraw,
        ),
        PrivateUsdCopy.scanOtherNetwork,
      );
      // Testnet's deployment is on Sepolia.
      expectAccepted(
        scan(
          'ethereum:$previewPrivateUsdEthereumAddress@11155111',
          mode: withdraw,
          chainId: 11155111,
        ),
        previewPrivateUsdEthereumAddress,
      );
    });

    test('points a 0zk address to Send', () {
      expectRejected(
        scan(previewPrivateUsdRecipient, mode: withdraw),
        PrivateUsdCopy.scanUseSend,
      );
    });

    test(
      'refuses the zero address, a bad checksum, and what is no address',
      () {
        expectRejected(
          scan(zeroAddress, mode: withdraw),
          PrivateUsdCopy.sendZeroAddress,
        );
        // One letter's case flipped: the EIP-55 checksum fails.
        expectRejected(
          scan(
            previewPrivateUsdEthereumAddress.replaceFirst('a', 'A'),
            mode: withdraw,
          ),
          PrivateUsdCopy.scanNot0x,
        );
        expectRejected(
          scan(
            'bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq',
            mode: withdraw,
          ),
          PrivateUsdCopy.scanNot0x,
        );
        // An escape that does not decode is refused, not thrown.
        expectRejected(
          scan('ethereum:$token@1/transfer?address=%FF', mode: withdraw),
          PrivateUsdCopy.scanNot0x,
        );
      },
    );
  });
}
