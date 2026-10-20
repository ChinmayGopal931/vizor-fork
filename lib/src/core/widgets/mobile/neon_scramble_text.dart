import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'neon_motion.dart';

/// Glyphs a scrambling character cycles through. All are in Gotham, so the
/// effect never falls back to another face.
const _cipherGlyphs = r'0123456789ABCDEFXZ#$%&*+=/\<>?';

/// Text that re-encrypts itself when it changes: every character runs through
/// cipher glyphs and the new text locks in left to right, as a terminal
/// decrypting a field. [cipherStyle] paints the characters still scrambling.
/// Under reduced motion the new text just appears.
class NeonScrambleText extends StatefulWidget {
  const NeonScrambleText({
    required this.text,
    required this.style,
    required this.cipherStyle,
    this.trailing,
    this.semanticsLabel,
    this.overflow,
    this.duration = const Duration(milliseconds: 650),
    this.decryptOnAppear = false,
    super.key,
  });

  /// Also decrypt in when first shown, not only when [text] changes.
  final bool decryptOnAppear;

  final String text;
  final TextStyle style;
  final TextStyle cipherStyle;

  /// A span after the text that never scrambles (the ticker).
  final InlineSpan? trailing;

  /// What screen readers hear: [text] and [trailing] unless set. They never
  /// hear the cipher glyphs.
  final String? semanticsLabel;

  /// How the text ends when it does not fit its one line.
  final TextOverflow? overflow;
  final Duration duration;

  @override
  State<NeonScrambleText> createState() => _NeonScrambleTextState();
}

class _NeonScrambleTextState extends State<NeonScrambleText>
    with SingleTickerProviderStateMixin, NeonAppearMotion<NeonScrambleText> {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  )..addListener(() => setState(() {}));

  final _random = math.Random();
  String _from = '';

  @override
  void onAppear() {
    if (widget.decryptOnAppear) _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(NeonScrambleText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) return;
    if (NeonMotion.reduced(context)) {
      _controller.value = 1;
      return;
    }
    _from = oldWidget.text;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _line(List<InlineSpan> spans, {String? semanticsLabel}) => Text.rich(
    TextSpan(children: [...spans, ?widget.trailing]),
    semanticsLabel: semanticsLabel,
    maxLines: 1,
    overflow: widget.overflow,
  );

  @override
  Widget build(BuildContext context) {
    final t = _controller.value;
    if (t >= 1) {
      return _line([
        TextSpan(text: widget.text, style: widget.style),
      ], semanticsLabel: widget.semanticsLabel);
    }

    // The field keeps the longer of the two lengths while it scrambles, then
    // settles to the new one; each position locks a little after the last.
    final target = widget.text;
    final length = math.max(_from.length, target.length);
    final settled = StringBuffer();
    final scrambling = StringBuffer();
    var lockedCount = 0;
    for (var i = 0; i < length; i++) {
      final lockAt = 0.35 + 0.6 * (length <= 1 ? 1 : i / (length - 1));
      if (t >= lockAt) {
        lockedCount = i + 1;
      } else {
        break;
      }
    }
    settled.write(target.substring(0, math.min(lockedCount, target.length)));
    for (var i = lockedCount; i < length; i++) {
      final source = i < target.length ? target[i] : ' ';
      // Separators stay put so the amount keeps its shape while it churns.
      if (source == '.' || source == ',' || source == ' ') {
        scrambling.write(source);
      } else {
        scrambling.write(_cipherGlyphs[_random.nextInt(_cipherGlyphs.length)]);
      }
    }
    return _line(
      [
        TextSpan(text: settled.toString(), style: widget.style),
        TextSpan(text: scrambling.toString(), style: widget.cipherStyle),
      ],
      semanticsLabel:
          widget.semanticsLabel ??
          '$target${widget.trailing?.toPlainText() ?? ''}',
    );
  }
}

/// Cipher glyphs churning in place: a value being worked out (a quote on its
/// way). Under reduced motion it holds still.
class NeonCipherChurn extends StatefulWidget {
  const NeonCipherChurn({
    required this.style,
    this.length = 6,
    this.semanticsLabel,
    super.key,
  });

  final TextStyle style;
  final int length;
  final String? semanticsLabel;

  @override
  State<NeonCipherChurn> createState() => _NeonCipherChurnState();
}

class _NeonCipherChurnState extends State<NeonCipherChurn>
    with SingleTickerProviderStateMixin {
  /// How long each set of glyphs shows.
  static const _step = Duration(milliseconds: 70);

  final _random = math.Random();
  late final Ticker _ticker = createTicker(_tick);
  late String _text = _next();
  var _shownAt = Duration.zero;

  String _next() => String.fromCharCodes([
    for (var i = 0; i < widget.length; i++)
      _cipherGlyphs.codeUnitAt(_random.nextInt(_cipherGlyphs.length)),
  ]);

  void _tick(Duration elapsed) {
    if (elapsed - _shownAt < _step) return;
    _shownAt = elapsed;
    setState(() => _text = _next());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (NeonMotion.reduced(context)) {
      _ticker.stop();
    } else if (!_ticker.isActive) {
      _shownAt = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticsLabel,
      excludeSemantics: widget.semanticsLabel != null,
      child: Text(_text, style: widget.style, maxLines: 1),
    );
  }
}
