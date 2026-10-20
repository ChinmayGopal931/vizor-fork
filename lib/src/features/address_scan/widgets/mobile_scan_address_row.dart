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
    super.key,
  });

  /// Null disables the row.
  final VoidCallback? onTap;

  /// Around the glyph and the lines, inside the row's tap target.
  final EdgeInsetsGeometry padding;
  final Key? iconFrameKey;

  static const height = 44.0;
  static const title = 'Scan a QR code';
  static const subtitle = 'Scan an address using camera';

  /// Each line's own height: the two always fit the row.
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
        child: SizedBox(
          height: height,
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
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Line(title, color: colors.text.accent),
                      const SizedBox(height: AppSpacing.xxs),
                      _Line(subtitle, color: colors.text.secondary),
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

/// One line at a fixed height, unscaled, so the row keeps its height.
class _Line extends StatelessWidget {
  const _Line(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MobileScanAddressRow._lineHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.noScaling),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.labelLarge.copyWith(color: color),
          ),
        ),
      ),
    );
  }
}
