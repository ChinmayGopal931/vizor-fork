import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../private_usd_copy.dart';

/// A text field's paste button: the clipboard's text, trimmed, replaces the
/// field's, and [onPasted] hears it. An empty clipboard changes nothing.
class PrivateUsdPasteButton extends StatelessWidget {
  const PrivateUsdPasteButton({
    required this.controller,
    required this.onPasted,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String> onPasted;
  final bool enabled;

  Future<void> _paste(BuildContext context) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (!context.mounted || text == null || text.isEmpty) return;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    onPasted(text);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: PrivateUsdCopy.paste,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => unawaited(_paste(context)) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
          child: AppIcon(
            AppIcons.paste,
            size: 20,
            color: context.colors.text.primary,
          ),
        ),
      ),
    );
  }
}
