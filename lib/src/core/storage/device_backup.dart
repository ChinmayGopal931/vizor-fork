import 'dart:io' show Platform;

import 'package:flutter/services.dart';

const _deviceBackupChannel = MethodChannel('com.zcash.wallet/network_privacy');

/// Keeps [directory] out of iCloud and device backups on iOS, and out of Time
/// Machine on macOS. The native side creates the directory when it does not
/// exist yet, then sets `isExcludedFromBackup` on it. The mark goes when the
/// directory goes, so set it again whenever the directory is made.
///
/// Android has no runtime equivalent. `android:allowBackup="false"` keeps app
/// files out of cloud backup, and device-to-device transfer is governed by
/// `data_extraction_rules.xml`, whose paths are fixed at build time: a
/// directory named after the generated wallet database cannot be listed
/// there, so the rules leave every app file (`domain="file"`) out of a
/// transfer. Linux and Windows have no backup the app can mark.
Future<void> excludeFromDeviceBackup(String directory) async {
  if (!Platform.isIOS && !Platform.isMacOS) return;
  try {
    await _deviceBackupChannel.invokeMethod<void>('excludeFromBackup', {
      'path': directory,
    });
  } on MissingPluginException {
    // Test hosts and older builds have no native side to ask.
  }
}
