import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../core/formatting/countdown_format.dart';
import '../../../../core/theme/app_theme.dart';
import '../../models/private_usd_pending_payment.dart';
import '../../../../core/l10n/l10n.dart';

/// Where an outgoing payment in flight stands, on the Private USD screen:
/// its proof's progress, the wait for a block, whose clock ticks each
/// second, or the balance updating.
class PrivateUsdPendingPaymentLine extends StatefulWidget {
  const PrivateUsdPendingPaymentLine({
    required this.payment,
    this.now = DateTime.now,
    super.key,
  });

  final PrivateUsdPendingPayment payment;
  final DateTime Function() now;

  @override
  State<PrivateUsdPendingPaymentLine> createState() =>
      _PrivateUsdPendingPaymentLineState();
}

class _PrivateUsdPendingPaymentLineState
    extends State<PrivateUsdPendingPaymentLine> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _syncTick();
  }

  @override
  void didUpdateWidget(PrivateUsdPendingPaymentLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTick();
  }

  // Only the wait for a block has a clock to move.
  void _syncTick() {
    if (widget.payment is PrivateUsdPaymentWaitingForBlock) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = switch (widget.payment) {
      PrivateUsdPaymentProving(:final percent) =>
        context.l10n.privateUsdPaymentProving(percent),
      PrivateUsdPaymentWaitingForBlock(:final postedAt) =>
        context.l10n.privateUsdPaymentWaitingForBlock(
          formatMinutesSeconds(widget.now().difference(postedAt)),
        ),
      PrivateUsdPaymentUpdatingBalance() =>
        context.l10n.privateUsdPaymentUpdatingBalance,
    };
    return Text(
      text,
      key: const ValueKey('mobile_private_usd_pending_payment'),
      style: AppTypography.bodySmall.copyWith(
        color: context.colors.text.accent,
      ),
    );
  }
}
