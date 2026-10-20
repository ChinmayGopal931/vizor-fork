import Foundation
import UIKit
import WebKit

/// One page's end of the transport: requests out, replies matched back to them, events to their listener. Every
/// call is answered exactly once, by its reply, its failure, its timeout or the close, and everything fails once the
/// channel closes. Params, results and events stay raw JSON text, as in Kotlin's `RailgunChannel`; nothing here logs
/// them.
@MainActor
final class RailgunChannel {
  /// Hands a request to the page; `failed` is called if the page never took it.
  typealias Deliver = @MainActor (_ request: String, _ failed: @escaping @MainActor @Sendable () -> Void) -> Void

  private struct Pending {
    let continuation: CheckedContinuation<String, Error>
    let deadline: Task<Void, Never>
  }

  private let deliver: Deliver
  private let onEvent: @MainActor (_ name: String, _ rawJSON: String) -> Void
  private let timeout: (RailgunMethod) -> TimeInterval
  private var lastID: Int64 = 0
  private var pending: [Int64: Pending] = [:]
  private var ready = false
  private var readyWaiter: CheckedContinuation<Void, Error>?
  private var readyDeadline: Task<Void, Never>?
  private(set) var closedBy: RailgunError?

  init(
    deliver: @escaping Deliver,
    onEvent: @escaping @MainActor (_ name: String, _ rawJSON: String) -> Void,
    timeout: @escaping (RailgunMethod) -> TimeInterval = { $0.timeout }
  ) {
    self.deliver = deliver
    self.onEvent = onEvent
    self.timeout = timeout
  }

  var isOpen: Bool { closedBy == nil }
  var isReady: Bool { ready }
  var hasPendingCalls: Bool { !pending.isEmpty }

  /// Waits for the page's hello; only this channel's own page can carry it.
  func awaitReady(timeout: TimeInterval) async throws {
    if ready { return }
    if let closedBy { throw RailgunError.disconnected(closedBy.message) }
    if readyWaiter != nil { throw RailgunError.protocol("the page is already loading") }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      readyWaiter = continuation
      readyDeadline = Task { [weak self] in
        try? await Task.sleep(nanoseconds: Self.nanoseconds(timeout))
        guard !Task.isCancelled else { return }
        self?.settleReady(.failure(RailgunError.timeout("loading the page")))
      }
    }
  }

  func call(_ method: RailgunMethod, paramsJSON: String) async throws -> String {
    if let closedBy { throw RailgunError.disconnected(closedBy.message) }
    lastID += 1
    let id = lastID
    let request = try RailgunProtocol.request(id: id, method: method, paramsJSON: paramsJSON)
    let seconds = timeout(method)
    return try await withCheckedThrowingContinuation { continuation in
      let deadline = Task { [weak self] in
        try? await Task.sleep(nanoseconds: Self.nanoseconds(seconds))
        guard !Task.isCancelled else { return }
        self?.settle(id, .failure(.timeout(method.rawValue)))
      }
      pending[id] = Pending(continuation: continuation, deadline: deadline)
      deliver(request) { [weak self] in
        self?.settle(id, .failure(.disconnected("the page did not take the call")))
      }
    }
  }

  /// One message from the page, as it sent it.
  func receive(_ text: String) {
    guard isOpen else { return }
    switch RailgunProtocol.decode(text) {
    case .ready?:
      ready = true
      settleReady(.success(()))
    case let .event(name, rawJSON)?:
      onEvent(name, rawJSON)
    case let .reply(id, resultJSON)?:
      settle(id, .success(resultJSON))
    case let .failure(id, error)?:
      settle(id, .failure(error))
    case nil:
      break
    }
  }

  /// Fails what waits and everything after; the first reason is kept.
  func close(_ reason: RailgunError) {
    if closedBy == nil { closedBy = reason }
    settleReady(.failure(RailgunError.disconnected(reason.message)))
    let calls = pending
    pending.removeAll()
    for call in calls.values {
      call.deadline.cancel()
      call.continuation.resume(throwing: RailgunError.disconnected(reason.message))
    }
  }

  // Whoever removes a call answers it, so it is answered once.
  private func settle(_ id: Int64, _ outcome: Result<String, RailgunError>) {
    guard let call = pending.removeValue(forKey: id) else { return }
    call.deadline.cancel()
    call.continuation.resume(with: outcome.mapError { $0 as Error })
  }

  private func settleReady(_ outcome: Result<Void, Error>) {
    readyDeadline?.cancel()
    readyDeadline = nil
    guard let waiter = readyWaiter else { return }
    readyWaiter = nil
    waiter.resume(with: outcome)
  }

  private nonisolated static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
    UInt64(max(0, seconds) * 1_000_000_000)
  }
}

/// One hidden page: a `WKWebView` of its own, configured once before it exists (WebKit copies the configuration),
/// loading the bundle over the custom scheme and talking to the host through `railgunHost` and
/// `__railgunHostDeliver`. It never takes touches, is hidden from accessibility and is inspectable only in a debug
/// build loaded with `debug`.
@MainActor
final class RailgunPage: NSObject, WKNavigationDelegate, WKUIDelegate {
  static let loadTimeout: TimeInterval = 30
  static let messageHandlerName = "railgunHost"
  /// Delivers one message as a `callAsyncJavaScript` argument, never spliced into the script; it returns at once.
  static let deliveryScript = "__railgunHostDeliver(m); return true;"

  private(set) var webView: WKWebView?
  private(set) var isLoaded = false
  private var navigated = false
  private var channel: RailgunChannel!
  private let debug: Bool
  private let onClosed: @MainActor (RailgunPage) -> Void

  /// `store` must already carry the bridge's proxy.
  init(
    store: WKWebsiteDataStore,
    rules: WKContentRuleList,
    debug: Bool,
    onEvent: @escaping @MainActor (String) -> Void,
    onClosed: @escaping @MainActor (RailgunPage) -> Void
  ) {
    self.debug = debug
    self.onClosed = onClosed
    super.init()
    channel = RailgunChannel(
      deliver: { [weak self] request, failed in self?.deliver(request, failed: failed) },
      onEvent: { name, rawJSON in
        // Engine lines can quote anything the engine saw: only a debug page forwards them.
        if debug || name != RailgunProtocol.log { onEvent(rawJSON) }
      }
    )

    let files = RailgunSchemeHandler()
    files.onRefused = { [weak self] in self?.ownFileRefused() }
    let content = WKUserContentController()
    // No WKUserScript: nothing is injected into the page.
    content.add(MessageRelay(self), contentWorld: .page, name: Self.messageHandlerName)
    content.add(rules)

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store
    configuration.setURLSchemeHandler(files, forURLScheme: RailgunSchemeHandler.scheme)
    configuration.userContentController = content
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.allowsInlineMediaPlayback = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.limitsNavigationsToAppBoundDomains = false

    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.isUserInteractionEnabled = false
    webView.accessibilityElementsHidden = true
    webView.isAccessibilityElement = false
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = false
    #if DEBUG
      if #available(iOS 16.4, *) {
        webView.isInspectable = debug
      }
    #endif
    self.webView = webView
  }

  var isOpen: Bool { channel.isOpen }
  var hasPendingCalls: Bool { channel.hasPendingCalls }

  /// Loads the page and waits for its hello. A page that fails to load, or says nothing in time, is closed.
  func load() async throws {
    guard let webView, channel.isOpen else {
      throw RailgunError.disconnected(channel.closedBy?.message ?? "closed")
    }
    webView.load(URLRequest(url: RailgunSchemeHandler.pageURL))
    do {
      try await channel.awaitReady(timeout: Self.loadTimeout)
      isLoaded = true
    } catch {
      close(.disconnected("the page did not load"))
      throw error
    }
  }

  /// A call that times out closes the page, as on Android: the engine may be stuck.
  func call(_ method: RailgunMethod, paramsJSON: String) async throws -> String {
    do {
      return try await channel.call(method, paramsJSON: paramsJSON)
    } catch let error as RailgunError {
      if case .timeout = error { close(error) }
      throw error
    }
  }

  /// Fails every call still waiting and takes the web view down. Idempotent.
  func close(_ reason: RailgunError) {
    guard channel.isOpen else { return }
    channel.close(reason)
    if let webView {
      webView.stopLoading()
      webView.navigationDelegate = nil
      webView.uiDelegate = nil
      webView.configuration.userContentController.removeAllScriptMessageHandlers()
      webView.configuration.userContentController.removeAllContentRuleLists()
      webView.removeFromSuperview()
    }
    webView = nil
    onClosed(self)
  }

  private func deliver(_ request: String, failed: @escaping @MainActor @Sendable () -> Void) {
    guard let webView, isLoaded else {
      failed()
      return
    }
    webView.callAsyncJavaScript(Self.deliveryScript, arguments: ["m": request], in: nil, in: .page) { result in
      if case .failure = result { failed() }
    }
  }

  /// Only the page's own main frame, in the page world, on the page's origin talks to the host.
  fileprivate func receive(_ message: WKScriptMessage) {
    guard
      let webView,
      message.webView === webView,
      message.frameInfo.isMainFrame,
      message.world == WKContentWorld.page,
      message.frameInfo.securityOrigin.protocol == RailgunSchemeHandler.scheme,
      message.frameInfo.securityOrigin.host == RailgunSchemeHandler.host,
      let text = message.body as? String
    else {
      return
    }
    channel.receive(text)
  }

  // Without its own files the page never answers, so don't wait out the load for it.
  private func ownFileRefused() {
    if !isLoaded { close(.disconnected("one of the page's files did not load")) }
  }

  // MARK: WKNavigationDelegate

  /// Only the page's own first load; nothing navigates it after that.
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    let isFirstLoad =
      !navigated
      && navigationAction.targetFrame?.isMainFrame == true
      && navigationAction.request.url == RailgunSchemeHandler.pageURL
    if isFirstLoad { navigated = true }
    decisionHandler(isFirstLoad ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    if !isLoaded { close(.disconnected("the page did not load")) }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    if !isLoaded { close(.disconnected("the page did not load")) }
  }

  /// The content process died (Android's `onRenderProcessGone`): the page is gone, and Dart reopens it lazily.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    close(.disconnected("the page's content process stopped"))
  }

  // MARK: WKUIDelegate

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    nil
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor () -> Void
  ) {
    completionHandler()
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor (Bool) -> Void
  ) {
    completionHandler(false)
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor (String?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// The content controller keeps its handlers strongly; this one holds the page weakly, so a closed page goes.
@MainActor
private final class MessageRelay: NSObject, WKScriptMessageHandler {
  private weak var page: RailgunPage?

  init(_ page: RailgunPage) {
    self.page = page
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    page?.receive(message)
  }
}
