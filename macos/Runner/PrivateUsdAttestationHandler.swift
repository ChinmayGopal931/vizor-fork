import FlutterMacOS
import Foundation

/// The macOS side of `com.zcash.wallet/private_usd_attestation`, as iOS's (`ios/Runner/`): zecSwap's issuer checks
/// Android key attestation alone, so every `sign` is `unavailable`, and Dart then says conversions need an Android
/// device while a market maker asks for tokens. The same codes as Android's, so Dart treats every host alike.
final class PrivateUsdAttestationHandler {
  static let channelName = "com.zcash.wallet/private_usd_attestation"

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "sign":
      result(FlutterError(code: "unavailable", message: "the token issuer has no macOS mode yet", details: nil))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
