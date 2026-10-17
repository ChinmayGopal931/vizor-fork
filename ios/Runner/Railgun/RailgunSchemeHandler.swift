import Foundation
import WebKit

/// Serves `veylor-railgun://app/<path>` from the app bundle's `railgun/` folder and nothing else: no path outside it,
/// no directory, only `GET`, and only the types the page loads (iOS reference §6.4). WebKit can't intercept `https`,
/// so the page gets an origin of its own on a custom scheme, as hybrid shells do.
final class RailgunSchemeHandler: NSObject, WKURLSchemeHandler {
  nonisolated static let scheme = "veylor-railgun"
  nonisolated static let host = "app"
  nonisolated static let pageURL = URL(string: "veylor-railgun://app/index.html")!

  /// The page's CSP (`index.html`'s meta tag, which `RailgunHostTests` pins this to), also sent as a header.
  nonisolated static var contentSecurityPolicy: String {
    let hosts = RailgunEndpoints.hosts.map { "https://\($0)" }.joined(separator: " ")
    return "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src blob:; connect-src 'self' \(hosts); "
      + "base-uri 'none'; form-action 'none'"
  }

  struct Response: Equatable {
    let status: Int
    let headers: [String: String]
    let body: Data
  }

  /// Told when one of the page's own files is refused: a page loading without it would never answer.
  var onRefused: (@MainActor () -> Void)?

  private let root: URL?

  init(root: URL? = Bundle.main.url(forResource: "railgun", withExtension: nil)) {
    self.root = root
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    let request = urlSchemeTask.request
    let answer = Self.response(for: request, root: root)
    guard
      let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: answer.status,
        httpVersion: "HTTP/1.1",
        headerFields: answer.headers
      )
    else {
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }
    // Answered in full before returning, so WebKit can't stop the task halfway.
    urlSchemeTask.didReceive(response)
    urlSchemeTask.didReceive(answer.body)
    urlSchemeTask.didFinish()
    if answer.status != 200, let onRefused {
      // After the answer: whoever closes the page must not do so inside WebKit's callback.
      Task { @MainActor in onRefused() }
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    // Every task is answered within `start`; there is nothing left to stop.
  }

  /// What a request to the page's scheme gets.
  nonisolated static func response(for request: URLRequest, root: URL?) -> Response {
    guard (request.httpMethod ?? "GET") == "GET" else { return refusal(405) }
    guard
      let url = request.url,
      url.scheme == scheme,
      url.host == host,
      let root,
      let file = file(at: url.path, in: root),
      let type = contentType(of: file),
      let body = try? Data(contentsOf: file, options: .mappedIfSafe)
    else {
      return refusal(404)
    }
    return Response(
      status: 200,
      headers: [
        "Content-Type": type,
        "Content-Length": String(body.count),
        "Content-Security-Policy": contentSecurityPolicy,
        "Cache-Control": "no-store",
      ],
      body: body
    )
  }

  /// The file `path` names inside `root`, links resolved, or nil: nothing outside it, and no directories.
  nonisolated static func file(at path: String, in root: URL) -> URL? {
    let relative = path.drop { $0 == "/" }
    guard !relative.isEmpty else { return nil }
    let base = root.standardizedFileURL.resolvingSymlinksInPath()
    let file = base.appendingPathComponent(String(relative)).standardizedFileURL.resolvingSymlinksInPath()
    guard file.path.hasPrefix(base.path + "/") else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      return nil
    }
    return file
  }

  /// The types the page loads; anything else is refused. `instantiateStreaming` needs `application/wasm`.
  nonisolated static func contentType(of file: URL) -> String? {
    switch file.pathExtension.lowercased() {
    case "html": return "text/html; charset=utf-8"
    case "js": return "text/javascript; charset=utf-8"
    case "wasm": return "application/wasm"
    case "txt": return "text/plain; charset=utf-8"
    default: return nil
    }
  }

  private nonisolated static func refusal(_ status: Int) -> Response {
    Response(
      status: status,
      headers: ["Content-Type": "text/plain; charset=utf-8", "Content-Length": "0", "Cache-Control": "no-store"],
      body: Data()
    )
  }
}
