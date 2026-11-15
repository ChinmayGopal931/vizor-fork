import 'package:flutter/widgets.dart';

import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_deposits.dart';
import '../../private_usd_copy.dart';

/// One deposit state as a line of text (the Receive screen and the Private
/// USD screen's card).
class PrivateUsdDepositLineText extends StatelessWidget {
  const PrivateUsdDepositLineText({
    required this.line,
    required this.minimum,
    required this.screening,
    required this.privacyModeEnabled,
    super.key,
  });

  final PrivateUsdDepositLine line;
  final BigInt? minimum;
  final Duration screening;
  final bool privacyModeEnabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final usd = hideAmountIfPrivacyMode(
      formatPrivateUsd(line.amount),
      privacyModeEnabled: privacyModeEnabled,
      denomination: '',
    );
    final minimum = this.minimum;
    final (text, color) = switch (line.phase) {
      PrivateUsdDepositPhase.received => (
        PrivateUsdCopy.depositReceived(usd),
        colors.text.accent,
      ),
      PrivateUsdDepositPhase.underMinimum => (
        minimum == null
            ? PrivateUsdCopy.depositReceived(usd)
            : PrivateUsdCopy.depositUnderMinimum(
                usd,
                formatPrivateUsd(minimum),
              ),
        colors.text.secondary,
      ),
      PrivateUsdDepositPhase.waiting => (
        PrivateUsdCopy.depositWaitingLine(usd),
        colors.text.secondary,
      ),
      PrivateUsdDepositPhase.shielding => (
        PrivateUsdCopy.depositShieldingLine(usd),
        colors.text.accent,
      ),
      PrivateUsdDepositPhase.shielded => (
        PrivateUsdCopy.depositShieldedLine(
          usd,
          PrivateUsdCopy.about(screening),
        ),
        colors.text.positiveStrong,
      ),
      PrivateUsdDepositPhase.notShielding => (
        PrivateUsdCopy.depositNotShieldingLine(usd),
        colors.text.secondary,
      ),
    };
    return Text(
      text,
      key: ValueKey(
        'private_usd_deposit_line_${line.index}_${line.phase.name}',
      ),
      style: AppTypography.bodySmall.copyWith(color: color),
    );
  }
}
