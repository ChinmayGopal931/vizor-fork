// ignore_for_file: depend_on_referenced_packages
// widgetbook is dev-only; see `widgetbook.dart` for the boundary.

import 'package:flutter/widgets.dart';

import '../src/features/activity/models/activity_row_data.dart';
import '../src/features/private_usd/models/private_usd_balances.dart';
import '../src/features/private_usd/models/private_usd_record_key.dart';
import '../src/features/private_usd/models/private_usd_status_presentation.dart';
import '../src/features/private_usd/models/railgun_models.dart';
import '../src/features/private_usd/private_usd_copy.dart';
import '../src/features/private_usd/providers/private_usd_conversion_provider.dart';
import '../src/features/private_usd/providers/private_usd_convert_provider.dart';
import '../src/features/private_usd/screens/mobile/mobile_private_usd_conversion_screen.dart';
import '../src/features/private_usd/screens/mobile/mobile_private_usd_convert_review_screen.dart';
import '../src/features/private_usd/screens/mobile/mobile_private_usd_convert_screen.dart';
import '../src/features/private_usd/screens/mobile/mobile_private_usd_screen.dart';
import '../src/features/private_usd/services/private_usd_balance_repository.dart';
import '../src/features/private_usd/services/private_usd_engine.dart';
import '../src/features/private_usd/services/private_usd_zec_quote_search.dart';
import '../src/features/private_usd/widgets/mobile/private_usd_activity_rows.dart';
import '../src/rust/api/private_usd.dart';

/// Deterministic Private USD fixtures (plan reference §9.7): fixed balances,
/// addresses and times; no WebView, Rust, network or clock.

/// Mainnet USDC, the token the home and screen previews hold.
const previewPrivateUsdUsdc = PrivateUsdToken(
  address: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
  symbol: 'USDC',
  decimals: 6,
);

/// A real-format `0zk` address (zapp's test vector for 64 bytes of 0x08).
const previewPrivateUsdAddress =
    '0zk1qyrs4qyrd08p6uep0fc2y8njktgcpezts3rpaq6q0ln948ecjkw8prv7j6f'
    'e3z53llz8ursderja0juwv5pgnv8x5klmmwkv8q38h9n704h4d4qjyw7n5qk68nx';

/// 2026-10-13 09:41 local.
final previewPrivateUsdUpdatedAt = DateTime(2026, 10, 13, 9, 41);

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

/// Not used yet: nothing known and nothing loading, the home strip's "—".
const previewPrivateUsdUnknown = PrivateUsdBalanceState();

/// A first sync under way, nothing shown yet.
const previewPrivateUsdLoading = PrivateUsdBalanceState(isRefreshing: true);

Widget buildMobilePrivateUsdDefaultUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(
      state: previewPrivateUsdBalance(
        available: 1250.4,
        arriving: 200,
        processing: 12.5,
      ),
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

class _PrivateUsdScreenPreview extends StatelessWidget {
  const _PrivateUsdScreenPreview({
    required this.state,
    this.privacyModeEnabled = false,
    this.records = const [],
  });

  final PrivateUsdBalanceState state;
  final bool privacyModeEnabled;
  final List<ApiForwardRecord> records;

  @override
  Widget build(BuildContext context) {
    return PrivateUsdPreviewFrame(
      child: Builder(
        builder: (context) => MobilePrivateUsdView(
          state: state,
          zecUsdPrice: 70,
          privacyModeEnabled: privacyModeEnabled,
          receiveAddress: previewPrivateUsdAddress,
          screening: const Duration(hours: 1),
          tokenNames: {
            previewPrivateUsdUsdc.address: PrivateUsdCopy.tokenName(
              previewPrivateUsdUsdc.symbol,
            ),
          },
          activityRows: [
            for (final record in records)
              ?buildPrivateUsdActivityRow(
                context: context,
                record: record,
                zcashConfirmations: 2,
                privacyModeEnabled: privacyModeEnabled,
                onOpenPayout: () {},
              ),
          ],
          onBack: () {},
          onRefresh: () {},
          onConvert: () {},
        ),
      ),
    );
  }
}

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

// ── Forward conversion (M5, plan reference §9.7) ─────────────────────────

/// 2026-10-14 09:41 local: the forward previews' "now".
final previewPrivateUsdNow = DateTime(2026, 10, 14, 9, 41);

int _unix(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

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
      expiresAt: _unix(expiresAt),
      amount: '16000000',
      networkCost: '40000',
      relayerFee: '460000',
      receives: '15500000',
      depositZat: BigInt.from(49990000),
      depositFeeZat: BigInt.from(10000),
      maxTotalZat: BigInt.from(50000000),
      feeExpiresAt: _unix(expiresAt),
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
/// [previewPrivateUsdNow].
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
  return ApiForwardRecord(
    index: index,
    swapId:
        '0x7b2d41c09e5f8a3b6c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b',
    phase: phase,
    acceptedAt: _unix(acceptedAt),
    quoteExpiresAt: _unix(acceptedAt.add(const Duration(minutes: 5))),
    depositZat: BigInt.from(49990000),
    maxTotalZat: BigInt.from(50000000),
    amount: '16000000',
    receives: '15500000',
    relayerFee: '460000',
    t0: _unix(acceptedAt.add(const Duration(minutes: 40))),
    t1: _unix(acceptedAt.add(const Duration(hours: 2))),
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
    endedAt: outcome == null
        ? null
        : _unix(acceptedAt.add(const Duration(minutes: 12))),
  );
}

Widget _convertPreview(PrivateUsdConvertState state) =>
    PrivateUsdPreviewFrame(child: _ConvertPreview(state: state));

class _ConvertPreview extends StatefulWidget {
  const _ConvertPreview({required this.state});

  final PrivateUsdConvertState state;

  @override
  State<_ConvertPreview> createState() => _ConvertPreviewState();
}

class _ConvertPreviewState extends State<_ConvertPreview> {
  late final _controller = TextEditingController(text: widget.state.amountText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MobilePrivateUsdConvertView(
    state: widget.state,
    controller: _controller,
    autofocus: false,
    privateUsdAvailable: BigInt.from(1250400000),
    onAmountChanged: (_) {},
    onMax: () {},
    onReview: () {},
    onBack: () {},
    // The direction toggle shows on the amount step, as in the app (M6).
    onSwitchDirection: widget.state.step == PrivateUsdConvertStep.amount
        ? () {}
        : null,
  );
}

/// ZEC → USD with a quote: the ledger and its countdown.
Widget buildMobilePrivateUsdConvertUseCase(BuildContext context) =>
    _convertPreview(
      previewPrivateUsdConvertState(quote: previewPrivateUsdQuote()),
    );

/// "Getting quote…" while the typed amount is quoted.
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

/// The wallet still catching up: the line says so and "Max" waits.
Widget buildMobilePrivateUsdConvertSyncingUseCase(BuildContext context) =>
    _convertPreview(
      previewPrivateUsdConvertState(
        amountText: '',
        catchingUp: true,
        syncPercent: 42,
      ),
    );

Widget _reviewPreview(PrivateUsdConvertState state, {bool torOff = false}) =>
    PrivateUsdPreviewFrame(
      child: MobilePrivateUsdConvertReviewView(
        state: state,
        privacyModeEnabled: false,
        showsTorOffDisclosure: torOff,
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

/// The review once its quote ran out: "Quote expired", "Refresh quote".
Widget buildMobilePrivateUsdReviewExpiredUseCase(BuildContext context) =>
    _reviewPreview(
      previewPrivateUsdConvertState(
        quote: previewPrivateUsdQuote(holds: Duration.zero),
        step: PrivateUsdConvertStep.review,
      ),
    );

/// The review with the Tor-off token disclosure (shown once tokens exist,
/// M4).
Widget buildMobilePrivateUsdReviewTorOffUseCase(BuildContext context) =>
    _reviewPreview(
      previewPrivateUsdConvertState(
        quote: previewPrivateUsdQuote(),
        step: PrivateUsdConvertStep.review,
      ),
      torOff: true,
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
      zcashConfirmations: 2,
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

/// Forward, waiting for confirmations (1 of 2).
Widget buildMobilePrivateUsdProgressUseCase(BuildContext context) =>
    _progressPreview(
      PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(depositConfirmations: 1),
        wait: ApiForwardWait.confirming,
      ),
    );

/// An opening that has taken over 90 s: "Call it off".
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

/// The maker called it off: bringing the ZEC back.
Widget buildMobilePrivateUsdProgressRefundingUseCase(BuildContext context) =>
    _progressPreview(
      PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(phase: ApiForwardPhase.refunding),
        wait: ApiForwardWait.refunding,
      ),
    );

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

/// The home banner's conversion: waiting for confirmations (1 of 2).
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

/// The banner a conversion under way shows (for tests).
PrivateUsdBannerState previewPrivateUsdBanner() => PrivateUsdBannerState(
  path: const PrivateUsdRoutePath(
    direction: PrivateUsdDirection.forward,
    index: 7,
  ),
  title: PrivateUsdCopy.bannerToUsd,
  detail: privateUsdForwardStageLabel(
    PrivateUsdConversionStatus(
      record: previewPrivateUsdRecord(depositConfirmations: 1),
      wait: ApiForwardWait.confirming,
    ),
    zcashConfirmations: 2,
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
      zcashConfirmations: 2,
    ),
];
