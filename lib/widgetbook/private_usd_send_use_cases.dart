import 'package:flutter/widgets.dart';

import '../src/features/private_usd/models/private_usd_balances.dart';
import '../src/features/private_usd/models/private_usd_send.dart';
import '../src/features/private_usd/models/railgun_models.dart';
import '../src/features/private_usd/screens/mobile/mobile_private_usd_send_review_screen.dart';
import '../src/features/private_usd/screens/mobile/mobile_private_usd_send_screen.dart';
import '../src/features/private_usd/screens/mobile/mobile_private_usd_send_status_screen.dart';
import '../src/features/private_usd/services/private_usd_spend_guard.dart';
import 'private_usd_use_cases.dart';

// ── Send and withdraw (M7, plan reference §9.4 S8, §9.7) ─────────────────

/// An EIP-55 address (the standard's own test vector) to withdraw to.
const previewPrivateUsdWithdrawAddress =
    '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';

/// Previews have no Rust: a full-length `0zk1` address reads as valid.
bool previewPrivateUsdIsRailgunAddress(String address) =>
    address.startsWith('0zk1') &&
    address.length == previewPrivateUsdRecipient.length;

final _balances = previewPrivateUsdBalance(available: 1250.4).balances;

/// The relayer's floor, $0.50, is what a send leaves until it is priced.
final _networkFee = PrivateUsdNetworkFee(
  token: previewPrivateUsdUsdc,
  minimum: BigInt.from(500000),
);

PrivateUsdSendForm _form(
  PrivateUsdSendMode mode, {
  String amountText = '',
  String recipient = '',
}) => PrivateUsdSendForm(
  mode: mode,
  token: previewPrivateUsdUsdc,
  amountText: amountText,
  recipient: recipient,
  networkFee: _networkFee,
);

Widget _send(PrivateUsdSendForm form) =>
    PrivateUsdPreviewFrame(child: _SendFormPreview(form: form));

class _SendFormPreview extends StatefulWidget {
  const _SendFormPreview({required this.form});

  final PrivateUsdSendForm form;

  @override
  State<_SendFormPreview> createState() => _SendFormPreviewState();
}

class _SendFormPreviewState extends State<_SendFormPreview> {
  late final _amount = TextEditingController(text: widget.form.amountText);
  late final _recipient = TextEditingController(text: widget.form.recipient);

  @override
  void dispose() {
    _amount.dispose();
    _recipient.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MobilePrivateUsdSendView(
    form: widget.form,
    balances: _balances,
    status: PrivateUsdSpendStatus.available,
    amountController: _amount,
    recipientController: _recipient,
    onAmountChanged: (_) {},
    onRecipientChanged: (_) {},
    onUseAll: () {},
    onPaste: () {},
    onReview: () {},
    onBack: () {},
    isRailgunAddress: previewPrivateUsdIsRailgunAddress,
    autofocus: false,
  );
}

/// $25 to another Railgun address: "Review" is enabled.
Widget buildMobilePrivateUsdSendUseCase(BuildContext context) => _send(
  _form(
    PrivateUsdSendMode.private,
    amountText: '25',
    recipient: previewPrivateUsdRecipient,
  ),
);

/// Not a `0zk` address.
Widget buildMobilePrivateUsdSendInvalidUseCase(BuildContext context) => _send(
  _form(
    PrivateUsdSendMode.private,
    amountText: '25',
    recipient: previewPrivateUsdRecipient.substring(0, 40),
  ),
);

/// A withdrawal to the zero address.
Widget buildMobilePrivateUsdWithdrawZeroUseCase(BuildContext context) => _send(
  _form(
    PrivateUsdSendMode.withdraw,
    amountText: '100',
    recipient: '0x0000000000000000000000000000000000000000',
  ),
);

/// All of it: the relayer's fee needs $0.50 of it.
Widget buildMobilePrivateUsdSendLeaveFeeUseCase(BuildContext context) => _send(
  _form(
    PrivateUsdSendMode.private,
    amountText: '1250.4',
    recipient: previewPrivateUsdRecipient,
  ),
);

final _privateRequest = PrivateUsdSendRequest(
  token: previewPrivateUsdUsdc,
  amount: BigInt.from(25000000),
  to: const RailgunPrivateDestination(previewPrivateUsdRecipient),
);

final _privateCost = PrivateUsdSendCost(
  railgunFee: BigInt.zero,
  feeBasisPoints: 0,
  networkFee: BigInt.from(500000),
  networkFeeToken: previewPrivateUsdUsdc.address,
);

final _withdrawRequest = PrivateUsdSendRequest(
  token: previewPrivateUsdUsdc,
  amount: BigInt.from(100000000),
  to: const RailgunPublicDestination(previewPrivateUsdWithdrawAddress),
);

final _withdrawCost = PrivateUsdSendCost(
  railgunFee: BigInt.from(250000),
  feeBasisPoints: 25,
  networkFee: BigInt.from(612340),
  networkFeeToken: previewPrivateUsdUsdc.address,
  networkFeeExpiresAt: 1792000000,
);

PrivateUsdSendForm _reviewed(
  PrivateUsdSendMode mode, {
  PrivateUsdSendPhase phase = PrivateUsdSendPhase.review,
  PrivateUsdSendStep? step,
  PrivateUsdSendOutcome? outcome,
}) {
  final private = mode == PrivateUsdSendMode.private;
  final request = private ? _privateRequest : _withdrawRequest;
  final cost = private ? _privateCost : _withdrawCost;
  return PrivateUsdSendForm(
    mode: mode,
    phase: phase,
    step: step,
    token: previewPrivateUsdUsdc,
    amountText: private ? '25' : '100',
    recipient: request.to.text,
    cost: cost,
    reviewed: request,
    isBusy: phase == PrivateUsdSendPhase.sending,
    outcome: outcome,
    networkFee: _networkFee.copyWith(quoted: cost.networkFee),
  );
}

Widget _review(PrivateUsdSendForm form) => PrivateUsdPreviewFrame(
  child: MobilePrivateUsdSendReviewView(
    form: form,
    balances: _balances,
    status: PrivateUsdSpendStatus.available,
    canConfirm: true,
    onBack: () {},
    onConfirm: () {},
  ),
);

/// A private send's review.
Widget buildMobilePrivateUsdSendReviewUseCase(BuildContext context) =>
    _review(_reviewed(PrivateUsdSendMode.private));

/// A withdrawal's review: Railgun's fee and the public notice.
Widget buildMobilePrivateUsdWithdrawReviewUseCase(BuildContext context) =>
    _review(_reviewed(PrivateUsdSendMode.withdraw));

Widget _status(PrivateUsdSendForm form, {int? proofPercent}) =>
    PrivateUsdPreviewFrame(
      child: MobilePrivateUsdSendStatusView(
        form: form,
        proofPercent: proofPercent,
        onDone: () {},
        onViewTransaction: form.phase == PrivateUsdSendPhase.done
            ? () {}
            : null,
      ),
    );

/// The page proves the send: 42 %.
Widget buildMobilePrivateUsdSendProvingUseCase(BuildContext context) => _status(
  _reviewed(
    PrivateUsdSendMode.private,
    phase: PrivateUsdSendPhase.sending,
    step: PrivateUsdSendStep.proving,
  ),
  proofPercent: 42,
);

const _txHash =
    '0x4b2e6a8c0d1f3a5c7e9b1d3f5a7c9e0b2d4f6a8c1e3b5d7f9a0c2e4b6d8f1a3c';

/// In a block: "View on Etherscan" and "Done".
Widget buildMobilePrivateUsdSendDoneUseCase(BuildContext context) => _status(
  _reviewed(
    PrivateUsdSendMode.private,
    phase: PrivateUsdSendPhase.done,
    outcome: const PrivateUsdSendSent(_txHash),
  ),
);

/// Handed to the relayer, not in a block yet.
Widget buildMobilePrivateUsdSendUnconfirmedUseCase(BuildContext context) =>
    _status(
      _reviewed(
        PrivateUsdSendMode.withdraw,
        phase: PrivateUsdSendPhase.done,
        outcome: const PrivateUsdSendUnconfirmed(_txHash),
      ),
    );

/// The fixtures' balance as a [PrivateUsdBalances], for tests.
PrivateUsdBalances get previewPrivateUsdSendBalances => _balances!;
