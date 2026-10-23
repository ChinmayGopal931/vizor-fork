import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/zcash_explorer.dart';
import 'package:zcash_wallet/src/core/formatting/address_display.dart';
import 'package:zcash_wallet/src/core/formatting/date_format.dart';
import 'package:zcash_wallet/src/core/formatting/zec_amount.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_activity_details.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_explorer.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_messages.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_reverse_use_cases.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// A Private USD activity row unfolds into what its record already holds, and
// its transactions open on the explorers of the deployment's chain.
void main() {
  // Each line as it reads: "label: value", a transaction as "label: hash on
  // its explorers".
  List<String> read(List<PrivateUsdActivityDetail> lines) => [
    for (final line in lines)
      switch (line) {
        PrivateUsdDetailNote(:final text) => text,
        PrivateUsdDetailValue(:final label, :final value) => '$label: $value',
        PrivateUsdDetailTransaction(
          :final label,
          :final hash,
          :final explorers,
        ) =>
          '$label: $hash on ${explorers.map((e) => e.name).join(', ')}',
      },
  ];

  String time(int seconds) =>
      formatDayMonthTime(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));

  String zec(int zatoshi) =>
      ZecAmount.fromZatoshi(BigInt.from(zatoshi)).activity.toString();

  test('a send: its recipient, copied whole, its amounts, status and '
      'transaction', () {
    final record = previewPrivateUsdSendRecord();
    final lines = privateUsdSendDetails(record);

    expect(read(lines), [
      '${PrivateUsdCopy.sendReviewTo}: '
          '${truncatedAddress(previewPrivateUsdRecipient)}',
      '${PrivateUsdCopy.sendAmount}: \$40.00',
      '${PrivateUsdCopy.convertNetworkFee}: \$0.50',
      '${PrivateUsdCopy.detailsStatus}: ${PrivateUsdCopy.detailsConfirmed}',
      '${PrivateUsdCopy.detailsSent}: ${time(record.sentAt)}',
      '${PrivateUsdCopy.detailsTransaction}: $previewPrivateUsdTxHash on '
          'railscan, etherscan',
    ]);
    expect(
      (lines.first as PrivateUsdDetailValue).copyText,
      previewPrivateUsdRecipient,
    );

    final pending = privateUsdSendDetails(
      previewPrivateUsdSendRecord(confirmed: false),
    );
    expect(
      read(pending),
      contains(
        '${PrivateUsdCopy.detailsStatus}: ${PrivateUsdCopy.detailsUnconfirmed}',
      ),
    );
    expect(pending.whereType<PrivateUsdDetailTransaction>(), isEmpty);
  });

  test('a received send keeps a hidden sender hidden, and says when it is '
      'still screened', () {
    final lines = privateUsdReceivedDetails(
      previewPrivateUsdReceipt(settled: false),
    );

    expect(
      read(lines).first,
      '${PrivateUsdCopy.detailsFrom}: ${PrivateUsdCopy.detailsSenderHidden}',
    );
    expect((lines.first as PrivateUsdDetailValue).copyText, isNull);
    expect(
      read(lines),
      contains(
        '${PrivateUsdCopy.detailsStatus}: ${PrivateUsdCopy.convertStepScreen}',
      ),
    );
  });

  test('a paid bridge states its amounts and fee, then its swap and '
      'transactions on their chains', () {
    final record = previewPrivateUsdRecord(
      phase: ApiForwardPhase.paid,
      outcome: ApiForwardOutcome.paid,
    );

    expect(read(privateUsdForwardDetails(record)), [
      '${PrivateUsdCopy.bridgedYouPaid}: ${zec(50000000)}',
      '${PrivateUsdCopy.bridgedYouReceived}: \$15.50',
      '${PrivateUsdCopy.detailsRelayerFee}: \$0.46',
      '${PrivateUsdCopy.detailSwapId}: ${truncatedTxid(record.swapId)}',
      '${PrivateUsdCopy.detailDeposit}: ${record.depositTxid} on zcash',
      '${PrivateUsdCopy.detailPayout}: ${record.payoutTx} on railscan, '
          'etherscan',
      '${PrivateUsdCopy.detailStarted}: ${time(record.acceptedAt)}',
      '${PrivateUsdCopy.detailsEnded}: ${time(record.endedAt!)}',
    ]);
  });

  test('a refunded bridge says why first, and names its ZEC refund', () {
    final record = previewPrivateUsdRecord(
      phase: ApiForwardPhase.refunded,
      outcome: ApiForwardOutcome.refunded,
      refundCause: ApiRefundCause.notClaimedInTime,
    );
    final lines = read(privateUsdForwardDetails(record));

    expect(
      lines.first,
      privateUsdRefundedMessage(ApiRefundCause.notClaimedInTime),
    );
    expect(
      lines,
      contains('${PrivateUsdCopy.detailRefund}: ${record.sweepTxid} on zcash'),
    );
    expect(
      lines.where((line) => line.startsWith(PrivateUsdCopy.bridgedYouPaid)),
      isEmpty,
    );
  });

  test('a completed reverse bridge states its fees, its escrow payment and '
      'its ZEC', () {
    final record = previewPrivateUsdReverseRecord(
      phase: ApiReversePhase.complete,
    );

    expect(read(privateUsdReverseDetails(record)), [
      '${PrivateUsdCopy.bridgedYouPaid}: \$25.31',
      '${PrivateUsdCopy.bridgedYouReceived}: ${zec(79985000)}',
      '${PrivateUsdCopy.reverseRailgunFee}: \$0.06',
      '${PrivateUsdCopy.reverseBroadcasterFee}: \$0.25',
      '${PrivateUsdCopy.detailSwapId}: ${truncatedTxid(record.swapId)}',
      '${PrivateUsdCopy.detailFunding}: ${record.fundingTx} on railscan, '
          'etherscan',
      '${PrivateUsdCopy.detailZecReceived}: ${record.receiveTxid} on zcash',
      '${PrivateUsdCopy.detailStarted}: ${time(record.acceptedAt!)}',
    ]);
  });

  test('a deposit names its address, what it moved, the relayer fee and '
      'what arrived', () {
    final record = ApiDepositRecord(
      id: 'deposit-1',
      kind: ApiDepositKind.shield,
      index: 0,
      address: previewPrivateUsdEthereumAddress,
      state: ApiDepositState.landed,
      value: '50000000',
      fee: '2250000',
      arrives: '47626875',
      createdAt: previewPrivateUsdUnix(previewPrivateUsdNow),
      txHash: previewPrivateUsdTxHash,
      waiting: false,
    );
    final lines = privateUsdDepositDetails(record);

    expect(read(lines), [
      '${PrivateUsdCopy.detailsDepositAddress}: '
          '${truncatedAddress(previewPrivateUsdEthereumAddress)}',
      '${PrivateUsdCopy.sendAmount}: \$50.00',
      '${PrivateUsdCopy.detailsRelayerFee}: \$2.25',
      '${PrivateUsdCopy.bridgedYouReceived}: \$47.62',
      '${PrivateUsdCopy.detailStarted}: ${time(record.createdAt)}',
      '${PrivateUsdCopy.detailsTransaction}: $previewPrivateUsdTxHash on '
          'railscan, etherscan',
    ]);
    expect(
      (lines.first as PrivateUsdDetailValue).copyText,
      previewPrivateUsdEthereumAddress,
    );
  });

  test('privacy mode hides every amount', () {
    final lines = read([
      ...privateUsdSendDetails(
        previewPrivateUsdSendRecord(),
        privacyModeEnabled: true,
      ),
      ...privateUsdForwardDetails(
        previewPrivateUsdRecord(
          phase: ApiForwardPhase.paid,
          outcome: ApiForwardOutcome.paid,
        ),
        privacyModeEnabled: true,
      ),
    ]);

    for (final amount in [r'$40.00', r'$0.50', r'$15.50', r'$0.46']) {
      expect(lines.where((line) => line.contains(amount)), isEmpty);
    }
    expect(lines.where((line) => line.contains(zec(50000000))), isEmpty);
  });

  group('explorers', () {
    // The prefixes the deployments pin (`rust/src/wallet/private_usd/
    // deployment.rs`); Railscan routes `/:chain/tx/:hash`.
    const sepolia = PrivateUsdExplorers(
      zcashNetworkName: 'test',
      etherscanTxPrefix: 'https://sepolia.etherscan.io/tx/',
      railscanTxPrefix: 'https://railscan.io/sepolia/tx/',
    );
    const mainnet = PrivateUsdExplorers(
      zcashNetworkName: 'main',
      etherscanTxPrefix: 'https://etherscan.io/tx/',
      railscanTxPrefix: 'https://railscan.io/ethereum/tx/',
    );
    const hash =
        '0xbc5942942d68af74e99088f5a2ed8d649e93b0ff681d9108ae79d9f4d87383b3';

    test('an Ethereum transaction opens on its chain\'s Railscan and '
        'Etherscan', () {
      expect(
        sepolia.uri(hash, PrivateUsdExplorer.railscan).toString(),
        'https://railscan.io/sepolia/tx/$hash',
      );
      expect(
        sepolia.uri(hash, PrivateUsdExplorer.etherscan).toString(),
        'https://sepolia.etherscan.io/tx/$hash',
      );
      expect(
        mainnet.uri(hash, PrivateUsdExplorer.railscan).toString(),
        'https://railscan.io/ethereum/tx/$hash',
      );
      expect(
        mainnet.uri(hash, PrivateUsdExplorer.etherscan).toString(),
        'https://etherscan.io/tx/$hash',
      );
    });

    test('without a deployment nothing opens', () {
      const none = PrivateUsdExplorers(zcashNetworkName: 'main');
      expect(none.uri(hash, PrivateUsdExplorer.railscan), isNull);
      expect(none.uri(hash, PrivateUsdExplorer.etherscan), isNull);
    });

    test('a Zcash txid opens on the wallet\'s explorer, in display order', () {
      const internal =
          '9f1c3b5a7d2e4f60819a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f70';
      final display = zcashDisplayTxidHex(
        internal,
        ZcashExplorerTxidOrder.protocol,
      );

      expect(
        mainnet.uri(internal, PrivateUsdExplorer.zcash).toString(),
        'https://zecblock.com/tx/$display',
      );
      expect(
        sepolia.uri(internal, PrivateUsdExplorer.zcash).toString(),
        'https://testnet.zecblock.com/tx/$display',
      );
      expect(
        const PrivateUsdExplorers(
          zcashNetworkName: 'main',
          zcashExplorerTemplate: 'https://explorer.example/tx/{txid}',
        ).uri(internal, PrivateUsdExplorer.zcash).toString(),
        'https://explorer.example/tx/$display',
      );
    });
  });
}
