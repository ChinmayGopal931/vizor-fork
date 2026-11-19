import FlutterMacOS
import Foundation
import IOKit.pwr_mgt

/// `com.zcash.wallet/screen_awake` on the Mac (`setEnabled {enabled}`), the flag `SyncKeepAwakeNativeHost` owns: while
/// it is on, an IOKit assertion keeps the display, and so the Mac, from sleeping on idle, as the phones keep their
/// screen on. A display that sleeps would lock the Mac and hide the app, and a hidden app pauses Private USD (plan
/// D9), so a Railgun first sync, or a bridge with a key step to come, would stall. It never stops the user locking
/// the screen or closing the lid, and the system drops the assertion with the process.
final class ScreenAwakeChannel {
  private static var channel: FlutterMethodChannel?
  private static var assertion: IOPMAssertionID?

  /// Shown by `pmset -g assertions`, never in the app.
  private static let reason = "Keeping the display awake while Shielded USD syncs or bridges" as CFString

  static func register(messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: "com.zcash.wallet/screen_awake",
      binaryMessenger: messenger
    )
    channel = methodChannel
    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "setEnabled":
        guard
          let arguments = call.arguments as? [String: Any],
          let enabled = arguments["enabled"] as? Bool
        else {
          result(FlutterError(code: "bad_args", message: "Expected enabled argument.", details: nil))
          return
        }
        if setEnabled(enabled) {
          result(nil)
        } else {
          result(FlutterError(code: "unavailable", message: "The power assertion was refused.", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Takes or releases the one assertion; asking twice for the same state does nothing.
  private static func setEnabled(_ enabled: Bool) -> Bool {
    if enabled {
      if assertion != nil { return true }
      var id = IOPMAssertionID(0)
      let status = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        reason,
        &id
      )
      guard status == kIOReturnSuccess else { return false }
      assertion = id
      return true
    }
    if let id = assertion {
      IOPMAssertionRelease(id)
      assertion = nil
    }
    return true
  }
}
