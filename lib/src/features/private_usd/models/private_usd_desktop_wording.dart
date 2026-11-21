import 'package:flutter/foundation.dart';

/// Whether desktop copy names the computer rather than the Mac: each desktop
/// message that says "your Mac" has a Linux twin that says "your computer".
/// Which OS runs is not a layout choice, so this reads `defaultTargetPlatform`
/// (which widget tests can set), and only desktop code asks.
bool get privateUsdLinuxWording =>
    defaultTargetPlatform == TargetPlatform.linux;
