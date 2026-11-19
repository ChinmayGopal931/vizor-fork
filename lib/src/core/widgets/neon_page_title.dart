import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';

/// A desktop screen's title in the neon look: the page title the phone's top
/// bar draws ([kNeonPageTitleStyle], spaced uppercase Thin).
///
/// [text] stays sentence case: it is upper-cased where drawn, and screen
/// readers get it as written.
class NeonPageTitle extends StatelessWidget {
  const NeonPageTitle(
    this.text, {
    this.color,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.textKey,
    super.key,
  });

  final String text;

  /// The title's colour; the accent text colour when null.
  final Color? color;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;

  /// A key for the [Text] itself, for screens whose tests find the title's
  /// text widget by key.
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      key: textKey,
      semanticsLabel: text,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      style: kNeonPageTitleStyle.copyWith(
        color: color ?? context.colors.text.accent,
      ),
    );
  }
}
