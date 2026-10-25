import Flutter
import Foundation

/// Why a Railgun page call failed. Each kind is one of the channel's error codes, the same as Android's, so Dart
/// treats both hosts alike. A `failed` message is the engine's own text and can quote a keyed RPC URL: it goes to
/// Dart, which redacts it before anything prints it, and is never logged here.
enum RailgunError: Error, Equatable {
  /// The page closed, its content process stopped, or another page replaced it. Dart reopens it on the next use.
  case disconnected(String)
  /// No answer in time, so the page was closed.
  case timeout(String)
  /// The page can't run here: below iOS 17 (its store and proxy), or without its content rules.
  case unavailable(String)
  /// A request or a reply one side couldn't read: a bug.
  case `protocol`(String)
  /// The engine, the chain or a screening node failed.
  case failed(String)
  /// A sync failed while the Ethereum RPC did not answer, or turned requests away.
  case rpcFailed(String)

  var code: String {
    switch self {
    case .disconnected: return "closed"
    case .timeout: return "timeout"
    case .unavailable: return "unavailable"
    case .protocol: return "protocol"
    case .failed: return "failed"
    case .rpcFailed: return "rpc_failed"
    }
  }

  var message: String {
    switch self {
    case let .disconnected(message), let .unavailable(message), let .protocol(message), let .failed(message),
      let .rpcFailed(message):
      return message
    case let .timeout(what):
      return "\(what) timed out"
    }
  }

  var flutterError: FlutterError { FlutterError(code: code, message: message, details: nil) }
}
