import AppKit
import Darwin
import Foundation
import Network
import WebKit

/// The process-wide Railgun page: one page at a time, in a data store of its own whose every connection goes through
/// the Rust bridge's loopback SOCKS5 port, so the page follows the wallet's route. It outlives Flutter engines; the
/// Dart engine closes a leftover page when it starts. iOS's `RailgunPageHost`, on AppKit: the page sits in the main
/// window behind the Flutter view. Unlike iOS's, it never closes the page for memory, as Android's never does: macOS
/// compresses and swaps rather than ending an app, a pressure warning is routine beside a page this size, and the rest
/// of a sync (Railgun's transaction list and the wallet's proofs) runs in the page with no call waiting, so closing a
/// page that looked idle cut it off. Dart closes a page nobody uses after ten minutes.
@MainActor
final class RailgunPageHost {
  static let shared = RailgunPageHost()

  /// The page's only data store, fixed so a wipe finds it again. iOS's identifier; each app has its own stores.
  nonisolated static let storeID = UUID(uuidString: "5C1F5E3A-8B2D-4F6E-9A7C-3D2B1E0F4A6B")!

  /// The store and its proxy are macOS 14 APIs; below that Private USD stays hidden.
  nonisolated static var isSupported: Bool {
    if #available(macOS 14.0, *) { return true }
    return false
  }

  /// Events kept while nobody listens; the oldest go first.
  static let eventBuffer = 256
  /// WebKit refuses to remove a store a page still uses; it lets go shortly after the page closes.
  static let wipeAttempts = 5
  static let wipeRetryDelay: TimeInterval = 0.5

  /// The window the page sits in: the app's one Flutter window, set when its channels are registered.
  weak var window: NSWindow? {
    didSet {
      if let view = page?.webView { place(view) }
    }
  }

  private var page: RailgunPage?
  // Bumped by every close and load; a load from an older one gives up.
  private var generation = 0
  private var sink: ((String) -> Void)?
  private var buffered: [String] = []

  private init() {}

  /// A loaded page that is still open.
  var isOpen: Bool { page.map { $0.isLoaded && $0.isOpen } ?? false }

  /// Loads a fresh page, closing the one before it, with its traffic sent to the bridge at `proxyPort`. Returns
  /// once the page says it is ready.
  func load(proxyPort port: NWEndpoint.Port, debug: Bool) async throws {
    closePage(.disconnected("a new page replaced it"))
    let loading = generation
    guard #available(macOS 14.0, *) else {
      throw RailgunError.unavailable("Private USD needs macOS 14")
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
      bridgePort: port,
      rules: rules,
      debug: debug,
      onEvent: { [weak self] rawJSON in self?.emit(rawJSON) },
      onClosed: { [weak self] closed in self?.forget(closed) }
    )
    self.page = page
    if let view = page.webView { place(view) }
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
    // Below macOS 14 no page ever ran, so nothing was stored.
    guard #available(macOS 14.0, *) else { return }
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

  // MARK: The window

  /// In the window's content view, 1×1 and below the Flutter view, which covers it: WebKit treats a web view outside
  /// a window as hidden and throttles it. With no window yet, it waits for one (`window`'s `didSet`).
  private func place(_ view: NSView) {
    let host = window ?? Self.flutterWindow()
    // The page's calls count time only while this window is in sight, as WebKit runs the page (`RailgunPageClock`).
    RailgunPageClock.shared.follow(host)
    guard let content = host?.contentView else { return }
    guard view.superview !== content else { return }
    view.removeFromSuperview()
    view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
    content.addSubview(view, positioned: .below, relativeTo: nil)
  }

  /// The app's Flutter window when none was set: the main window, else the first that is not a panel.
  private static func flutterWindow() -> NSWindow? {
    NSApp.mainWindow ?? NSApp.windows.first { !($0 is NSPanel) }
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

  @available(macOS 14.0, *)
  private static func storeExists() async -> Bool {
    // WebKit sets up its main run loop when its first object is made, and these class methods don't make one. A wipe
    // before any page opened in this process (a reset from the lock screen) crashed when WebKit answered, on a run
    // loop that didn't exist yet. A throwaway in-memory store makes WebKit set it up first; it touches no disk.
    _ = WKWebsiteDataStore.nonPersistent()
    return await withCheckedContinuation { continuation in
      WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
        continuation.resume(returning: identifiers.contains(storeID))
      }
    }
  }

  /// The page's IndexedDB holds the encrypted Railgun wallet and the notes the engine decrypted for it, which it
  /// keeps unencrypted: keep it out of backups (on the Mac, Time Machine), as iOS keeps it out of iCloud. WebKit
  /// doesn't say which directory the store uses, so all of the container's `Library/WebKit` is excluded; the app has
  /// no other web content. The directory is made if WebKit hasn't made it yet, because a mark on a directory covers
  /// what is created inside it later; the mark is lost when the directory is made anew, so it is set before every
  /// load and again after. A failed mark never blocks the load; the next load tries again.
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
