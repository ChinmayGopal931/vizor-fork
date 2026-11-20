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
/// The Mac's alone: the iOS host starts the page without the archive. A Rust test (`railgun_bridge.rs`) reads [host]
/// below, so keep it literal.
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

  /// Run once in the page's world before the `start` that reads the archive; idempotent, and true once the page
  /// will read it. The page took its transport (`railgunHost`) when it loaded, so hiding the WebKit host from what
  /// it reads later leaves the transport as it was; only the start's archive check reads it again. WebKit defines
  /// `window.webkit` non-configurable, so the prelude replaces its `messageHandlers` instead. Archive GETs go to
  /// [path], the rest of the page's requests as they were. Nothing is spliced into it.
  static let prelude = """
    const archive = 'https://\(host)/';
    const own = '\(path)';
    const marker = Symbol.for('veylor.railgunArchive');
    if (globalThis[marker] === true) return true;
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
    try {
      Object.defineProperty(globalThis.webkit, 'messageHandlers', {
        value: Object.freeze({}),
        configurable: true,
      });
    } catch {
      return false;
    }
    Object.defineProperty(globalThis, marker, { value: true });
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

/// One page's archive requests, fetched through its bridge with Android's limits: a GET of the archive on the
/// default https port, a minute and 16 MB an answer at most, no redirect followed, no cache, cookie or credential,
/// a fixed User-Agent, and the files as served (gzip, which the page checks against the archive's checksums; never
/// unzipped on the way). A failure is a 502, which the page takes as the archive's, as on Android. Everything runs on
/// the main thread: WebKit calls the scheme handler there, and the session's delegate queue is the main queue. It
/// logs nothing.
@MainActor
final class RailgunArchiveFetch: NSObject, URLSessionDataDelegate {
  private struct Fetch {
    let task: WKURLSchemeTask
    let dataTask: URLSessionDataTask
    var response: HTTPURLResponse?
    var body = Data()
  }

  /// Off until the page's start reads the archive: before that, a request under [RailgunArchive.path] is refused.
  var enabled = false

  private let bridgePort: NWEndpoint.Port
  private var session: URLSession?
  /// The scheme task each data task answers, by the data task's identifier.
  private var fetches: [Int: Fetch] = [:]
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
    guard #available(macOS 14.0, *), let session = session ?? makeSession() else {
      Self.answer(task, status: 502)
      return
    }
    var fetch = URLRequest(
      url: upstream,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: RailgunArchive.stall
    )
    fetch.httpMethod = "GET"
    fetch.httpShouldHandleCookies = false
    fetch.setValue(RailgunArchive.userAgent, forHTTPHeaderField: "User-Agent")
    // The files are gzip, checked against the archive's checksums as served: never unzipped on the way.
    fetch.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let dataTask = session.dataTask(with: fetch)
    fetches[dataTask.taskIdentifier] = Fetch(task: task, dataTask: dataTask)
    dataTask.resume()
  }

  /// WebKit stopped `task` (the page aborted it, or the page went): its fetch is cancelled and never answered.
  func stop(_ task: WKURLSchemeTask) {
    guard let entry = fetches.first(where: { $0.value.task === task }) else { return }
    fetches.removeValue(forKey: entry.key)
    entry.value.dataTask.cancel()
  }

  /// The page closed: every fetch is cancelled, none is answered, and nothing is fetched again.
  func close() {
    closed = true
    enabled = false
    fetches.removeAll()
    session?.invalidateAndCancel()
    session = nil
  }

  /// The archive's own session: through the bridge alone (no failover to a direct connection), with no cache,
  /// cookie or credential store, a stalled connection or read failing after 20 s and any answer after a minute.
  @available(macOS 14.0, *)
  private func makeSession() -> URLSession? {
    let configuration = URLSessionConfiguration.ephemeral
    var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: bridgePort))
    proxy.allowFailover = false
    configuration.proxyConfigurations = [proxy]
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = RailgunArchive.stall
    configuration.timeoutIntervalForResource = RailgunArchive.deadline
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    self.session = session
    return session
  }

  // MARK: URLSessionDataDelegate, on the main queue

  nonisolated func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    let id = dataTask.taskIdentifier
    let http = response as? HTTPURLResponse
    let allowed = MainActor.assumeIsolated { () -> Bool in
      guard
        fetches[id] != nil,
        let http,
        RailgunArchive.servable(http.statusCode),
        http.expectedContentLength <= Int64(RailgunArchive.maxBytes)
      else {
        fail(id)
        return false
      }
      fetches[id]?.response = http
      return true
    }
    completionHandler(allowed ? .allow : .cancel)
  }

  nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let id = dataTask.taskIdentifier
    MainActor.assumeIsolated {
      guard let fetch = fetches[id] else { return }
      guard fetch.body.count + data.count <= RailgunArchive.maxBytes else {
        fail(id)
        fetch.dataTask.cancel()
        return
      }
      fetches[id]?.body.append(data)
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
    let id = task.taskIdentifier
    let failed = error != nil
    MainActor.assumeIsolated {
      guard let fetch = fetches.removeValue(forKey: id) else { return }
      guard !failed, let response = fetch.response else {
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
    }
  }

  /// Answers fetch `id` as failed, if it waits still.
  private func fail(_ id: Int) {
    guard let fetch = fetches.removeValue(forKey: id) else { return }
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
