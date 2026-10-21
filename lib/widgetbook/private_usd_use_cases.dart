// ignore_for_file: depend_on_referenced_packages
// widgetbook is dev-only; see `widgetbook.dart` for the boundary.

import 'package:flutter/widgets.dart';

import '../src/core/layout/mobile/app_mobile_sheet.dart';
import '../src/core/theme/app_theme.dart';
import '../src/features/activity/models/activity_row_data.dart';
import '../src/features/private_usd/models/private_usd_balances.dart';
import '../src/features/private_usd/models/private_usd_record_key.dart';
import '../src/features/private_usd/models/private_usd_status_presentation.dart';
import '../src/features/private_usd/models/railgun_models.dart';
import '../src/features/private_usd/private_usd_copy.dart';
import '../src/features/private_usd/providers/private_usd_balance_provider.dart';
import '../src/features/private_usd/providers/private_usd_conversion_provider.dart';
import '../src/features/private_usd/providers/private_usd_convert_provider.dart';
import '../src/features/private_usd/providers/private_usd_unfinished_provider.dart';
import '../src/features/private_usd/screens/mobile/mobile_private_usd_screen.dart';
import '../src/features/private_usd/services/private_usd_balance_repository.dart';
import '../src/features/private_usd/services/private_usd_engine.dart';
import '../src/features/private_usd/services/private_usd_zec_quote_search.dart';
import '../src/features/private_usd/widgets/mobile/private_usd_activity_rows.dart';
import '../src/features/private_usd/widgets/mobile/private_usd_convert_views.dart';
import '../src/features/private_usd/widgets/mobile/private_usd_progress_views.dart';
import '../src/features/private_usd/widgets/mobile/private_usd_receive_sheet.dart';
import '../src/rust/api/private_usd.dart';

/// Deterministic Private USD fixtures: fixed balances, addresses and times;
/// no WebView, Rust, network or clock.

/// Mainnet USDC, the token the home and screen previews hold.
const previewPrivateUsdUsdc = PrivateUsdToken(
  address: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
  symbol: 'USDC',
  decimals: 6,
);

/// A real-format `0zk` address, for 64 bytes of 0x08.
const previewPrivateUsdAddress =
    '0zk1qyrs4qyrd08p6uep0fc2y8njktgcpezts3rpaq6q0ln948ecjkw8prv7j6f'
    'e3z53llz8ursderja0juwv5pgnv8x5klmmwkv8q38h9n704h4d4qjyw7n5qk68nx';

/// Another wallet's real-format `0zk` address, for sends.
const previewPrivateUsdRecipient =
    '0zk1qy860uut20m8gd6fnhzvr0zqeyhs0ya5247x7h2eyedxsazx43w5nrv7j6fe3z53l78'
    'hn78kmslky2206lm75mclrv7dawd756m2suy7l4zud2m4yhg6kcsn7ed';

/// An EIP-55 address (the EIP's own example): a deposit address, or where a
/// withdrawal goes.
const previewPrivateUsdEthereumAddress =
    '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';

/// A send's Ethereum transaction.
const previewPrivateUsdTxHash =
    '0x4b2e6a8c0d1f3a5c7e9b1d3f5a7c9e0b2d4f6a8c1e3b5d7f9a0c2e4b6d8f1a3c';

/// 2026-10-13 09:41 local.
final previewPrivateUsdUpdatedAt = DateTime(2026, 10, 13, 9, 41);

/// 2026-10-14 09:41 local: the conversion and send previews' "now".
final previewPrivateUsdNow = DateTime(2026, 10, 14, 9, 41);

/// [time] in Unix seconds, as Rust records it.
int previewPrivateUsdUnix(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

// The deployment's Zcash confirmations, as the previews count them.
const _confirmations = 2;

/// A balance with [available], [arriving], [blocked] and [processing]
/// dollars of USDC.
PrivateUsdBalanceState previewPrivateUsdBalance({
  double available = 0,
  double arriving = 0,
  double blocked = 0,
  double processing = 0,
  bool isRefreshing = false,
  bool refreshFailed = false,
}) {
  BigInt units(double dollars) => BigInt.from((dollars * 1e6).round());
  final buckets = <RailgunBalanceBucket, List<RailgunTokenAmount>>{
    RailgunBalanceBucket.spendable: [_held(units(available))],
    RailgunBalanceBucket.shieldPending: [_held(units(arriving))],
    RailgunBalanceBucket.shieldBlocked: [_held(units(blocked))],
    RailgunBalanceBucket.missingExternalPoi: [_held(units(processing))],
  };
  return PrivateUsdBalanceState(
    balances: PrivateUsdBalances.of(RailgunBalances(buckets), const [
      previewPrivateUsdUsdc,
    ]),
    updatedAt: previewPrivateUsdUpdatedAt,
    address: previewPrivateUsdAddress,
    isRefreshing: isRefreshing,
    refreshFailed: refreshFailed,
  );
}

RailgunTokenAmount _held(BigInt amount) =>
    RailgunTokenAmount(token: previewPrivateUsdUsdc.address, amount: amount);

/// Not used yet: nothing known and nothing loading.
const previewPrivateUsdUnknown = PrivateUsdBalanceState();

/// A first sync under way, nothing shown yet.
const previewPrivateUsdLoading = PrivateUsdBalanceState(isRefreshing: true);

/// A send of $[dollars] kept [ago] before [previewPrivateUsdNow]:
/// confirmed with its transaction, or not in a block yet.
ApiSendRecord previewPrivateUsdSendRecord({
  String sendId = '6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b',
  double dollars = 40,
  bool withdraw = false,
  bool confirmed = true,
  Duration ago = const Duration(hours: 5),
}) {
  final sentAt = previewPrivateUsdNow.subtract(ago);
  return ApiSendRecord(
    sendId: sendId,
    token: previewPrivateUsdUsdc.address,
    amount: BigInt.from((dollars * 1e6).round()).toString(),
    fee: '500000',
    to: withdraw
        ? previewPrivateUsdEthereumAddress
        : previewPrivateUsdRecipient,
    withdraw: withdraw,
    sentAt: previewPrivateUsdUnix(sentAt),
    state: confirmed ? ApiSendState.confirmed : ApiSendState.unconfirmed,
    txHash: confirmed ? previewPrivateUsdTxHash : null,
    postedAt: previewPrivateUsdUnix(sentAt),
  );
}

/// A private send of $[dollars] received [ago] before [previewPrivateUsdNow]:
/// screened unless [settled] is off, from [sender] where the sender showed
/// it.
RailgunReceipt previewPrivateUsdReceipt({
  double dollars = 25,
  bool settled = true,
  String? sender,
  Duration ago = const Duration(hours: 2),
}) => RailgunReceipt(
  txid: '0x${'5e' * 32}',
  token: previewPrivateUsdUsdc.address,
  amount: BigInt.from((dollars * 1e6).round()),
  bucket: settled
      ? RailgunBalanceBucket.spendable
      : RailgunBalanceBucket.missingExternalPoi,
  at: previewPrivateUsdNow.subtract(ago),
  sender: sender,
);

/// Holds the text controllers a form preview edits, one per [texts].
class PrivateUsdPreviewControllers extends StatefulWidget {
  const PrivateUsdPreviewControllers({
    required this.texts,
    required this.builder,
    super.key,
  });

  final List<String> texts;
  final Widget Function(
    BuildContext context,
    List<TextEditingController> controllers,
  )
  builder;

  @override
  State<PrivateUsdPreviewControllers> createState() =>
      _PrivateUsdPreviewControllersState();
}

class _PrivateUsdPreviewControllersState
    extends State<PrivateUsdPreviewControllers> {
  late final _controllers = [
    for (final text in widget.texts) TextEditingController(text: text),
  ];

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controllers);
}

Widget buildMobilePrivateUsdDefaultUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(
      state: previewPrivateUsdBalance(
        available: 1250.4,
        arriving: 200,
        processing: 12.5,
      ),
      sends: [previewPrivateUsdSendRecord()],
      receipts: [previewPrivateUsdReceipt()],
      records: [
        previewPrivateUsdRecord(
          index: 4,
          phase: ApiForwardPhase.paid,
          outcome: ApiForwardOutcome.paid,
          ago: const Duration(days: 1),
        ),
        previewPrivateUsdRecord(
          index: 2,
          phase: ApiForwardPhase.refunded,
          outcome: ApiForwardOutcome.refunded,
          refundCause: ApiRefundCause.makerCancelled,
          ago: const Duration(days: 3),
        ),
      ],
    );

Widget buildMobilePrivateUsdEmptyUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(state: previewPrivateUsdBalance());

Widget buildMobilePrivateUsdFirstLoadUseCase(BuildContext context) =>
    const _PrivateUsdScreenPreview(
      state: PrivateUsdBalanceState(isRefreshing: true, firstSyncPercent: 42),
    );

Widget buildMobilePrivateUsdRefreshFailedUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(
      state: previewPrivateUsdBalance(available: 1250.4, refreshFailed: true),
    );

Widget buildMobilePrivateUsdBlockedUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(
      state: previewPrivateUsdBalance(available: 80, blocked: 25),
    );

Widget buildMobilePrivateUsdHiddenUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(
      state: previewPrivateUsdBalance(available: 1250.4, arriving: 200),
      privacyModeEnabled: true,
    );

/// A send not in a block yet: the spending note, and Send, Withdraw and
/// bridging held back.
Widget buildMobilePrivateUsdPaymentPendingUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(
      state: previewPrivateUsdBalance(available: 1210.4, processing: 12.5),
      sends: [
        previewPrivateUsdSendRecord(confirmed: false, ago: Duration.zero),
      ],
      canSend: false,
      canConvert: false,
      spendNote: PrivateUsdCopy.paymentPending,
    );

/// A network with no windows contract (mainnet for now): no Bridge, and the
/// empty card points to Receive.
Widget buildMobilePrivateUsdBridgeOffUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(
      state: previewPrivateUsdBalance(),
      bridgeAvailable: false,
    );

class _PrivateUsdScreenPreview extends StatelessWidget {
  const _PrivateUsdScreenPreview({
    required this.state,
    this.privacyModeEnabled = false,
    this.records = const [],
    this.sends = const [],
    this.receipts = const [],
    this.canSend = true,
    this.canConvert = true,
    this.bridgeAvailable = true,
    this.spendNote,
  });

  final PrivateUsdBalanceState state;
  final bool privacyModeEnabled;
  final List<ApiForwardRecord> records;
  final List<ApiSendRecord> sends;
  final List<RailgunReceipt> receipts;
  final bool canSend;
  final bool canConvert;
  final bool bridgeAvailable;
  final String? spendNote;

  @override
  Widget build(BuildContext context) {
    return PrivateUsdPreviewFrame(
      child: Builder(
        builder: (context) => MobilePrivateUsdView(
          state: state,
          zecUsdPrice: 70,
          privacyModeEnabled: privacyModeEnabled,
          screening: const Duration(hours: 1),
          activityRows: [
            for (final record in sends)
              buildPrivateUsdSendActivityRow(
                context: context,
                record: record,
                privacyModeEnabled: privacyModeEnabled,
                onOpenTransaction: () {},
              ),
            for (final receipt in receipts)
              buildPrivateUsdReceivedActivityRow(
                context: context,
                receipt: receipt,
                privacyModeEnabled: privacyModeEnabled,
                onOpenTransaction: () {},
              ),
            for (final record in records)
              ?buildPrivateUsdActivityRow(
                context: context,
                record: record,
                zcashConfirmations: _confirmations,
                privacyModeEnabled: privacyModeEnabled,
                onOpenTransaction: () {},
              ),
          ],
          onBack: () {},
          onRefresh: () {},
          onConvert: () {},
          onSend: () {},
          onWithdraw: () {},
          onReceive: () {},
          canSend: canSend,
          canConvert: canConvert,
          bridgeAvailable: bridgeAvailable,
          spendNote: spendNote,
        ),
      ),
    );
  }
}

// As `showAppMobileSheet` presents it: the modal card at the bottom, the
// sheet scrolling when it is taller than the space above the status bar.
Widget _receivePreview(PrivateUsdReceiveKind kind) => PrivateUsdPreviewFrame(
  child: Builder(
    builder: (context) => ColoredBox(
      color: context.colors.background.window,
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: MobileModalCard(child: _receiveBody(kind)),
        ),
      ),
    ),
  ),
);

Widget _receiveBody(PrivateUsdReceiveKind kind) => PrivateUsdReceiveSheetBody(
  kind: kind,
  onKindChanged: (_) {},
  symbol: 'USDC',
  chain: 'Ethereum',
  address: previewPrivateUsdEthereumAddress,
  railgunAddress: previewPrivateUsdAddress,
  terms: const ApiDepositTerms(
    fee: '250000',
    feeBps: 50,
    minValue: '10000000',
    railgunFeeBps: 25,
  ),
  example: PrivateUsdCopy.depositExample(r'$10.00', r'$9.68'),
  screening: const Duration(hours: 1),
  onClose: () {},
);

/// Receive, public USDC (the default): the deposit address and its terms.
Widget buildMobilePrivateUsdReceiveUseCase(BuildContext context) =>
    _receivePreview(PrivateUsdReceiveKind.usdc);

/// Receive, switched to 0zkUSDC: the 0zk address for a Railgun wallet.
Widget buildMobilePrivateUsdReceiveShieldedUseCase(BuildContext context) =>
    _receivePreview(PrivateUsdReceiveKind.shielded);

/// A 393 × 852 phone frame with its safe area, for the Private USD
/// previews.
class PrivateUsdPreviewFrame extends StatelessWidget {
  const PrivateUsdPreviewFrame({required this.child, super.key});

  final Widget child;

  static const _size = Size(393, 852);
  static const _safeArea = EdgeInsets.only(top: 55, bottom: 24);

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return Center(
      child: SizedBox.fromSize(
        size: _size,
        child: ClipRect(
          child: MediaQuery(
            data: mediaQuery.copyWith(
              size: _size,
              padding: _safeArea,
              viewPadding: _safeArea,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

// ── Forward conversion ───────────────────────────────────────────────────

/// A quote for 0.5 ZEC in all ($16 asked, $15.50 arriving after a $0.46
/// relayer fee) that is offered for [holds] more.
PrivateUsdZecQuote previewPrivateUsdQuote({
  Duration holds = const Duration(minutes: 2, seconds: 35),
  int index = 7,
}) {
  final expiresAt = previewPrivateUsdNow
      .add(holds)
      .add(PrivateUsdConvertTiming.expiryMargin);
  return PrivateUsdZecQuote(
    requestedUnits: 16000000,
    quote: ApiForwardQuote(
      index: index,
      expiresAt: previewPrivateUsdUnix(expiresAt),
      amount: '16000000',
      networkCost: '40000',
      relayerFee: '460000',
      receives: '15500000',
      depositZat: BigInt.from(49990000),
      depositFeeZat: BigInt.from(10000),
      maxTotalZat: BigInt.from(50000000),
      feeExpiresAt: previewPrivateUsdUnix(expiresAt),
    ),
  );
}

/// The convert flow's state: [amountText] typed, with [quote].
PrivateUsdConvertState previewPrivateUsdConvertState({
  String amountText = '0.5',
  PrivateUsdZecQuote? quote,
  bool quoting = false,
  BigInt? spendable,
  bool catchingUp = false,
  int? syncPercent,
  PrivateUsdConvertStep step = PrivateUsdConvertStep.amount,
  DateTime? now,
  String? startError,
}) => PrivateUsdConvertState(
  now: now ?? previewPrivateUsdNow,
  amountText: amountText,
  quote: quote,
  quoting: quoting,
  step: step,
  startError: startError,
  holdings: PrivateUsdZecHoldings(
    spendable: spendable ?? BigInt.from(143120000),
    authoritative: !catchingUp,
    catchingUp: catchingUp,
    syncPercent: syncPercent,
  ),
);

/// A forward record of 0.5 ZEC for $15.50, accepted [ago] before
/// [previewPrivateUsdNow], on the testnet windows contract (`t1` two hours
/// on, its late window an hour).
ApiForwardRecord previewPrivateUsdRecord({
  int index = 7,
  ApiForwardPhase phase = ApiForwardPhase.confirming,
  ApiForwardOutcome? outcome,
  ApiRefundCause? refundCause,
  ApiNothingSentCause? nothingSentCause,
  Duration ago = const Duration(minutes: 3),
  int? depositConfirmations,
  bool deposited = true,
}) {
  final acceptedAt = previewPrivateUsdNow.subtract(ago);
  int at(Duration after) => previewPrivateUsdUnix(acceptedAt.add(after));
  return ApiForwardRecord(
    index: index,
    swapId:
        '0x7b2d41c09e5f8a3b6c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b',
    phase: phase,
    acceptedAt: previewPrivateUsdUnix(acceptedAt),
    quoteExpiresAt: at(const Duration(minutes: 5)),
    depositZat: BigInt.from(49990000),
    maxTotalZat: BigInt.from(50000000),
    amount: '16000000',
    receives: '15500000',
    relayerFee: '460000',
    t0: at(const Duration(minutes: 40)),
    t1: at(const Duration(hours: 2)),
    lateClaimAt: at(const Duration(hours: 3)),
    depositTxid: deposited
        ? '9f1c3b5a7d2e4f60819a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f70'
        : null,
    depositConfirmations: outcome == null && deposited
        ? depositConfirmations
        : null,
    sweepTxid: outcome == ApiForwardOutcome.refunded
        ? '0a1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5061728394a5b6c7d8e9f'
        : null,
    payoutTx: outcome == ApiForwardOutcome.paid
        ? '0x5e3a9c1f7b2d4e6a8c0b1d3f5a7c9e2b4d6f8a0c2e4b6d8f0a1c3e5b7d9f1a3c'
        : null,
    outcome: outcome,
    refundCause: refundCause,
    nothingSentCause: nothingSentCause,
    endedAt: outcome == null ? null : at(const Duration(minutes: 12)),
  );
}

Widget _convertPreview(PrivateUsdConvertState state) => PrivateUsdPreviewFrame(
  child: PrivateUsdPreviewControllers(
    texts: [state.amountText],
    builder: (context, controllers) => MobilePrivateUsdConvertView(
      state: state,
      controller: controllers.single,
      autofocus: false,
      privateUsdAvailable: BigInt.from(1250400000),
      onAmountChanged: (_) {},
      onMax: () {},
      onReview: () {},
      onBack: () {},
      // The direction switch is live on the amount step, as in the app.
      onSwitchDirection: state.step == PrivateUsdConvertStep.amount
          ? () {}
          : null,
    ),
  ),
);

/// ZEC → USD with a quote: the ledger and its countdown.
Widget buildMobilePrivateUsdConvertUseCase(BuildContext context) =>
    _convertPreview(
      previewPrivateUsdConvertState(quote: previewPrivateUsdQuote()),
    );

/// While the typed amount is quoted.
Widget buildMobilePrivateUsdConvertQuotingUseCase(BuildContext context) =>
    _convertPreview(previewPrivateUsdConvertState(quoting: true));

/// More than the wallet can spend.
Widget buildMobilePrivateUsdConvertInsufficientUseCase(BuildContext context) =>
    _convertPreview(
      previewPrivateUsdConvertState(
        amountText: '2',
        spendable: BigInt.from(143120000),
      ),
    );

/// The wallet still catching up: the line says so and Max waits.
Widget buildMobilePrivateUsdConvertSyncingUseCase(BuildContext context) =>
    _convertPreview(
      previewPrivateUsdConvertState(
        amountText: '',
        catchingUp: true,
        syncPercent: 42,
      ),
    );

Widget _reviewPreview(PrivateUsdConvertState state) => PrivateUsdPreviewFrame(
  child: MobilePrivateUsdConvertReviewView(
    state: state,
    privacyModeEnabled: false,
    onBack: () {},
    onConfirm: () {},
    onRefreshQuote: () {},
  ),
);

/// The forward review.
Widget buildMobilePrivateUsdReviewUseCase(BuildContext context) =>
    _reviewPreview(
      previewPrivateUsdConvertState(
        quote: previewPrivateUsdQuote(),
        step: PrivateUsdConvertStep.review,
      ),
    );

/// The review once its quote ran out.
Widget buildMobilePrivateUsdReviewExpiredUseCase(BuildContext context) =>
    _reviewPreview(
      previewPrivateUsdConvertState(
        quote: previewPrivateUsdQuote(holds: Duration.zero),
        step: PrivateUsdConvertStep.review,
      ),
    );

Widget _progressPreview(
  PrivateUsdConversionStatus status, {
  PrivateUsdBalanceState? balance,
  bool callingOff = false,
}) => PrivateUsdPreviewFrame(
  child: MobilePrivateUsdConversionView(
    presentation: privateUsdProgressPresentation(
      status: status,
      now: previewPrivateUsdNow,
      zcashConfirmations: _confirmations,
      screening: const Duration(hours: 1),
      balance: balance,
      explorerTxPrefix: 'https://sepolia.etherscan.io/tx/',
    ),
    callingOff: callingOff,
    onBack: () {},
    onInfo: () {},
    onRetry: () {},
    onCallOff: () {},
    onViewBalance: () {},
    onTryAgain: () {},
  ),
);

/// Waiting for confirmations, 1 of 2.
Widget buildMobilePrivateUsdProgressUseCase(BuildContext context) =>
    _progressPreview(
      PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(depositConfirmations: 1),
        wait: ApiForwardWait.confirming,
      ),
    );

/// An opening that has taken over 90 s, so it can be called off.
Widget buildMobilePrivateUsdProgressOpeningSlowUseCase(BuildContext context) =>
    _progressPreview(
      PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(
          phase: ApiForwardPhase.opening,
          deposited: false,
          ago: const Duration(minutes: 2),
        ),
        wait: ApiForwardWait.opening,
      ),
    );

/// Steps failing for over a minute: the problem card.
Widget buildMobilePrivateUsdProgressProblemUseCase(BuildContext context) =>
    _progressPreview(
      PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(
          phase: ApiForwardPhase.claiming,
          depositConfirmations: 2,
        ),
        problem: ApiPrivateUsdErrorCode.relayerUnreachable,
        failingSince: previewPrivateUsdNow.subtract(const Duration(minutes: 2)),
      ),
    );

/// Paid: arrived in the private balance, screening.
Widget buildMobilePrivateUsdProgressPaidUseCase(BuildContext context) =>
    _progressPreview(
      PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(
          phase: ApiForwardPhase.paid,
          outcome: ApiForwardOutcome.paid,
          ago: const Duration(minutes: 20),
        ),
      ),
      balance: previewPrivateUsdBalance(available: 1250.4, arriving: 15.5),
    );

/// Paid and screened: bridged.
Widget buildMobilePrivateUsdProgressBridgedUseCase(BuildContext context) =>
    _progressPreview(
      PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(
          phase: ApiForwardPhase.paid,
          outcome: ApiForwardOutcome.paid,
          ago: const Duration(minutes: 20),
        ),
      ),
      // Read after the payout settled, with nothing left arriving.
      balance: previewPrivateUsdBalance(
        available: 1265.9,
      ).copyWith(updatedAt: previewPrivateUsdNow),
    );

/// The maker called it off: bringing the ZEC back.
Widget buildMobilePrivateUsdProgressRefundingUseCase(BuildContext context) =>
    _progressPreview(
      PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(phase: ApiForwardPhase.refunding),
        wait: ApiForwardWait.refunding,
      ),
    );

/// Unwinding: `t1` passed ten minutes ago with the dollars unclaimed, so the
/// ZEC waits on the maker's refund, or Veylor claims from its late claim
/// time, 50 minutes on.
PrivateUsdConversionStatus previewPrivateUsdUnwinding() =>
    PrivateUsdConversionStatus(
      record: previewPrivateUsdRecord(
        phase: ApiForwardPhase.claiming,
        depositConfirmations: 2,
        ago: const Duration(hours: 2, minutes: 10),
      ),
      wait: ApiForwardWait.unwinding,
    );

Widget buildMobilePrivateUsdProgressUnwindingUseCase(BuildContext context) =>
    _progressPreview(previewPrivateUsdUnwinding());

/// The ZEC came back.
Widget buildMobilePrivateUsdProgressRefundedUseCase(BuildContext context) =>
    _progressPreview(
      PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(
          phase: ApiForwardPhase.refunded,
          outcome: ApiForwardOutcome.refunded,
          refundCause: ApiRefundCause.notClaimedInTime,
        ),
      ),
    );

/// Nothing was sent.
Widget buildMobilePrivateUsdProgressNothingSentUseCase(BuildContext context) =>
    _progressPreview(
      PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(
          phase: ApiForwardPhase.nothingSent,
          outcome: ApiForwardOutcome.nothingSent,
          nothingSentCause: ApiNothingSentCause.makerUnavailable,
          deposited: false,
        ),
      ),
    );

/// The home banner's conversion: waiting for confirmations, 1 of 2.
Map<PrivateUsdRecordKey, PrivateUsdConversionStatus>
previewPrivateUsdConverting(String accountUuid) => {
  PrivateUsdRecordKey(
    accountUuid: accountUuid,
    direction: PrivateUsdDirection.forward,
    index: 7,
  ): PrivateUsdConversionStatus(
    record: previewPrivateUsdRecord(depositConfirmations: 1),
    wait: ApiForwardWait.confirming,
  ),
};

/// A balance that only shows [fixed]. It never polls or opens the page.
class FixedPrivateUsdBalanceNotifier extends PrivateUsdBalanceNotifier {
  FixedPrivateUsdBalanceNotifier(super.accountUuid, this.fixed);

  final PrivateUsdBalanceState fixed;

  @override
  PrivateUsdBalanceState build() => fixed;

  @override
  VoidCallback watch({required bool ifUsed}) => () {};

  @override
  void refresh({Duration maxAge = Duration.zero}) {}
}

/// Conversions that only show [fixed]. No engine runs.
class FixedPrivateUsdConversionsNotifier extends PrivateUsdConversionsNotifier {
  FixedPrivateUsdConversionsNotifier(this.fixed);

  final Map<PrivateUsdRecordKey, PrivateUsdConversionStatus> fixed;

  @override
  Map<PrivateUsdRecordKey, PrivateUsdConversionStatus> build() => fixed;
}

/// Reverse conversions that only show [fixed]. No engine runs.
class FixedPrivateUsdReverseConversionsNotifier
    extends PrivateUsdReverseConversionsNotifier {
  FixedPrivateUsdReverseConversionsNotifier(this.fixed);

  final Map<PrivateUsdRecordKey, PrivateUsdReverseStatus> fixed;

  @override
  Map<PrivateUsdRecordKey, PrivateUsdReverseStatus> build() => fixed;
}

/// The banner a conversion under way shows.
PrivateUsdBannerState previewPrivateUsdBanner() => PrivateUsdBannerState(
  path: const PrivateUsdRoutePath(
    direction: PrivateUsdDirection.forward,
    index: 7,
  ),
  title: PrivateUsdCopy.convertingToUsd,
  detail: privateUsdForwardStageLabel(
    PrivateUsdConversionStatus(
      record: previewPrivateUsdRecord(depositConfirmations: 1),
      wait: ApiForwardWait.confirming,
    ),
    zcashConfirmations: _confirmations,
  ),
  attention: false,
);

/// Activity rows for [records], as the screens build them.
List<ActivityRowData> previewPrivateUsdActivityRows(
  BuildContext context,
  List<ApiForwardRecord> records,
) => [
  for (final record in records)
    ?buildPrivateUsdActivityRow(
      context: context,
      record: record,
      zcashConfirmations: _confirmations,
    ),
];
