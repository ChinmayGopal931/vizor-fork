import 'package:flutter/widgets.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';

/// "Scan a QR code": the row a mobile recipient picker opens the camera
/// scanner from (ZEC send, Pay, Private USD send), the QR glyph in a round
/// frame beside two lines. The scanner itself is the caller's, usually
/// `MobileAddressScanCard` in a sheet.
class MobileScanAddressRow extends StatelessWidget {
  const MobileScanAddressRow({
    required this.onTap,
    this.padding = EdgeInsets.zero,
    this.iconFrameKey,
    this.scalesText = true,
    super.key,
  });

  /// Null disables the row.
  final VoidCallback? onTap;

  /// Around the glyph and the lines, inside the row's tap target.
  final EdgeInsetsGeometry padding;
  final Key? iconFrameKey;

  /// Whether the lines follow the system text size, the row growing with
  /// them. Send's recipient picker lays its lines out at fixed heights, so
  /// it keeps them unscaled.
  final bool scalesText;

  static const height = 44.0;
  static const title = 'Scan a QR code';
  static const subtitle = 'Scan an address using camera';

  /// Each line's own height, at the default text size: the two fit the row.
  static const _lineHeight = 17.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: scalesText
              ? const BoxConstraints(minHeight: height)
              : const BoxConstraints.tightFor(height: height),
          child: Padding(
            padding: padding,
            child: Row(
              children: [
                Container(
                  key: iconFrameKey,
                  width: AppAssetSize.size,
                  height: AppAssetSize.size,
                  decoration: BoxDecoration(
                    color: colors.background.neutralSubtleOpacity,
                    borderRadius: BorderRadius.circular(AppRadii.full),
                  ),
                  child: Center(
                    child: AppIcon(
                      AppIcons.qr,
                      size: AppAssetSize.icon,
                      color: colors.icon.accent,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.s),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Line(
                        title,
                        color: colors.text.accent,
                        scaled: scalesText,
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      _Line(
                        subtitle,
                        color: colors.text.secondary,
                        scaled: scalesText,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One line, at least [MobileScanAddressRow._lineHeight] tall; unscaled, it
/// is exactly that tall.
class _Line extends StatelessWidget {
  const _Line(this.text, {required this.color, required this.scaled});

  final String text;
  final Color color;
  final bool scaled;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: scaled
          ? const BoxConstraints(minHeight: MobileScanAddressRow._lineHeight)
          : const BoxConstraints.tightFor(
              height: MobileScanAddressRow._lineHeight,
            ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textScaler: scaled ? null : TextScaler.noScaling,
          style: AppTypography.labelLarge.copyWith(color: color),
        ),
      ),
    );
  }
}
