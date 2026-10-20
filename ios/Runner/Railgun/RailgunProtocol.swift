import Foundation

/// Every call the page answers, its wire name, and how long it may take: Kotlin's `RailgunMethod` table
/// (`kt/RailgunProtocol.kt`), which `RailgunHostTests` pins. The page's side is `index.js`.
enum RailgunMethod: String, CaseIterable {
  case start
  case openWallet
  /// A wallet's first sync reads all of Railgun's history, half an hour or more on Ethereum, and keeps none of it
  /// until it's done; a timeout closes the page, which starts it over.
  case refresh
  /// Local only: the page opens its database without a provider, on a page loaded for it alone.
  case deleteWallet
  case transfer
  case unshield
  case broadcasterFee
  case reverseCost
  case prepareReverse

  var timeout: TimeInterval {
    switch self {
    case .start: return 2 * 60
    case .openWallet: return 60
    case .refresh: return 2 * 60 * 60
    case .deleteWallet: return 60
    case .transfer: return 10 * 60
    case .unshield: return 10 * 60
    case .broadcasterFee: return 2 * 60
    case .reverseCost: return 30
    case .prepareReverse: return 10 * 60
    }
  }
}

/// A message from the page, as this build reads it.
enum RailgunMessage: Equatable {
  case ready
  /// A whole event message, `{"event": name, "data": …}`, as the page sent it.
  case event(name: String, rawJSON: String)
  case reply(id: Int64, resultJSON: String)
  case failure(id: Int64, error: RailgunError)
}

/// The page's wire format (Android reference §6.2). Params, results and events stay raw JSON text; Dart owns the
/// typed models.
enum RailgunProtocol {
  /// Engine lines; forwarded only from a page loaded with `debug`.
  static let log = "log"

  private static let events: Set<String> = [log, "scan", "proof", "screening"]

  /// `paramsJSON` must be exactly one JSON object, so it can't add keys to the envelope around it. It is spliced,
  /// not re-serialized, so large numbers keep every digit.
  static func request(id: Int64, method: RailgunMethod, paramsJSON: String) throws -> String {
    guard
      let data = paramsJSON.data(using: .utf8),
      (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    else {
      throw RailgunError.protocol("\(method.rawValue) params must be one JSON object")
    }
    return "{\"id\":\(id),\"method\":\"\(method.rawValue)\",\"params\":\(paramsJSON)}"
  }

  /// Nil for what this build can't read, except a reply: that one still fails its call.
  static func decode(_ text: String) -> RailgunMessage? {
    guard
      let data = text.data(using: .utf8),
      let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      return nil
    }
    if let event = message["event"] {
      guard let name = event as? String else { return nil }
      if name == "ready" { return .ready }
      return events.contains(name) ? .event(name: name, rawJSON: text) : nil
    }
    // A JSON `true` is an NSNumber too; it is no id.
    guard let id = message["id"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID() else { return nil }
    if let error = message["error"], !(error is NSNull) {
      guard let wire = error as? [String: Any] else {
        return .failure(id: id.int64Value, error: unreadable)
      }
      let reason = (wire["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "the page failed"
      let kind: RailgunError = (wire["code"] as? String) == "BAD_REQUEST" ? .protocol(reason) : .failed(reason)
      return .failure(id: id.int64Value, error: kind)
    }
    guard let result = rawJSON(message["result"]) else {
      return .failure(id: id.int64Value, error: unreadable)
    }
    return .reply(id: id.int64Value, resultJSON: result)
  }

  private static let unreadable = RailgunError.protocol("the page's reply is unreadable")

  /// The result as JSON text again: a string keeps its quotes, a missing result is `null`, and any other value,
  /// a bare number included, is encoded as itself.
  private static func rawJSON(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return "null" }
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed, .withoutEscapingSlashes]
      )
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }
}
