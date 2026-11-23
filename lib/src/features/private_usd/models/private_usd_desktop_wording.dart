import 'package:flutter/foundation.dart';

/// Whether desktop copy names the computer rather than the Mac: each desktop
/// message that says "your Mac" has a twin that says "your computer", for
/// Linux and Windows (its key ends in `Linux`, where it came first). Which OS
/// runs is not a layout choice, so this reads `defaultTargetPlatform` (which
/// widget tests can set), and only desktop code asks.
bool get privateUsdComputerWording =>
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.windows;
