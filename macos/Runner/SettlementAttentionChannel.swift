import AppKit
import FlutterMacOS

/// `com.zcash.wallet/haptics` on the Mac, for its one Mac meaning: `settlementDeadline`, the phones' buzz when a
/// shielded USD → ZEC bridge first offers "Authorize settlement" (the user's turn) and again two minutes before it
/// closes. A Mac has no haptics to buzz, so it asks for the user's attention instead: the Dock icon bounces until
/// Veylor is active again (`NSApp.requestUserAttention`, nothing when it already is) and the user's alert sound plays.
/// Neither needs a permission or a notification, and nothing is shown or logged.
///
/// Dart's `privateUsdSettlementReminderProvider` decides when, as on the phones: only while the app is in the
/// foreground (a window showing, focused or not) and unlocked, once per offer and once per closing. Every other
/// haptics call answers not implemented, so Dart falls back as it did before this handler existed.
enum SettlementAttentionChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.zcash.wallet/haptics", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "settlementDeadline":
        _ = NSApp.requestUserAttention(.criticalRequest)
        NSSound.beep()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
