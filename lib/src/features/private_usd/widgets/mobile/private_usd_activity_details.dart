import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../core/config/zcash_explorer.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_copy_feedback.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/mobile/neon_motion.dart';
import '../../models/private_usd_activity_details.dart';
import '../../models/private_usd_explorer.dart';
import '../../private_usd_copy.dart';
import 'private_usd_flow_widgets.dart';

const _unfoldDuration = Duration(milliseconds: 220);
const _iconSize = 12.0;

/// Opens a transaction's [hash] on [explorer].
typedef PrivateUsdOpenTransaction =
    void Function(String hash, PrivateUsdExplorer explorer);

/// How a feed's Private USD rows unfold into their details: the rows open,
/// a row's toggle, and how a transaction opens on its explorers.
class PrivateUsdActivityDetailsConfig {
  const PrivateUsdActivityDetailsConfig({
    required this.open,
    required this.onToggle,
    required this.onOpenTransaction,
    this.zcashExplorerLabel = kDefaultZcashExplorerLabel,
  });

  /// The ids of the rows unfolded.
  final Set<String> open;
  final ValueChanged<String> onToggle;
  final PrivateUsdOpenTransaction onOpenTransaction;

  /// Settings' name for the wallet's Zcash explorer.
  final String zcashExplorerLabel;

  /// Row [rowId]'s details, unfolded while it is open.
  Widget detailsOf(String rowId, List<PrivateUsdActivityDetail> lines) =>
      PrivateUsdActivityDetailsView(
        key: ValueKey('private_usd_activity_details_$rowId'),
        lines: lines,
        open: open.contains(rowId),
        zcashExplorerLabel: zcashExplorerLabel,
        onOpenTransaction: onOpenTransaction,
      );
}

/// A Private USD activity row's [lines], unfolding under the row while
/// [open]: its values, a shortened one copied whole on a tap, and its
/// transactions, each with a link to its explorers.
class PrivateUsdActivityDetailsView extends StatefulWidget {
  const PrivateUsdActivityDetailsView({
    required this.lines,
    required this.open,
    required this.onOpenTransaction,
    this.zcashExplorerLabel = kDefaultZcashExplorerLabel,
    super.key,
  });

  final List<PrivateUsdActivityDetail> lines;
  final bool open;
  final PrivateUsdOpenTransaction onOpenTransaction;
  final String zcashExplorerLabel;

  @override
  State<PrivateUsdActivityDetailsView> createState() =>
      _PrivateUsdActivityDetailsViewState();
}

class _PrivateUsdActivityDetailsViewState
    extends State<PrivateUsdActivityDetailsView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _unfold = AnimationController(
    vsync: this,
    duration: _unfoldDuration,
    value: widget.open ? 1 : 0,
  )..addStatusListener(_onStatus);
  late final _curve = CurvedAnimation(
    parent: _unfold,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didUpdateWidget(PrivateUsdActivityDetailsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open == oldWidget.open) return;
    if (NeonMotion.reduced(context)) {
      _unfold.value = widget.open ? 1 : 0;
    } else if (widget.open) {
      unawaited(_unfold.forward());
    } else {
      unawaited(_unfold.reverse());
    }
  }

  // Folded away, the lines leave the tree, and screen readers with them.
  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  @override
  void dispose() {
    _curve.dispose();
    _unfold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.open && _unfold.isDismissed) return const SizedBox.shrink();
    return SizeTransition(
      sizeFactor: _curve,
      alignment: AlignmentDirectional.topStart,
      child: FadeTransition(
        opacity: _curve,
        child: IgnorePointer(
          ignoring: !widget.open,
          child: ExcludeSemantics(
            excluding: !widget.open,
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: PrivateUsdLedgerCard(
                rows: [
                  for (final line in widget.lines)
                    switch (line) {
                      PrivateUsdDetailNote(:final text) => _NoteLine(text),
                      PrivateUsdDetailValue() => _ValueLine(line),
                      PrivateUsdDetailTransaction() => _TransactionLine(
                        line,
                        zcashExplorerLabel: widget.zcashExplorerLabel,
                        onOpen: widget.onOpenTransaction,
                      ),
                    },
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NoteLine extends StatelessWidget {
  const _NoteLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
    child: Text(
      text,
      style: AppTypography.bodyExtraSmall.copyWith(
        color: context.colors.text.secondary,
      ),
    ),
  );
}

/// A ledger line, its shortened value copied whole on a tap.
class _ValueLine extends StatelessWidget {
  const _ValueLine(this.line);

  final PrivateUsdDetailValue line;

  @override
  Widget build(BuildContext context) {
    final copyText = line.copyText;
    if (copyText == null) {
      return PrivateUsdLedgerRow(label: line.label, value: line.value);
    }
    return MergeSemantics(
      child: Semantics(
        button: true,
        onTapHint: PrivateUsdCopy.detailsCopyHint,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => copyTextWithToast(
            context,
            text: copyText,
            toastMessage: PrivateUsdCopy.detailsCopied,
          ),
          child: PrivateUsdLedgerRow(
            label: line.label,
            value: line.value,
            trailing: AppIcon(
              AppIcons.copy,
              size: _iconSize,
              color: context.colors.icon.regular.withValues(alpha: 0.72),
            ),
          ),
        ),
      ),
    );
  }
}

/// A transaction's label, and a link to each of its explorers.
class _TransactionLine extends StatelessWidget {
  const _TransactionLine(
    this.line, {
    required this.zcashExplorerLabel,
    required this.onOpen,
  });

  final PrivateUsdDetailTransaction line;
  final String zcashExplorerLabel;
  final PrivateUsdOpenTransaction onOpen;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            line.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.bodyExtraSmall.copyWith(
              color: context.colors.text.secondary,
            ),
          ),
        ),
        for (final explorer in line.explorers) ...[
          const SizedBox(width: AppSpacing.s),
          _ExplorerLink(
            name: switch (explorer) {
              PrivateUsdExplorer.railscan => PrivateUsdCopy.explorerRailscan,
              PrivateUsdExplorer.etherscan => PrivateUsdCopy.explorerEtherscan,
              PrivateUsdExplorer.zcash => zcashExplorerLabel,
            },
            transaction: line.label,
            onTap: () => onOpen(line.hash, explorer),
          ),
        ],
      ],
    );
  }
}

/// An explorer's name lit as a link, opening outside the app.
class _ExplorerLink extends StatelessWidget {
  const _ExplorerLink({
    required this.name,
    required this.transaction,
    required this.onTap,
  });

  final String name;
  final String transaction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final glow = context.colors.neon.glow;
    return Semantics(
      link: true,
      label: PrivateUsdCopy.detailsOpenOn(transaction, name),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A custom explorer's host can be long.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodyExtraSmall.copyWith(color: glow),
                ),
              ),
              const SizedBox(width: AppSpacing.xxs),
              AppIcon(AppIcons.arrowTopRight, size: _iconSize, color: glow),
            ],
          ),
        ),
      ),
    );
  }
}
