import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../core/formatting/countdown_format.dart';
import '../../../../core/theme/app_theme.dart';
import '../../models/private_usd_pending_payment.dart';
import '../../private_usd_copy.dart';

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
      PrivateUsdPaymentProving(:final percent) => PrivateUsdCopy.paymentProving(
        percent,
      ),
      PrivateUsdPaymentWaitingForBlock(:final postedAt) =>
        PrivateUsdCopy.paymentWaitingForBlock(
          formatMinutesSeconds(widget.now().difference(postedAt)),
        ),
      PrivateUsdPaymentUpdatingBalance() =>
        PrivateUsdCopy.paymentUpdatingBalance,
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
