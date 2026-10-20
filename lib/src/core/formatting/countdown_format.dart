/// [duration] as `m:ss`, never negative: a countdown or a short wait.
String formatMinutesSeconds(Duration duration) {
  final seconds = duration.isNegative ? 0 : duration.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
