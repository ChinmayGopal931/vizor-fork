import Flutter
import Foundation
import Network

/// Binds the Flutter engine to the process-wide Railgun page, over the same channel contract as Android's
/// `RailgunHostHandler`. The page host outlives the engine.
///
/// Never log a call's `paramsJson`, its result or a failure's message: `start` carries keyed RPC URLs, `openWallet`
/// and `deleteWallet` a mnemonic, and engine errors can quote either.
final class RailgunHostHandler: NSObject, FlutterStreamHandler {
  static let methodChannelName = "com.zcash.wallet/railgun"
  static let eventChannelName = "com.zcash.wallet/railgun/events"

  /// Whether this build may debug the page at all; `load`'s `debug` can only narrow it.
  static var isDebugBuild: Bool {
    #if DEBUG
      return true
    #else
      return false
    #endif
  }

  private let debuggable: Bool

  init(debuggable: Bool = RailgunHostHandler.isDebugBuild) {
    self.debuggable = debuggable
    super.init()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "supported":
      result(RailgunPageHost.isSupported)
    case "load":
      guard
        let number = arguments?["proxyPort"] as? Int,
        (1...65535).contains(number),
        let port = NWEndpoint.Port(rawValue: UInt16(number))
      else {
        result(Self.badArgs("proxyPort"))
        return
      }
      let debug = debuggable && (arguments?["debug"] as? Bool) == true
      reply(result) {
        try await RailgunPageHost.shared.load(proxyPort: port, debug: debug)
        return nil
      }
    case "call":
      guard
        let name = arguments?["method"] as? String,
        let method = RailgunMethod(rawValue: name),
        let params = arguments?["paramsJson"] as? String
      else {
        result(Self.badArgs("method or paramsJson"))
        return
      }
      reply(result) { try await RailgunPageHost.shared.call(method, paramsJSON: params) }
    case "close":
      reply(result) {
        RailgunPageHost.shared.close()
        return nil
      }
    case "wipe":
      reply(result) {
        try await RailgunPageHost.shared.wipe()
        return nil
      }
    case "isOpen":
      reply(result) { RailgunPageHost.shared.isOpen }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // Flutter calls these on the main thread, as it does `handle`.
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    MainActor.assumeIsolated {
      RailgunPageHost.shared.setEventSink { events($0) }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    MainActor.assumeIsolated {
      RailgunPageHost.shared.setEventSink(nil)
    }
    return nil
  }

  /// Exactly one answer per call, on the main thread: a second one crashes the app, and none hangs Dart. The task
  /// answers once, when its body ends; the page answers every waiting call when it closes. Any failure but a
  /// `RailgunError` gets a fixed message: its own could quote a URL.
  private func reply(_ result: @escaping FlutterResult, _ body: @escaping @MainActor () async throws -> Any?) {
    Task { @MainActor in
      let answer: Any?
      do {
        answer = try await body()
      } catch let error as RailgunError {
        answer = error.flutterError
      } catch {
        answer = RailgunError.failed("the Railgun host failed").flutterError
      }
      result(answer)
    }
  }

  private static func badArgs(_ what: String) -> FlutterError {
    FlutterError(code: "bad_args", message: what, details: nil)
  }
}
