import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../../feedback/app_haptics.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/mobile/neon_scramble_text.dart';
import 'mobile_sync_status.dart';

/// Height of [MobileTopNav] — Figma `Mobile Top Nav` (node 4237:92733).
const double kMobileTopNavHeight = 72;

/// Mobile top navigation bar with the three Figma variants:
///
/// - [MobileTopNav.account] — avatar + account name (+ optional balance)
///   on the left, sync status label + edge glow indicator on the right.
///   Used by the tab roots.
/// - [MobileTopNav.steps] — back button + centered progress track. Used
///   by multi-step flows (onboarding, send wizard).
/// - [MobileTopNav.back] — back button + centered title. Used by
///   pushed detail screens; with a null [onBack] the button is omitted
///   and only the centered title remains (tab roots like Activity).
///
/// Metrics come from Figma node 4237:92733 (393×72; not tokenized as
/// variables yet, so they live here as constants). The Back-variant
/// title is a page title ([kNeonPageTitleStyle]) unless the screen passes
/// its own [titleStyle].
class MobileTopNav extends StatelessWidget {
  const MobileTopNav.account({
    required this.accountName,
    this.height = kMobileTopNavHeight,
    this.balanceLabel,
    this.syncLabel,
    this.syncLabelColor,
    this.syncIndicatorColor,
    this.syncAnimated = false,
    this.syncHighlightColor,
    this.avatar,
    this.onAccountTap,
    super.key,
  }) : _variant = _MobileTopNavVariant.account,
       title = '',
       titleStyle = null,
       titleMaxLines = 1,
       progress = 0,
       progressOffset = Offset.zero,
       progressTrackColor = null,
       showBackButton = true,
       onBack = null,
       trailing = null,
       foregroundColor = null,
       backIcon = AppIcons.chevronBackward;

  const MobileTopNav.steps({
    required this.progress,
    this.height = kMobileTopNavHeight,
    this.progressOffset = Offset.zero,
    this.progressTrackColor,
    this.onBack,
    this.showBackButton = true,
    super.key,
  }) : _variant = _MobileTopNavVariant.steps,
       accountName = '',
       balanceLabel = null,
       syncLabel = null,
       syncLabelColor = null,
       syncIndicatorColor = null,
       syncAnimated = false,
       syncHighlightColor = null,
       avatar = null,
       onAccountTap = null,
       title = '',
       titleStyle = null,
       titleMaxLines = 1,
       trailing = null,
       foregroundColor = null,
       backIcon = AppIcons.chevronBackward;

  const MobileTopNav.back({
    required this.title,
    this.onBack,
    this.trailing,
    this.backIcon = AppIcons.chevronBackward,
    this.titleStyle,
    this.titleMaxLines = 1,
    this.foregroundColor,
    this.height = kMobileTopNavHeight,
    super.key,
  }) : _variant = _MobileTopNavVariant.back,
       accountName = '',
       balanceLabel = null,
       syncLabel = null,
       syncLabelColor = null,
       syncIndicatorColor = null,
       syncAnimated = false,
       syncHighlightColor = null,
       avatar = null,
       onAccountTap = null,
       progress = 0,
       progressOffset = Offset.zero,
       progressTrackColor = null,
       showBackButton = true;

  final _MobileTopNavVariant _variant;

  /// Account variant: display name, optional secondary balance line, and
  /// the right-aligned sync status label. The label and edge-indicator
  /// colors default to the synced tokens; pass overrides for syncing /
  /// failed states.
  final String accountName;
  final String? balanceLabel;
  final String? syncLabel;
  final Color? syncLabelColor;
  final Color? syncIndicatorColor;

  /// When true (the live syncing state, reduced-motion off) the label
  /// shimmers a bright-green band across itself and the edge bar breathes
  /// a slow glow pulse. Otherwise the label and bar render static.
  final bool syncAnimated;

  /// Bright-green peak used for the shimmer band and the breathing glow.
  /// Falls back to [syncLabelColor] when null.
  final Color? syncHighlightColor;

  /// Account variant: leading 40×40 avatar. Falls back to a plain
  /// surface circle until real profile pictures are wired in.
  final Widget? avatar;
  final VoidCallback? onAccountTap;

  /// Steps variant: progress through the flow, 0.0–1.0.
  final double progress;

  /// Optional visual alignment and track tint for screen-specific step frames.
  final Offset progressOffset;
  final Color? progressTrackColor;
  final bool showBackButton;

  /// Back variant: centered title.
  final String title;
  final TextStyle? titleStyle;
  final int titleMaxLines;
  final Color? foregroundColor;

  /// Navigation height; the steps and back variants accept screen overrides.
  final double height;

  /// Back variant: right-aligned widget (e.g. the swap composer's
  /// "Powered by NEAR Intents" lockup — Figma 4686:102067).
  final Widget? trailing;

  final VoidCallback? onBack;

  /// Back-variant leading icon. Defaults to the chevron; the swap composer
  /// swaps it to a cross while its number-pad keyboard is open so the leading
  /// button dismisses the keyboard instead of leaving the tab.
  final String backIcon;

  static const _avatarSize = 40.0;
  static const _backButtonSize = 44.0;
  static const _progressTrackWidth = 196.0;
  static const _progressTrackHeight = 6.0;
  static const _syncStatusMaxShare = 0.65;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: switch (_variant) {
        _MobileTopNavVariant.account => _buildAccount(context),
        _MobileTopNavVariant.steps => _buildSteps(context),
        _MobileTopNavVariant.back => _buildBack(context),
      },
    );
  }

  Widget _buildAccount(BuildContext context) {
    final colors = context.colors;
    final account = _AccountBadge(
      accountName: accountName,
      balanceLabel: balanceLabel,
      avatar: avatar ?? _AvatarPlaceholder(size: _avatarSize),
      onAccountTap: onAccountTap,
    );

    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: account),
          ),
          if (syncLabel != null)
            // The status never takes more than this share of the bar, so the
            // account avatar keeps its room at large text sizes and with a
            // long label; past it the label ends in an ellipsis.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * _syncStatusMaxShare,
              ),
              child: MobileSyncStatus(
                label: syncLabel!,
                baseColor: syncLabelColor ?? colors.sync.text,
                highlightColor:
                    syncHighlightColor ?? syncLabelColor ?? colors.sync.text,
                indicatorColor: syncIndicatorColor ?? colors.sync.glow,
                animated: syncAnimated,
              ),
            )
          else
            const SizedBox(width: AppSpacing.sm),
        ],
      ),
    );
  }

  Widget _buildSteps(BuildContext context) {
    final colors = context.colors;
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: Transform.translate(
            offset: progressOffset,
            child: SizedBox(
              width: _progressTrackWidth,
              height: _progressTrackHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: progressTrackColor ?? colors.background.overlay,
                  borderRadius: BorderRadius.circular(AppRadii.full),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: progress.clamp(0.0, 1.0),
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.background.inverse,
                        borderRadius: BorderRadius.circular(AppRadii.full),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (showBackButton)
          Positioned(
            left: AppSpacing.s,
            child: _BackButton(size: _backButtonSize, onTap: onBack),
          ),
      ],
    );
  }

  Widget _buildBack(BuildContext context) {
    final colors = context.colors;
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: Padding(
            // Keep the centered title clear of the back button on both
            // sides so it stays optically centered.
            padding: const EdgeInsets.symmetric(
              horizontal: _backButtonSize + AppSpacing.s,
            ),
            // A page title is drawn uppercase; a screen's own style keeps
            // its case.
            child: Text(
              titleStyle == null ? title.toUpperCase() : title,
              maxLines: titleMaxLines,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: (titleStyle ?? kNeonPageTitleStyle).copyWith(
                color: foregroundColor ?? colors.text.accent,
              ),
            ),
          ),
        ),
        if (onBack != null)
          Positioned(
            left: AppSpacing.s,
            child: _BackButton(
              size: _backButtonSize,
              onTap: onBack,
              iconName: backIcon,
              color: foregroundColor,
            ),
          ),
        if (trailing != null) Positioned(right: AppSpacing.s, child: trailing!),
      ],
    );
  }
}

enum _MobileTopNavVariant { account, steps, back }

class _BackButton extends StatelessWidget {
  const _BackButton({
    required this.size,
    this.onTap,
    this.iconName = AppIcons.chevronBackward,
    this.color,
  });

  final double size;
  final VoidCallback? onTap;
  final String iconName;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: iconName == AppIcons.cross ? 'Close' : 'Back',
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: AppIcon(
              iconName,
              size: 24,
              color: color ?? context.colors.icon.accent,
            ),
          ),
        ),
      ),
    );
  }
}

class _AvatarPlaceholder extends StatelessWidget {
  const _AvatarPlaceholder({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: context.colors.background.overlay,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// The account in the top bar: only its portrait until tapped. A tap
/// decrypts the name in beside it, which folds away again after a moment;
/// tapping while the name shows (or a long press) opens the account switcher.
/// Screen readers get the name and the switcher directly.
class _AccountBadge extends StatefulWidget {
  const _AccountBadge({
    required this.accountName,
    required this.avatar,
    required this.onAccountTap,
    this.balanceLabel,
  });

  final String accountName;
  final String? balanceLabel;
  final Widget avatar;
  final VoidCallback? onAccountTap;

  @override
  State<_AccountBadge> createState() => _AccountBadgeState();
}

class _AccountBadgeState extends State<_AccountBadge> {
  static const _showFor = Duration(milliseconds: 3500);

  var _revealed = false;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _setRevealed(bool revealed) {
    _hide?.cancel();
    if (revealed) _hide = Timer(_showFor, () => _setRevealed(false));
    if (mounted && revealed != _revealed) {
      setState(() => _revealed = revealed);
    }
  }

  void _onTap() {
    if (_revealed) {
      _setRevealed(false);
      widget.onAccountTap?.call();
      return;
    }
    unawaited(AppHaptics.auxiliaryKey());
    _setRevealed(true);
  }

  void _onLongPress() {
    _setRevealed(false);
    widget.onAccountTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final nameStyle = AppTypography.labelLarge.copyWith(
      fontSize: 17,
      letterSpacing: 0.6,
      color: colors.text.accent,
    );
    return Semantics(
      key: const ValueKey('mobile_top_nav_account_semantics'),
      button: true,
      label: widget.accountName,
      onTap: widget.onAccountTap,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('mobile_top_nav_account'),
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        onLongPress: _onLongPress,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.avatar,
            Flexible(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerLeft,
                child: _revealed
                    ? Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.s),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            NeonScrambleText(
                              key: const ValueKey(
                                'mobile_top_nav_account_name',
                              ),
                              text: widget.accountName,
                              decryptOnAppear: true,
                              overflow: TextOverflow.ellipsis,
                              style: nameStyle,
                              cipherStyle: nameStyle.copyWith(
                                color: colors.neon.glow,
                                shadows: Neon.textGlow(
                                  colors.neon.glow,
                                  intensity: 0.5,
                                ),
                              ),
                            ),
                            if (widget.balanceLabel case final label?) ...[
                              const SizedBox(height: AppSpacing.xxs),
                              Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.labelLarge.copyWith(
                                  color: colors.text.secondary,
                                ),
                              ),
                            ],
                          ],
                        ),
                      )
                    : const SizedBox(height: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
