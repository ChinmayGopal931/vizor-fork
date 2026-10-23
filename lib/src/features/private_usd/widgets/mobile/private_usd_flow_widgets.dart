import 'package:flutter/material.dart' show Scaffold, SelectableText;
import 'package:flutter/widgets.dart';

import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../private_usd_copy.dart';

/// Railgun's fee for shielding or unshielding, as the screens state it
/// before a cost names its own.
const kPrivateUsdRailgunFeePercent = '0.25';

/// A Private USD flow screen: the top bar with its info button, the [body],
/// and the [action] pinned under it.
class PrivateUsdFlowScaffold extends StatelessWidget {
  const PrivateUsdFlowScaffold({
    required this.title,
    required this.onBack,
    required this.body,
    this.onInfo,
    this.action,
    super.key,
  });

  final String title;

  /// Null hides the back button, while a step holds the screen.
  final VoidCallback? onBack;
  final VoidCallback? onInfo;
  final Widget body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final onInfo = this.onInfo;
    final action = this.action;
    return Scaffold(
      backgroundColor: context.colors.background.window,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MobileTopNav.back(
              title: title,
              onBack: onBack,
              trailing: onInfo == null
                  ? null
                  : PrivateUsdInfoButton(onTap: onInfo),
            ),
            Expanded(child: body),
            if (action != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.s,
                  AppSpacing.sm,
                  AppSpacing.md,
                ),
                child: action,
              ),
          ],
        ),
      ),
    );
  }
}

/// A flow screen's scrolling body.
class PrivateUsdFlowColumn extends StatelessWidget {
  const PrivateUsdFlowColumn({
    required this.children,
    this.top = AppSpacing.xs,
    super.key,
  });

  final List<Widget> children;
  final double top;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(
      AppSpacing.sm,
      top,
      AppSpacing.sm,
      AppSpacing.sm,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

/// The info button of the Private USD screens' top bars.
class PrivateUsdInfoButton extends StatelessWidget {
  const PrivateUsdInfoButton({required this.onTap, super.key});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: PrivateUsdCopy.infoButton,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('mobile_private_usd_info'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: AppIcon(
              AppIcons.help,
              size: 20,
              color: context.colors.text.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// A ledger panel: its rows between hairlines.
class PrivateUsdLedgerCard extends StatelessWidget {
  const PrivateUsdLedgerCard({required this.rows, super.key});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MobileSurfaceCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++)
            DecoratedBox(
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : Border(
                        top: BorderSide(color: colors.border.subtleOpacity),
                      ),
              ),
              child: rows[i],
            ),
        ],
      ),
    );
  }
}

/// One line of a ledger: the label on the left, the value on the right,
/// always on one line (a long value shrinks to fit rather than wrap).
class PrivateUsdLedgerRow extends StatelessWidget {
  const PrivateUsdLedgerRow({
    required this.label,
    required this.value,
    this.trailing,
    super.key,
  });

  final String label;
  final String value;

  /// An icon after the value for what a tap on the row does: a copy, say.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    const style = AppTypography.bodyExtraSmall;
    final valueText = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Text(
        value,
        maxLines: 1,
        style: style.copyWith(color: colors.text.accent),
      ),
    );
    final trailing = this.trailing;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style.copyWith(color: colors.text.secondary),
              ),
            ),
            const SizedBox(width: AppSpacing.s),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * 0.64,
              ),
              child: trailing == null
                  ? valueText
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(child: valueText),
                        const SizedBox(width: AppSpacing.xxs),
                        trailing,
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A ledger entry that never fits one line, a full address: the value wraps
/// under its label.
class PrivateUsdLedgerAddress extends StatelessWidget {
  const PrivateUsdLedgerAddress({
    required this.label,
    required this.address,
    super.key,
  });

  final String label;
  final String address;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    const style = AppTypography.bodyExtraSmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: style.copyWith(color: colors.text.secondary)),
          const SizedBox(height: AppSpacing.xxs),
          SelectableText(
            address,
            style: style.copyWith(color: colors.text.accent),
          ),
        ],
      ),
    );
  }
}
