import Darwin
import Foundation
import Network
import UIKit
import WebKit

/// The process-wide Railgun page: one page at a time, in a data store of its own whose every connection goes through
/// the Rust bridge's loopback SOCKS5 port, so the page follows the wallet's route. It outlives Flutter engines; the
/// Dart engine closes a leftover page when it starts.
@MainActor
final class RailgunPageHost {
  static let shared = RailgunPageHost()

  /// The page's only data store, fixed so a wipe finds it again.
  nonisolated static let storeID = UUID(uuidString: "5C1F5E3A-8B2D-4F6E-9A7C-3D2B1E0F4A6B")!

  /// The store and its proxy are iOS 17 APIs; below that Private USD stays hidden.
  nonisolated static var isSupported: Bool {
    if #available(iOS 17.0, *) { return true }
    return false
  }

  /// Events kept while nobody listens; the oldest go first.
  static let eventBuffer = 256
  /// WebKit refuses to remove a store a page still uses; it lets go shortly after the page closes.
  static let wipeAttempts = 5
  static let wipeRetryDelay: TimeInterval = 0.5

  private var page: RailgunPage?
  // Bumped by every close and load; a load from an older one gives up.
  private var generation = 0
  private var sink: ((String) -> Void)?
  private var buffered: [String] = []
  private var observers: [NSObjectProtocol] = []

  private init() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
        let window = note.object as? UIWindow
        MainActor.assumeIsolated { self?.follow(window) }
      })
    observers.append(
      center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.memoryWarning() }
      })
  }

  /// A loaded page that is still open.
  var isOpen: Bool { page.map { $0.isLoaded && $0.isOpen } ?? false }

  /// Loads a fresh page, closing the one before it, with its traffic sent to the bridge at `proxyPort`. Returns
  /// once the page says it is ready.
  func load(proxyPort port: NWEndpoint.Port, debug: Bool) async throws {
    closePage(.disconnected("a new page replaced it"))
    let loading = generation
    guard #available(iOS 17.0, *) else {
      throw RailgunError.unavailable("Private USD needs iOS 17")
    }
    let rules: WKContentRuleList
    do {
      rules = try await RailgunContentRules.compiled()
    } catch {
      throw RailgunError.unavailable("the page's content rules did not compile")
    }
    guard loading == generation else { throw RailgunError.disconnected("closed while loading") }
    // Never a page without its proxy.
    guard Self.loopbackAccepts(port: port.rawValue) else {
      throw RailgunError.unavailable("the bridge is not running")
    }

    // The store's directory is out of backups before the store is first used; whatever WebKit creates in it later
    // is covered by the mark.
    Self.excludeWebDataFromBackup()

    // The store's proxy is set before the web view that uses it exists, and no request may go around a proxy that
    // refuses it.
    let store = WKWebsiteDataStore(forIdentifier: Self.storeID)
    var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))
    proxy.allowFailover = false
    store.proxyConfigurations = [proxy]

    let page = RailgunPage(
      store: store,
      rules: rules,
      debug: debug,
      onEvent: { [weak self] rawJSON in self?.emit(rawJSON) },
      onClosed: { [weak self] closed in self?.forget(closed) }
    )
    self.page = page
    place(page)
    try await page.load()
    guard loading == generation, page.isOpen else { throw RailgunError.disconnected("closed while loading") }
    // Again, in case WebKit made the directory anew; still before any call can bring the wallet in.
    Self.excludeWebDataFromBackup()
  }

  func call(_ method: RailgunMethod, paramsJSON: String) async throws -> String {
    guard let page, page.isLoaded, page.isOpen else { throw RailgunError.disconnected("no page") }
    return try await page.call(method, paramsJSON: paramsJSON)
  }

  /// Closes the page, if any; a load still waiting gives up. Idempotent.
  func close() {
    closePage(.disconnected("closed"))
  }

  /// Closes the page, then deletes its data store and everything in it, every account's wallet with it.
  func wipe() async throws {
    closePage(.disconnected("wiped"))
    // Below iOS 17 no page ever ran, so nothing was stored.
    guard #available(iOS 17.0, *) else { return }
    guard await Self.storeExists() else { return }
    for attempt in 1...Self.wipeAttempts {
      do {
        try await WKWebsiteDataStore.remove(forIdentifier: Self.storeID)
        return
      } catch {
        guard attempt < Self.wipeAttempts else { break }
        try? await Task.sleep(nanoseconds: UInt64(Self.wipeRetryDelay * 1_000_000_000))
      }
    }
    throw RailgunError.failed("the page's data could not be removed")
  }

  /// Where events go; with nobody listening they wait in a buffer.
  func setEventSink(_ sink: ((String) -> Void)?) {
    self.sink = sink
    guard let sink else { return }
    let waiting = buffered
    buffered.removeAll()
    waiting.forEach(sink)
  }

  private func emit(_ rawJSON: String) {
    if let sink {
      sink(rawJSON)
      return
    }
    buffered.append(rawJSON)
    if buffered.count > Self.eventBuffer {
      buffered.removeFirst(buffered.count - Self.eventBuffer)
    }
  }

  private func closePage(_ reason: RailgunError) {
    generation += 1
    let closing = page
    page = nil
    closing?.close(reason)
  }

  private func forget(_ closed: RailgunPage) {
    if page === closed { page = nil }
  }

  // A memory warning closes an idle page; it reopens on the next use.
  private func memoryWarning() {
    guard let page, page.isLoaded, page.isOpen, !page.hasPendingCalls else { return }
    closePage(.disconnected("closed to free memory"))
  }

  // MARK: The window

  /// In the key window, 1×1 and behind the Flutter view, which covers it: WebKit treats a web view outside a window
  /// as hidden and throttles it. With no window yet, it waits for one.
  private func place(_ page: RailgunPage) {
    guard let view = page.webView, let window = Self.keyWindow() else { return }
    put(view, in: window)
  }

  private func follow(_ window: UIWindow?) {
    guard let window, let view = page?.webView, view.window !== window else { return }
    put(view, in: window)
  }

  private func put(_ view: UIView, in window: UIWindow) {
    view.removeFromSuperview()
    view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    window.insertSubview(view, at: 0)
  }

  static func keyWindow() -> UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene =
      scenes.first { $0.activationState == .foregroundActive }
      ?? scenes.first { $0.activationState == .foregroundInactive }
      ?? scenes.first
    return scene?.keyWindow ?? scene?.windows.first
  }

  /// Whether something accepts TCP connections on loopback `port`: a connection made and dropped at once, which
  /// the bridge refuses quietly. A loopback connect is answered at once, so this never waits.
  nonisolated static func loopbackAccepts(port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return connected == 0
  }

  // MARK: Storage

  @available(iOS 17.0, *)
  private static func storeExists() async -> Bool {
    await withCheckedContinuation { continuation in
      WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
        continuation.resume(returning: identifiers.contains(storeID))
      }
    }
  }

  /// The page's IndexedDB holds the encrypted Railgun wallet and the notes the engine decrypted for it, which it
  /// keeps unencrypted: keep it out of iCloud and device backups. WebKit doesn't say which directory the store
  /// uses, so all of `Library/WebKit` is excluded; the app has no other web content. The directory is made if WebKit
  /// hasn't made it yet, because a mark on a directory covers what is created inside it later; the mark is lost when
  /// the directory is made anew, so it is set before every load and again after. A failed mark never blocks the
  /// load; the next load tries again.
  @discardableResult
  nonisolated static func excludeWebDataFromBackup(
    library: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
  ) -> Bool {
    guard let library else { return false }
    var webKit = library.appendingPathComponent("WebKit", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: webKit, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try webKit.setResourceValues(values)
      return true
    } catch {
      return false
    }
  }
}
