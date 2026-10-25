import Flutter
import Foundation

/// The iOS side of `com.zcash.wallet/private_usd_attestation`, the channel the Android Keystore signs a Privacy
/// Pass issuance's attestation on (plan M4, reference §5.9). zecSwap's issuer has no iOS mode yet (it checks Android
/// key attestation alone), so every `sign` is `unavailable`: Dart then says conversions need an Android device while
/// a market maker asks for tokens. The same codes as Android's, so Dart treats both hosts alike.
final class PrivateUsdAttestationHandler {
  static let channelName = "com.zcash.wallet/private_usd_attestation"

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "sign":
      result(FlutterError(code: "unavailable", message: "the token issuer has no iOS mode yet", details: nil))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
