import Foundation
import WebKit

/// The page's allowlist as a `WKContentRuleList` (iOS reference §6.4): block everything, then let through the page's
/// own scheme, `blob:`, `data:` and https to the hosts in `RailgunEndpoints`. WebKit has no per-request hook for
/// network loads, so this stands in for Android's request filter. The bridge's allowlist stays the authority; this
/// and the page's CSP are defence in depth.
enum RailgunContentRules {
  /// Versioned: change it whenever the hosts change, so a stale compiled list is never reused.
  static let identifier = "railgun-allowlist-v2"

  /// The URL patterns let through, one rule each: WebKit's rule regexes have no alternation.
  static var allowedPatterns: [String] {
    ["^\(RailgunSchemeHandler.scheme)://\(RailgunSchemeHandler.host)/", "^blob:", "^data:"]
      + RailgunEndpoints.hosts.map { "^https://\($0.replacingOccurrences(of: ".", with: "\\."))/" }
  }

  /// The rule list's JSON.
  static func encoded() throws -> String {
    let block: [String: Any] = ["trigger": ["url-filter": ".*"], "action": ["type": "block"]]
    let allowed: [[String: Any]] = allowedPatterns.map {
      ["trigger": ["url-filter": $0], "action": ["type": "ignore-previous-rules"]]
    }
    let data = try JSONSerialization.data(
      withJSONObject: [block] + allowed,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return String(decoding: data, as: UTF8.self)
  }

  @MainActor private static var compiledList: WKContentRuleList?

  /// The list, compiled into the default store once per process.
  @MainActor
  static func compiled() async throws -> WKContentRuleList {
    if let compiledList { return compiledList }
    let list = try await compile(in: .default())
    compiledList = list
    return list
  }

  /// Compiles the list into `store`, replacing one of the same identifier.
  @MainActor
  static func compile(in store: WKContentRuleListStore) async throws -> WKContentRuleList {
    let json = try encoded()
    return try await withCheckedThrowingContinuation { continuation in
      store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
        if let list {
          continuation.resume(returning: list)
        } else {
          continuation.resume(throwing: error ?? RailgunError.unavailable("the page's content rules did not compile"))
        }
      }
    }
  }
}
