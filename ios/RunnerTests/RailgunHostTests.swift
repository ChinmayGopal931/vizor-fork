import Darwin
import WebKit
import XCTest

#if os(macOS)
  import FlutterMacOS
#else
  import Flutter
#endif

#if canImport(Runner)
  @testable import Runner
#else
  @testable import Vizor
#endif

/// The Railgun host's boundary (plan MI2.6): the envelope, the methods table, the scheme handler, the content rules
/// and exactly-once replies. The page itself runs in the device rounds.
final class RailgunHostTests: XCTestCase {
  // MARK: The envelope

  func testARequestCarriesItsIdMethodAndParams() throws {
    let request = try RailgunProtocol.request(id: 7, method: .openWallet, paramsJSON: #"{"network":"sepolia"}"#)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
    )
    XCTAssertEqual(object["id"] as? Int, 7)
    XCTAssertEqual(object["method"] as? String, "openWallet")
    XCTAssertEqual((object["params"] as? [String: Any])?["network"] as? String, "sepolia")
  }

  func testParamsAreOneObjectSplicedAsSent() throws {
    for params in ["[]", "1", #""text""#, "{} {}", #"{"a":1}, "b""#, "not json", ""] {
      XCTAssertThrowsError(try RailgunProtocol.request(id: 1, method: .start, paramsJSON: params), params) {
        XCTAssertEqual(($0 as? RailgunError)?.code, "PROTOCOL", params)
      }
    }
    // Not re-serialized, so a large number keeps every digit.
    let params = #"{"amount":123456789012345678901234567890}"#
    XCTAssertTrue(try RailgunProtocol.request(id: 1, method: .start, paramsJSON: params).hasSuffix(#""params":\#(params)}"#))
  }

  func testDecodesReplies() {
    XCTAssertEqual(
      RailgunProtocol.decode(#"{"id":3,"result":{"address":"0zk1"}}"#),
      .reply(id: 3, resultJSON: #"{"address":"0zk1"}"#)
    )
    XCTAssertEqual(RailgunProtocol.decode(#"{"id":4,"result":null}"#), .reply(id: 4, resultJSON: "null"))
    XCTAssertEqual(RailgunProtocol.decode(#"{"id":4}"#), .reply(id: 4, resultJSON: "null"))
    XCTAssertEqual(RailgunProtocol.decode(#"{"id":5,"result":"0zk1"}"#), .reply(id: 5, resultJSON: #""0zk1""#))
    XCTAssertEqual(RailgunProtocol.decode(#"{"id":6,"result":12}"#), .reply(id: 6, resultJSON: "12"))
    XCTAssertEqual(
      RailgunProtocol.decode(#"{"id":7,"result":"https://ppoi.fdi.network/"}"#),
      .reply(id: 7, resultJSON: #""https://ppoi.fdi.network/""#)
    )
  }

  func testFailuresKeepTheirKind() {
    XCTAssertEqual(
      RailgunProtocol.decode(#"{"id":1,"error":{"code":"BAD_REQUEST","message":"no wallet is open"}}"#),
      .failure(id: 1, error: .protocol("no wallet is open"))
    )
    XCTAssertEqual(
      RailgunProtocol.decode(#"{"id":1,"error":{"code":"FAILED","message":"the RPC timed out"}}"#),
      .failure(id: 1, error: .failed("the RPC timed out"))
    )
    XCTAssertEqual(
      RailgunProtocol.decode(#"{"id":1,"error":{"code":"SOMETHING_NEW","message":"?"}}"#),
      .failure(id: 1, error: .failed("?"))
    )
  }

  func testAReplyItCannotReadStillFailsItsCall() {
    guard case let .failure(id, error)? = RailgunProtocol.decode(#"{"id":5,"error":"a bare string"}"#) else {
      return XCTFail("an unreadable failure must still fail its call")
    }
    XCTAssertEqual(id, 5)
    XCTAssertEqual(error.code, "PROTOCOL")
  }

  func testDecodesEventsAndDropsWhatItDoesNotUnderstand() {
    XCTAssertEqual(RailgunProtocol.decode(#"{"event":"ready","data":null}"#), .ready)
    for (name, raw) in [
      ("scan", #"{"event":"scan","data":{"tree":"txid","status":"Updated","progress":0.4}}"#),
      ("proof", #"{"event":"proof","data":{"progress":0.25,"status":"proving"}}"#),
      ("log", #"{"event":"log","data":"scanning"}"#),
    ] {
      XCTAssertEqual(RailgunProtocol.decode(raw), .event(name: name, rawJSON: raw))
    }
    for unreadable in [
      "not json", "[1]", #"{"event":"unknown","data":1}"#, #"{"event":7,"data":1}"#, #"{"event":null}"#,
      #"{"result":1}"#, #"{"id":true,"result":1}"#,
    ] {
      XCTAssertNil(RailgunProtocol.decode(unreadable), unreadable)
    }
  }

  // MARK: The methods

  /// The same names and timeouts as Kotlin's `RailgunMethod`, read from its source (simulator only).
  func testTheMethodsAndTimeoutsMatchKotlin() throws {
    let kotlin = try Self.repositoryFile("android/app/src/main/kotlin/com/keplr/vizor/railgun/RailgunProtocol.kt")
    let entry = try NSRegularExpression(pattern: #"[A-Z_]+\("([A-Za-z]+)", (\d+)\.(seconds|minutes|hours)\)"#)
    var table: [String: TimeInterval] = [:]
    for match in entry.matches(in: kotlin, range: NSRange(kotlin.startIndex..., in: kotlin)) {
      let text = { (group: Int) in String(kotlin[Range(match.range(at: group), in: kotlin)!]) }
      let unit: TimeInterval = ["seconds": 1, "minutes": 60, "hours": 3600][text(3)]!
      table[text(1)] = TimeInterval(text(2))! * unit
    }
    XCTAssertEqual(table, Dictionary(uniqueKeysWithValues: RailgunMethod.allCases.map { ($0.rawValue, $0.timeout) }))
  }

  /// Every method the page answers, and only those: the debug-only `openNewWallet` is never exposed.
  func testThePageAnswersEveryMethod() throws {
    let page = try Self.repositoryFile("android/railgun-web/src/index.js")
    let table = try NSRegularExpression(pattern: #"const handlers = \{([^}]*)\}"#)
    let match = try XCTUnwrap(table.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)))
    let body = String(page[Range(match.range(at: 1), in: page)!])
    let names = body.split(separator: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined()
      .split(separator: ",")
      .map { $0.split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
      .filter { !$0.isEmpty }
    XCTAssertEqual(Set(names), Set(RailgunMethod.allCases.map(\.rawValue)))
    XCTAssertNil(RailgunMethod(rawValue: "openNewWallet"))
  }

  // MARK: The scheme handler

  @MainActor
  func testTheSchemeHandlerServesThePageFilesWithTheirTypes() throws {
    let root = try Self.pageFolder()
    for (path, type) in [
      ("index.html", "text/html; charset=utf-8"),
      ("railgun.js", "text/javascript; charset=utf-8"),
      ("poseidon_hash_wasm_bg.wasm", "application/wasm"),
      ("railgun.js.LEGAL.txt", "text/plain; charset=utf-8"),
    ] {
      let response = Self.response("veylor-railgun://app/\(path)", root: root)
      XCTAssertEqual(response.status, 200, path)
      XCTAssertEqual(response.headers["Content-Type"], type, path)
      XCTAssertEqual(response.headers["Content-Security-Policy"], RailgunSchemeHandler.contentSecurityPolicy, path)
      XCTAssertEqual(response.headers["Cache-Control"], "no-store", path)
      XCTAssertEqual(response.body, try Data(contentsOf: root.appendingPathComponent(path)), path)
    }
  }

  @MainActor
  func testTheSchemeHandlerRefusesEverythingElse() throws {
    let root = try Self.pageFolder()
    let outside = root.deletingLastPathComponent().appendingPathComponent("secret.html")
    try Data("secret".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link.html"),
      withDestinationURL: outside
    )
    for url in [
      "veylor-railgun://app/COPYING",  // shipped beside the bundle, never served
      "veylor-railgun://app/missing.js",
      "veylor-railgun://app/",
      "veylor-railgun://app/sub",
      "veylor-railgun://app/sub/",
      "veylor-railgun://app/../secret.html",
      "veylor-railgun://app/%2e%2e/secret.html",
      "veylor-railgun://app/sub/../../secret.html",
      "veylor-railgun://app/link.html",
      "veylor-railgun://evil/index.html",
      "https://app/index.html",
    ] {
      XCTAssertEqual(Self.response(url, root: root).status, 404, url)
    }
    var post = URLRequest(url: RailgunSchemeHandler.pageURL)
    post.httpMethod = "POST"
    XCTAssertEqual(RailgunSchemeHandler.response(for: post, root: root).status, 405)
    XCTAssertEqual(Self.response(RailgunSchemeHandler.pageURL.absoluteString, root: nil).status, 404)
  }

  /// The header the scheme handler sends is the policy the bundled page declares.
  @MainActor
  func testTheBundledPageDeclaresTheHeaderCSP() throws {
    let folder = try XCTUnwrap(Bundle.main.url(forResource: "railgun", withExtension: nil), "the railgun folder")
    let html = try String(contentsOf: folder.appendingPathComponent("index.html"), encoding: .utf8)
    let meta = try NSRegularExpression(pattern: #"http-equiv="Content-Security-Policy" content="([^"]*)""#)
    let match = try XCTUnwrap(meta.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)))
    let declared = String(html[Range(match.range(at: 1), in: html)!])
    XCTAssertEqual(Self.directives(declared), Self.directives(RailgunSchemeHandler.contentSecurityPolicy))
    for file in ["index.html", "railgun.js", "poseidon_hash_wasm_bg.wasm", "curve25519_scalarmult_wasm_bg.wasm"] {
      XCTAssertEqual(Self.response("veylor-railgun://app/\(file)", root: folder).status, 200, file)
    }
  }

  // MARK: The content rules

  func testTheContentRulesAllowExactlyThePageTheLocalSchemesAndTheHosts() throws {
    let rules = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(RailgunContentRules.encoded().utf8)) as? [[String: [String: String]]]
    )
    XCTAssertEqual(rules.first?["trigger"]?["url-filter"], ".*")
    XCTAssertEqual(rules.first?["action"]?["type"], "block")
    let allowed = try rules.dropFirst().map { rule -> NSRegularExpression in
      XCTAssertEqual(rule["action"]?["type"], "ignore-previous-rules")
      return try NSRegularExpression(pattern: try XCTUnwrap(rule["trigger"]?["url-filter"]))
    }
    XCTAssertEqual(allowed.count, 3 + RailgunEndpoints.hosts.count)
    let lets = { (url: String) in
      allowed.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
    }
    for url in [
      RailgunSchemeHandler.pageURL.absoluteString,
      "veylor-railgun://app/poseidon_hash_wasm_bg.wasm",
      "blob:veylor-railgun://app/0f1e",
      "data:application/wasm;base64,AGFzbQ==",
      "https://eth-sepolia.g.alchemy.com/v2/key",
      RailgunEndpoints.poiNodeURL,
    ] + RailgunEndpoints.hosts.map({ "https://\($0)/any/path" }) {
      XCTAssertTrue(lets(url), url)
    }
    for url in [
      "https://example.com/",
      "http://ethereum-sepolia-rpc.publicnode.com/",
      "https://ethereum-sepolia-rpc.publicnode.com:8443/",
      "https://evil.ipfs-lb.com/",
      "https://ipfs-lb.com.evil.example/",
      "https://ipfs-lbxcom/",
      "wss://ethereum-rpc.publicnode.com/",
      "veylor-railgun://evil/index.html",
      "file:///etc/hosts",
    ] {
      XCTAssertFalse(lets(url), url)
    }
  }

  @MainActor
  func testTheContentRulesCompile() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
    let list = try await RailgunContentRules.compile(in: store)
    XCTAssertEqual(list.identifier, RailgunContentRules.identifier)
  }

  // MARK: The bridge

  /// Invariant 20: the page never loads without a bridge that accepts on its port.
  func testTheBridgeProbeTellsAListenerFromAClosedPort() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
        bind(fd, pointer, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, pointer, &length) == 0
      }
    }
    XCTAssertTrue(bound)
    let port = UInt16(bigEndian: address.sin_port)
    XCTAssertTrue(RailgunPageHost.loopbackAccepts(port: port))
    Darwin.close(fd)
    XCTAssertFalse(RailgunPageHost.loopbackAccepts(port: port))
  }

  // MARK: Backups

  /// Plan DI6 and invariant 25: the page's web data directory is made and marked before the store is first used,
  /// and marking it again, once it exists, holds.
  func testTheWebDataDirectoryIsOutOfBackupsBeforeFirstUse() throws {
    let library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: library) }
    let webKit = library.appendingPathComponent("WebKit", isDirectory: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: webKit.path))

    XCTAssertTrue(RailgunPageHost.excludeWebDataFromBackup(library: library))
    XCTAssertEqual(try webKit.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

    XCTAssertTrue(RailgunPageHost.excludeWebDataFromBackup(library: library))
    let again = library.appendingPathComponent("WebKit", isDirectory: true)
    XCTAssertEqual(try again.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }

  // MARK: Exactly once

  @MainActor
  func testAReplyAnswersItsOwnCall() async throws {
    let page = FakePage()
    let first = Task { try await page.channel.call(.reverseCost, paramsJSON: "{}") }
    let second = Task { try await page.channel.call(.reverseCost, paramsJSON: "{}") }
    await page.posted(2)
    page.channel.receive(#"{"id":\#(page.id(1)),"result":"second"}"#)
    page.channel.receive(#"{"id":\#(page.id(0)),"result":"first"}"#)
    let answers = try await (first.value, second.value)
    XCTAssertEqual(answers.0, #""first""#)
    XCTAssertEqual(answers.1, #""second""#)
  }

  @MainActor
  func testACallWithoutAReplyTimesOutOnceAndALateReplyIsDropped() async throws {
    let page = FakePage(timeout: 0.05)
    let call = Task { try await page.channel.call(.reverseCost, paramsJSON: "{}") }
    await XCTAssertThrowsRailgun(try await call.value, .timeout("reverseCost"))
    page.channel.receive(#"{"id":\#(page.id(0)),"result":"late"}"#)
    XCTAssertTrue(page.channel.isOpen)
  }

  @MainActor
  func testAnUnreadableReplyFailsTheCallAtOnce() async throws {
    let page = FakePage()
    let call = Task { try await page.channel.call(.refresh, paramsJSON: "{}") }
    await page.posted(1)
    page.channel.receive(#"{"id":\#(page.id(0)),"error":"a bare string"}"#)
    await XCTAssertThrowsRailgun(try await call.value, .protocol("the page's reply is unreadable"))
  }

  @MainActor
  func testClosingFailsWhatWaitsAndWhatComesAfter() async throws {
    let page = FakePage()
    let call = Task { try await page.channel.call(.refresh, paramsJSON: "{}") }
    await page.posted(1)
    page.channel.close(.disconnected("the page's content process stopped"))
    page.channel.receive(#"{"id":\#(page.id(0)),"result":"late"}"#)
    page.channel.close(.disconnected("closed again"))
    XCTAssertFalse(page.channel.isOpen)
    await XCTAssertThrowsRailgun(try await call.value, .disconnected("the page's content process stopped"))
    await XCTAssertThrowsRailgun(
      try await page.channel.call(.refresh, paramsJSON: "{}"),
      .disconnected("the page's content process stopped")
    )
    XCTAssertEqual(page.requests.count, 1)
  }

  @MainActor
  func testACallThePageDidNotTakeFailsOnce() async throws {
    let page = FakePage(takes: false)
    await XCTAssertThrowsRailgun(
      try await page.channel.call(.start, paramsJSON: "{}"),
      .disconnected("the page did not take the call")
    )
    page.channel.close(.disconnected("closed"))
  }

  @MainActor
  func testTheHelloOnlyCountsOnItsOwnChannel() async throws {
    let other = FakePage()
    other.channel.receive(#"{"event":"ready","data":null}"#)
    let page = FakePage()
    await XCTAssertThrowsRailgun(try await page.channel.awaitReady(timeout: 0.05), .timeout("loading the page"))
    page.channel.receive(#"{"event":"ready","data":null}"#)
    try await page.channel.awaitReady(timeout: 0.05)
    XCTAssertTrue(page.channel.isReady)
  }

  @MainActor
  func testClosingBeforeTheHelloFailsTheLoad() async throws {
    let page = FakePage()
    let ready = Task { try await page.channel.awaitReady(timeout: 30) }
    await Task.yield()
    page.channel.close(.disconnected("the page did not load"))
    await XCTAssertThrowsRailgun(try await ready.value, .disconnected("the page did not load"))
  }

  @MainActor
  func testEventsGoToTheirListener() {
    let page = FakePage()
    let proof = #"{"event":"proof","data":{"progress":0.5,"status":"proving"}}"#
    page.channel.receive(proof)
    XCTAssertEqual(page.events.map(\.1), [proof])
    XCTAssertTrue(page.channel.isOpen)
  }

  @MainActor
  func testTheHandlerAnswersEachCallOnce() async {
    let handler = RailgunHostHandler(debuggable: false)
    let calls: [(String, Any?, String?)] = [
      ("load", ["proxyPort": 0, "debug": false], "BAD_ARGS"),
      ("load", ["proxyPort": 65536, "debug": false], "BAD_ARGS"),
      ("call", ["method": "openNewWallet", "paramsJson": "{}"], "BAD_ARGS"),
      ("call", ["method": "refresh"], "BAD_ARGS"),
      ("call", ["method": "refresh", "paramsJson": "{}"], "CLOSED"),
    ]
    for (method, arguments, code) in calls {
      let answers = Answers()
      handler.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { answers.record($0) }
      await answers.settle()
      XCTAssertEqual(answers.values.count, 1, method)
      XCTAssertEqual((answers.values.first as? FlutterError)?.code, code, method)
    }
    let supported = Answers()
    handler.handle(FlutterMethodCall(methodName: "supported", arguments: nil)) { supported.record($0) }
    await supported.settle()
    XCTAssertEqual(supported.values.count, 1)
    XCTAssertEqual(supported.values.first as? Bool, RailgunPageHost.isSupported)
    let isOpen = Answers()
    handler.handle(FlutterMethodCall(methodName: "isOpen", arguments: nil)) { isOpen.record($0) }
    await isOpen.settle()
    XCTAssertEqual(isOpen.values.count, 1)
    XCTAssertEqual(isOpen.values.first as? Bool, false)
  }

  // MARK: Helpers

  /// Reads a file of this repository, found from this test's own path; skips where the tree isn't reachable.
  private static func repositoryFile(_ path: String, file: StaticString = #filePath) throws -> String {
    let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
      throw XCTSkip("\(path) is not readable from here")
    }
    return text
  }

  /// A page folder of its own: the bundle's names with stand-in contents, and a subfolder.
  private static func pageFolder() throws -> URL {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = parent.appendingPathComponent("railgun")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    for name in [
      "index.html", "railgun.js", "poseidon_hash_wasm_bg.wasm", "railgun.js.LEGAL.txt", "COPYING", "sub/inner.js",
    ] {
      try Data("contents of \(name)".utf8).write(to: root.appendingPathComponent(name))
    }
    return root
  }

  private static func response(_ url: String, root: URL?) -> RailgunSchemeHandler.Response {
    RailgunSchemeHandler.response(for: URLRequest(url: URL(string: url)!), root: root)
  }

  /// A CSP's directives, each source list sorted after its name.
  private static func directives(_ policy: String) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for directive in policy.split(separator: ";") {
      let parts = directive.split(separator: " ").map(String.init)
      guard let name = parts.first else { continue }
      result[name] = parts.dropFirst().sorted()
    }
    return result
  }
}

/// A channel whose page records what it is sent.
@MainActor
private final class FakePage {
  private(set) var requests: [String] = []
  private(set) var events: [(String, String)] = []
  private(set) var channel: RailgunChannel!

  init(timeout: TimeInterval? = nil, takes: Bool = true) {
    channel = RailgunChannel(
      deliver: { [weak self] request, failed in
        if takes { self?.requests.append(request) } else { failed() }
      },
      onEvent: { [weak self] name, rawJSON in self?.events.append((name, rawJSON)) },
      timeout: { timeout ?? $0.timeout }
    )
  }

  /// Waits until `count` requests went out.
  func posted(_ count: Int) async {
    while requests.count < count { await Task.yield() }
  }

  func id(_ request: Int) -> Int64 {
    let object = try? JSONSerialization.jsonObject(with: Data(requests[request].utf8)) as? [String: Any]
    return (object?["id"] as? NSNumber)?.int64Value ?? -1
  }
}

/// What a `FlutterResult` was given.
@MainActor
private final class Answers {
  private(set) var values: [Any?] = []

  func record(_ value: Any?) {
    values.append(value)
  }

  /// Lets the handler's task answer, then a little longer, so a second answer would show.
  func settle() async {
    for _ in 0..<50 where values.isEmpty {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
  }
}

@MainActor
private func XCTAssertThrowsRailgun<T>(
  _ expression: @autoclosure () async throws -> T,
  _ expected: RailgunError,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("expected \(expected.code)", file: file, line: line)
  } catch {
    XCTAssertEqual(error as? RailgunError, expected, file: file, line: line)
  }
}
