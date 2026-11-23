import Foundation
import Network
import WebKit

/// Anon's archive of Railgun's history, fetched for the page by the Mac's host as Android's host fetches it
/// (`RailgunArchiveFetch.kt`). The archive sends no CORS headers, so the page can't read it, and WebKit can't
/// intercept `https`. Before a `start` that reads the archive the host runs [prelude] in the page: the page's archive
/// requests then go to [path] on its own origin, which [RailgunPageSchemeHandler] answers through the page's own
/// bridge, and its start reads the archive, as the Android page's does (the page reads it only where it finds no
/// WebKit host). Every request goes through the Rust loopback SOCKS5 bridge, which resolves the hostname on the
/// wallet's route (Tor when that is on) and checks it against its allowlist, as it does the page's own connections;
/// never directly.
///
/// The Mac's, and iOS's since 2026-11-22: the iOS target compiles this file unchanged, so keep it free of AppKit and
/// UIKit. A Rust test (`railgun_bridge.rs`) reads [host] below, so keep it literal.
enum RailgunArchive {
  /// Anon's archive: the host the page's `ARCHIVES` names, which the bridge's allowlist and the page's CSP list.
  static let host = "digest.anon.inc"

  /// Where the page's archive requests go on its own origin: no file of the bundle lives under it.
  static let path = "/anon-archive/"

  /// Far above the archive's largest file and far below the app's memory: a body past it is refused, never kept.
  static let maxBytes = 16 * 1024 * 1024

  /// The page gives up on a request after a minute, and so does the host.
  static let deadline: TimeInterval = 60

  /// A connection or a read that stalls this long fails, as Android's connect and read timeouts.
  static let stall: TimeInterval = 20

  /// The same for every Mac, and Android's: the platform's own would name the Mac and its build.
  static let userAgent = "Mozilla/5.0"

  /// Sent in place of the Mac's own languages, which `URLSession` adds to every request it isn't given one for and
  /// which differ from one Mac to the next: any language, which is what Android's host means by sending none.
  static let acceptLanguage = "*"

  /// Android's connection pool (`ConfigAwareConnectionPool`'s defaults, which the app leaves alone): at most five
  /// connections kept idle for the next requests, each for five minutes at most.
  static let maxIdleConnections = 5
  static let keepAlive: TimeInterval = 5 * 60

  /// Run in the page's world before every `start` that reads the archive; idempotent, and true once the page will
  /// read it. The page took its transport (`railgunHost`) when it loaded, so hiding the WebKit host from what it reads
  /// later leaves the transport as it was; only the start's archive check reads it again. WebKit defines
  /// `window.webkit` non-configurable, so the prelude replaces its `messageHandlers` instead. Archive GETs go to
  /// [path], the rest of the page's requests as they were. Nothing is spliced into it.
  ///
  /// The prelude holds the `webkit` object it changed. WebKit makes that object anew once nothing in the page refers
  /// to it, and the new one has the real `messageHandlers`: a garbage collection between the prelude and the start
  /// showed the start the host again, and the page synced from rail-squid alone. 0.9.0's first mainnet sync did, and
  /// so did 6 of 15 starts of this host in a test (none of 15 since), where a page that collected garbage after the
  /// prelude saw the host every time.
  static let prelude = """
    const archive = 'https://\(host)/';
    const own = '\(path)';
    const marker = Symbol.for('veylor.railgunArchive');
    const webkit = globalThis.webkit;
    if (typeof webkit !== 'object' || webkit === null) return false;
    if (globalThis[marker] === undefined) {
      const pageFetch = globalThis.fetch;
      if (typeof pageFetch !== 'function') return false;
      const routed = function (input, init) {
        const method = init?.method === undefined ? 'GET' : String(init.method).toUpperCase();
        if (typeof input === 'string' && method === 'GET' && input.startsWith(archive)) {
          return pageFetch.call(globalThis, own + input.slice(archive.length), init);
        }
        return pageFetch.call(globalThis, input, init);
      };
      Object.defineProperty(globalThis, 'fetch', { value: routed, writable: true, configurable: true });
    }
    try {
      Object.defineProperty(webkit, 'messageHandlers', { value: Object.freeze({}), configurable: true });
    } catch {
      return false;
    }
    Object.defineProperty(globalThis, marker, { value: webkit, configurable: true });
    return globalThis.webkit?.messageHandlers?.railgunHost === undefined;
    """

  /// Whether a `start` asks the page to read the archive (`RailgunStartParams.archive`). Read for this alone; the
  /// params carry keyed RPC URLs and stay unlogged.
  static func startsWithArchive(_ paramsJSON: String) -> Bool {
    guard
      let data = paramsJSON.data(using: .utf8),
      let params = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      return false
    }
    return (params["archive"] as? Bool) == true
  }

  /// The archive URL a request to [path] on the page's origin stands for: the same path and query on the archive's
  /// host, over https on its default port. Nil for anything else.
  static func upstream(for url: URL?) -> URL? {
    guard
      let url,
      url.scheme == RailgunSchemeHandler.scheme,
      url.host == RailgunSchemeHandler.host,
      let page = URLComponents(url: url, resolvingAgainstBaseURL: false),
      page.percentEncodedPath.hasPrefix(path),
      page.fragment == nil
    else {
      return nil
    }
    let rest = page.percentEncodedPath.dropFirst(path.count)
    guard !rest.isEmpty, !rest.hasPrefix("/") else { return nil }
    var archive = URLComponents()
    archive.scheme = "https"
    archive.host = host
    archive.percentEncodedPath = "/" + rest
    archive.percentEncodedQuery = page.percentEncodedQuery
    return archive.url
  }

  /// Whether WebKit takes `status` as an answer the page reads: a success or an error. A redirect is never
  /// followed, and is a failure.
  static func servable(_ status: Int) -> Bool {
    (200...299).contains(status) || (400...599).contains(status)
  }

  /// The request for `upstream`, as Android's host makes it: a GET whose headers are the same on every Mac, with no
  /// cookie, and the files as served (gzip, checked against the archive's checksums as served: never unzipped on the
  /// way). No cache is read or written, and none is asked for `no-cache` either: the archive's CDN answers as it
  /// answers Android, and the page asks past its cache itself where it has to (`?v=`).
  static func request(for upstream: URL) -> URLRequest {
    var request = URLRequest(url: upstream, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: stall)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
    return request
  }
}

/// The page's scheme on the Mac: its own files (`RailgunSchemeHandler`, iOS's), and under [RailgunArchive.path] the
/// archive, fetched through the bridge once the page reads it. WebKit calls it on the main thread.
@MainActor
final class RailgunPageSchemeHandler: NSObject, WKURLSchemeHandler {
  private let files: RailgunSchemeHandler
  private let archive: RailgunArchiveFetch

  init(files: RailgunSchemeHandler, archive: RailgunArchiveFetch) {
    self.files = files
    self.archive = archive
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard RailgunArchiveFetch.isArchiveRequest(urlSchemeTask.request) else {
      files.webView(webView, start: urlSchemeTask)
      return
    }
    archive.start(urlSchemeTask)
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    archive.stop(urlSchemeTask)
    files.webView(webView, stop: urlSchemeTask)
  }
}

/// One page's archive requests, fetched through its bridge as Android's host fetches them (`RailgunArchiveFetch.kt`):
/// a GET of the archive on the default https port, a minute and 16 MB an answer at most, a 20 s stall, no redirect
/// followed, no cache, cookie or credential, the same headers on every Mac ([RailgunArchive.request]), and the files as
/// served. A failure is a 502, which the page tries again and then takes as the archive's, as on Android.
///
/// Its connections are Android's too. Android's `HttpURLConnection` speaks HTTP/1.1 only, so each connection carries
/// one request at a time and requests in flight together go out on connections of their own; one whose answer was
/// read whole goes back to a pool for the next request, and one whose request failed is closed. The page's next try
/// at a request therefore never goes out on the connection the last one failed on. Here each connection is a
/// [Connection], a session that carries one request at a time, kept by the same rules ([take], [keep]). One session
/// for every request, as before, multiplexed them all on one HTTP/2 connection, which a connection that stops
/// answering without closing (a stalled Tor circuit or network) held: in a test every try the page sent in the next
/// 100 s went out on such a connection, nearly all five of its tries at each request. A connection for every request,
/// and none kept, made a sync's requests 2.3 times slower in another, at a 265 ms round trip.
///
/// Everything runs on the main thread: WebKit calls the scheme handler there, and each session's delegate queue and the
/// network watch run on the main queue. It logs nothing.
@MainActor
final class RailgunArchiveFetch: NSObject, URLSessionDataDelegate {
  /// A session that carries one request at a time, so that its connection does too, as an HTTP/1.1 connection does:
  /// one connection, kept while its answers come back whole.
  private final class Connection {
    let session: URLSession
    /// The network it was made on ([RailgunArchiveFetch.network]).
    let network: Int
    /// When its last answer came back whole, on a clock that counts sleep.
    var idleSince: UInt64 = 0

    init(session: URLSession, network: Int) {
      self.session = session
      self.network = network
    }
  }

  /// One request in flight: the scheme task it answers, and the connection it alone goes out on. A class, so its body
  /// grows in place.
  private final class Fetch {
    let task: WKURLSchemeTask
    let connection: Connection
    let dataTask: URLSessionDataTask
    var response: HTTPURLResponse?
    var body = Data()

    init(task: WKURLSchemeTask, connection: Connection, dataTask: URLSessionDataTask) {
      self.task = task
      self.connection = connection
      self.dataTask = dataTask
    }
  }

  /// Off until the page's start reads the archive: before that, a request under [RailgunArchive.path] is refused.
  var enabled = false

  private let bridgePort: NWEndpoint.Port
  /// The requests in flight, by data task: each is its session's only one, and every session numbers its tasks from 1,
  /// so a task's identifier tells none apart.
  private var fetches: [ObjectIdentifier: Fetch] = [:]
  /// Connections whose last answer came back whole, waiting for the next request: the one idle longest first.
  private var idle: [Connection] = []
  /// Counts the network's changes. Android drops its pool when the default network changes, so that no connection
  /// made before is used again: the tunnels the bridge opened on the old network may be dead without having closed.
  private var network = 0
  private var watch: NWPathMonitor?
  private var closed = false

  init(bridgePort: NWEndpoint.Port) {
    self.bridgePort = bridgePort
    super.init()
  }

  nonisolated static func isArchiveRequest(_ request: URLRequest) -> Bool {
    request.url.map { $0.path.hasPrefix(RailgunArchive.path) } ?? false
  }

  func start(_ task: WKURLSchemeTask) {
    let request = task.request
    guard (request.httpMethod ?? "GET") == "GET" else {
      Self.answer(task, status: 405)
      return
    }
    guard enabled, !closed, let upstream = RailgunArchive.upstream(for: request.url) else {
      Self.answer(task, status: 404)
      return
    }
    guard #available(macOS 14.0, iOS 17.0, *) else {
      Self.answer(task, status: 502)
      return
    }
    watchNetwork()
    let connection = take()
    let dataTask = connection.session.dataTask(with: RailgunArchive.request(for: upstream))
    fetches[ObjectIdentifier(dataTask)] = Fetch(task: task, connection: connection, dataTask: dataTask)
    dataTask.resume()
  }

  /// WebKit stopped `task` (the page aborted it, or the page went): its fetch ends and is never answered, and its
  /// connection is closed, as a request that fails.
  func stop(_ task: WKURLSchemeTask) {
    guard let entry = fetches.first(where: { $0.value.task === task }) else { return }
    fetches.removeValue(forKey: entry.key)
    entry.value.connection.session.invalidateAndCancel()
  }

  /// The page closed: every fetch ends unanswered, every connection is closed, and nothing is fetched again.
  func close() {
    closed = true
    enabled = false
    watch?.cancel()
    watch = nil
    let open = fetches.values.map(\.connection) + idle
    fetches.removeAll()
    idle.removeAll()
    for connection in open { connection.session.invalidateAndCancel() }
  }

  // MARK: Connections, as Android's pool keeps them

  /// The connection a request goes out on: one kept idle, else a new one.
  @available(macOS 14.0, iOS 17.0, *)
  private func take() -> Connection {
    dropExpired()
    if !idle.isEmpty { return idle.removeFirst() }
    return Connection(session: makeSession(), network: network)
  }

  /// `connection`'s answer came back whole: it waits for the next request, unless the network changed since it was
  /// made or the page closed. Past [RailgunArchive.maxIdleConnections] the one idle longest is closed, and each is
  /// closed after [RailgunArchive.keepAlive] idle.
  private func keep(_ connection: Connection) {
    guard !closed, connection.network == network else {
      connection.session.invalidateAndCancel()
      return
    }
    connection.idleSince = Self.now()
    idle.append(connection)
    while idle.count > RailgunArchive.maxIdleConnections {
      idle.removeFirst().session.invalidateAndCancel()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + RailgunArchive.keepAlive) { [weak self] in
      MainActor.assumeIsolated { self?.dropExpired() }
    }
  }

  /// Closes every connection kept idle for [RailgunArchive.keepAlive] or longer.
  private func dropExpired() {
    let now = Self.now()
    let limit = UInt64(RailgunArchive.keepAlive * 1_000_000_000)
    idle.removeAll { connection in
      guard now - connection.idleSince >= limit else { return false }
      connection.session.invalidateAndCancel()
      return true
    }
  }

  /// Watches the network from the first request on: a change closes every connection kept idle, and those in flight
  /// are not kept after their answers. The first update is the network as it is.
  private func watchNetwork() {
    guard watch == nil, !closed else { return }
    let watch = NWPathMonitor()
    watch.pathUpdateHandler = { [weak self] _ in
      MainActor.assumeIsolated { self?.networkUpdated() }
    }
    watch.start(queue: .main)
    self.watch = watch
  }

  private var networkSeen = false

  private func networkUpdated() {
    guard networkSeen else {
      networkSeen = true
      return
    }
    network += 1
    let dropped = idle
    idle.removeAll()
    for connection in dropped { connection.session.invalidateAndCancel() }
  }

  /// Nanoseconds on a clock that keeps counting while the Mac sleeps, so a connection kept idle over a sleep has aged.
  private static func now() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC)
  }

  /// A session for one connection: through the bridge alone (no failover to a direct connection), with no cache,
  /// cookie or credential store, a stalled connection or read failing after 20 s and any answer after a minute.
  @available(macOS 14.0, iOS 17.0, *)
  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: bridgePort))
    proxy.allowFailover = false
    configuration.proxyConfigurations = [proxy]
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = RailgunArchive.stall
    configuration.timeoutIntervalForResource = RailgunArchive.deadline
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
  }

  // MARK: URLSessionDataDelegate, on the main queue

  nonisolated func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    let key = ObjectIdentifier(dataTask)
    let http = response as? HTTPURLResponse
    let allowed = MainActor.assumeIsolated { () -> Bool in
      guard let fetch = fetches[key] else { return false }
      guard
        let http,
        RailgunArchive.servable(http.statusCode),
        http.expectedContentLength <= Int64(RailgunArchive.maxBytes)
      else {
        fail(key)
        return false
      }
      fetch.response = http
      // A body that says how long it is is kept in one piece, as Android's host sizes its buffer.
      if http.expectedContentLength > 0 { fetch.body.reserveCapacity(Int(http.expectedContentLength)) }
      return true
    }
    completionHandler(allowed ? .allow : .cancel)
  }

  nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let key = ObjectIdentifier(dataTask)
    MainActor.assumeIsolated {
      guard let fetch = fetches[key] else { return }
      guard fetch.body.count + data.count <= RailgunArchive.maxBytes else {
        fail(key)
        return
      }
      fetch.body.append(data)
    }
  }

  /// A redirect is never followed: the answer is the redirect itself, which fails.
  nonisolated func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let key = ObjectIdentifier(task)
    let failed = error != nil
    MainActor.assumeIsolated {
      // One that failed, stopped or closed has ended already, its session with it.
      guard let fetch = fetches.removeValue(forKey: key) else { return }
      guard !failed, let response = fetch.response else {
        fetch.connection.session.invalidateAndCancel()
        Self.answer(fetch.task, status: 502)
        return
      }
      let declared = response.value(forHTTPHeaderField: "Content-Type") ?? ""
      let type = declared.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
      Self.answer(
        fetch.task,
        status: response.statusCode,
        type: type.isEmpty ? "application/octet-stream" : type,
        body: fetch.body
      )
      keep(fetch.connection)
    }
  }

  /// Answers fetch `key` as failed, if it waits still, and closes its connection.
  private func fail(_ key: ObjectIdentifier) {
    guard let fetch = fetches.removeValue(forKey: key) else { return }
    fetch.connection.session.invalidateAndCancel()
    Self.answer(fetch.task, status: 502)
  }

  /// `task` answered in full, once: a fetch leaves [fetches] before it is answered, and a stopped one is never
  /// answered (WebKit throws).
  private static func answer(
    _ task: WKURLSchemeTask,
    status: Int,
    type: String = "text/plain; charset=utf-8",
    body: Data = Data()
  ) {
    guard
      let url = task.request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": type,
          "Content-Length": String(body.count),
          "Cache-Control": "no-store",
        ]
      )
    else {
      task.didFailWithError(URLError(.badURL))
      return
    }
    task.didReceive(response)
    if !body.isEmpty { task.didReceive(body) }
    task.didFinish()
  }
}
