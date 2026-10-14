import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../app_icon.dart';

/// An inline warning line with an icon, in the destructive colour: a quote
/// that drifted or expired, or why a step did not start. Lifted from the
/// swap review so the Private USD screens share it.
class MobileWarningNotice extends StatelessWidget {
  const MobileWarningNotice({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: AppIcon(
            AppIcons.warning,
            size: AppIconSize.medium,
            color: colors.text.destructive,
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            message,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.destructive,
            ),
          ),
        ),
      ],
    );
  }
}
