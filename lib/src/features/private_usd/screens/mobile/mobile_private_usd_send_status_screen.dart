import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/formatting/address_display.dart';
import '../../../../core/widgets/mobile/mobile_transaction_progress_screen.dart';
import '../../models/private_usd_explorer.dart';
import '../../models/private_usd_send.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_send_provider.dart';
import '../../providers/railgun_engine_provider.dart';
import '../../services/railgun_engine.dart';

/// `/private-usd/send/status` (`extra`: the mode): the proof's progress
/// while it proves, then the outcome, pending while it is not in a block
/// yet. Back is blocked while it runs. When nothing was sent (busy, not
/// sent, repriced) it pops back to the review; Done pops with `true`.
class MobilePrivateUsdSendStatusScreen extends ConsumerStatefulWidget {
  const MobilePrivateUsdSendStatusScreen({required this.mode, super.key});

  final PrivateUsdSendMode mode;

  @override
  ConsumerState<MobilePrivateUsdSendStatusScreen> createState() =>
      _MobilePrivateUsdSendStatusScreenState();
}

class _MobilePrivateUsdSendStatusScreenState
    extends ConsumerState<MobilePrivateUsdSendStatusScreen> {
  var _left = false;

  @override
  void initState() {
    super.initState();
    // An outcome may land before this screen first builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _leaveIfBack(ref.read(privateUsdSendProvider(widget.mode)));
    });
  }

  void _leaveIfBack(PrivateUsdSendForm form) {
    final back =
        form.phase == PrivateUsdSendPhase.form ||
        form.phase == PrivateUsdSendPhase.review;
    if (!back || _left || !mounted) return;
    _left = true;
    context.pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final form = ref.watch(privateUsdSendProvider(widget.mode));
    ref.listen(
      privateUsdSendProvider(widget.mode),
      (_, next) => _leaveIfBack(next),
    );
    final engine = ref.watch(railgunEngineStateProvider);
    final proving = engine.phase == RailgunEnginePhase.proving;
    final prefix = ref.watch(
      privateUsdCurrentDeploymentProvider.select((d) => d?.explorerTxPrefix),
    );
    final txHash = switch (form.outcome) {
      PrivateUsdSendSent(:final txHash) => txHash,
      PrivateUsdSendUnconfirmed(:final txHash) => txHash,
      _ => null,
    };
    final uri = txHash == null ? null : privateUsdExplorerUri(prefix, txHash);
    return MobilePrivateUsdSendStatusView(
      form: form,
      proofPercent: proving && engine.proof != null
          ? (engine.proof!.progress * 100).round().clamp(0, 100)
          : null,
      onDone: () => context.pop(true),
      onViewTransaction: uri == null
          ? null
          : () => launchUrl(uri, mode: LaunchMode.externalApplication),
    );
  }
}

/// The status's content for a given form.
class MobilePrivateUsdSendStatusView extends StatelessWidget {
  const MobilePrivateUsdSendStatusView({
    required this.form,
    required this.onDone,
    this.proofPercent,
    this.onViewTransaction,
    super.key,
  });

  final PrivateUsdSendForm form;

  /// The page's proof, 0–100, while it proves.
  final int? proofPercent;
  final VoidCallback onDone;
  final VoidCallback? onViewTransaction;

  @override
  Widget build(BuildContext context) {
    final request = form.reviewed;
    final outcome = form.outcome;
    if (form.phase != PrivateUsdSendPhase.done || request == null) {
      final posting = form.step == PrivateUsdSendStep.posting;
      final percent = proofPercent;
      return MobileTransactionProgressScreen(
        phase: MobileTransactionProgressPhase.inProgress,
        title: posting
            ? PrivateUsdCopy.sendSending
            : percent == null
            ? PrivateUsdCopy.sendProving
            : PrivateUsdCopy.sendProvingPercent(percent),
        body: posting
            ? PrivateUsdCopy.sendLanding
            : PrivateUsdCopy.sendProvingDetail,
        canPop: false,
        titleKey: const ValueKey('mobile_private_usd_send_status_title'),
        bodyKey: const ValueKey('mobile_private_usd_send_status_body'),
      );
    }
    final unconfirmed = outcome is PrivateUsdSendUnconfirmed;
    final amount = formatPrivateUsdExact(
      request.amount,
      request.token.decimals,
    );
    final address = truncatedAddress(request.to.text);
    return MobileTransactionProgressScreen(
      phase: unconfirmed
          ? MobileTransactionProgressPhase.pending
          : MobileTransactionProgressPhase.succeeded,
      title: form.mode == PrivateUsdSendMode.private
          ? PrivateUsdCopy.sendDoneTitlePrivate
          : PrivateUsdCopy.sendDoneTitleWithdraw,
      body: unconfirmed
          ? PrivateUsdCopy.sendDoneUnconfirmedBody(amount, address)
          : PrivateUsdCopy.sendDoneBody(amount, address),
      canPop: true,
      primaryActionLabel: PrivateUsdCopy.done,
      onPrimaryAction: onDone,
      secondaryActionLabel: onViewTransaction == null
          ? null
          : PrivateUsdCopy.sendViewTx,
      onSecondaryAction: onViewTransaction,
      titleKey: const ValueKey('mobile_private_usd_send_status_title'),
      bodyKey: const ValueKey('mobile_private_usd_send_status_body'),
      primaryActionKey: const ValueKey('mobile_private_usd_send_status_done'),
      secondaryActionKey: const ValueKey('mobile_private_usd_send_status_tx'),
    );
  }
}
