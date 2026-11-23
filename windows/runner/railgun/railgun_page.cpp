#include "railgun/railgun_page.h"

#include <shlwapi.h>

#include <utility>

#include "private_usd/railgun_json.h"
#include "railgun/railgun_dispatch.h"
#include "railgun/railgun_requests.h"
#include "railgun/railgun_text.h"
#include "railgun_page/railgun_endpoints.h"

namespace railgun_windows {
namespace {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

constexpr unsigned kLoadTimeoutMs = 30 * 1000;
constexpr wchar_t kWindowClass[] = L"VeylorRailgunPage";

// Hands the page a MessagePort as Android's host does (`handshake` in RailgunWebViewHost.kt): `index.js` takes the
// first port it is handed in a `message` event with no source window, once it loads. WebView2 can't hand a page a
// port, so this keeps one end of a channel of its own and relays it to and from `chrome.webview`, WebView2's message
// API, whose messages only the page's own main frame posts. It runs before the page's scripts, in its world, and the
// page itself is unchanged. `vizor-railgun-init` is Android's `RailgunProtocol.INIT`, which a Rust test
// (`railgun_bridge.rs`) holds this to.
constexpr wchar_t kTransport[] = LR"JS((() => {
  'use strict';
  if (window !== window.top) return;
  const webview = window.chrome && window.chrome.webview;
  if (!webview) return;
  const channel = new MessageChannel();
  const host = channel.port1;
  host.onmessage = (event) => {
    if (typeof event.data === 'string') webview.postMessage(event.data);
  };
  webview.addEventListener('message', (event) => {
    if (typeof event.data === 'string') host.postMessage(event.data);
  });
  window.addEventListener('load', () => {
    window.dispatchEvent(new MessageEvent('message', { data: 'vizor-railgun-init', ports: [channel.port2] }));
  }, { once: true });
})();)JS";

void RegisterWindowClass() {
  static const bool registered = []() {
    WNDCLASSEXW window_class = {};
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = ::DefWindowProcW;
    window_class.hInstance = ::GetModuleHandleW(nullptr);
    window_class.lpszClassName = kWindowClass;
    return ::RegisterClassExW(&window_class) != 0;
  }();
  (void)registered;
}

// The page's 1x1 window, beneath its siblings (in the app, the Flutter view, which covers it) and disabled, so neither
// the pointer nor the keyboard reaches it.
HWND MakePageWindow(HWND parent) {
  if (parent == nullptr) return nullptr;
  RegisterWindowClass();
  HWND window = ::CreateWindowExW(0, kWindowClass, L"", WS_CHILD | WS_VISIBLE | WS_DISABLED | WS_CLIPSIBLINGS, 0, 0,
                                  1, 1, parent, nullptr, ::GetModuleHandleW(nullptr), nullptr);
  if (window != nullptr) {
    ::SetWindowPos(window, HWND_BOTTOM, 0, 0, 1, 1, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);
  }
  return window;
}

}  // namespace

RailgunPage::RailgunPage(Config config, ComPtr<ICoreWebView2Environment> environment, OnEvent on_event,
                         OnClosed on_closed)
    : config_(std::move(config)),
      environment_(std::move(environment)),
      on_event_(std::move(on_event)),
      on_closed_(std::move(on_closed)),
      channel_([this](const std::string& request) { return Deliver(request); },
               [this](const std::string& name, const std::string& raw_json) {
                 // Engine lines can quote anything the engine saw: only a debug page forwards them.
                 if ((config_.debug || name != railgun_protocol::kLogEvent) && on_event_) on_event_(raw_json);
               }),
      archive_(config_.bridge_port),
      visible_(config_.visible) {}

RailgunPage::~RailgunPage() {
  on_closed_ = nullptr;
  Close(Error::Disconnected("closed"));
}

void RailgunPage::Load(Done done) {
  load_done_ = std::move(done);
  channel_.AwaitReady(kLoadTimeoutMs, [this](const Error* error) { FinishLoad(error); });
  if (closed_) return;
  window_ = MakePageWindow(config_.parent);
  if (window_ == nullptr || !environment_) {
    Fail(Error::Unavailable("the page's window could not be made"));
    return;
  }
  std::weak_ptr<int> alive = alive_;
  const HRESULT result = environment_->CreateCoreWebView2Controller(
      window_, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                   [this, alive](HRESULT created, ICoreWebView2Controller* controller) -> HRESULT {
                     if (alive.expired()) {
                       if (controller != nullptr) controller->Close();
                       return S_OK;
                     }
                     OnController(created, controller);
                     return S_OK;
                   })
                   .Get());
  if (FAILED(result)) Fail(Error::Unavailable("the WebView2 page could not start"));
}

void RailgunPage::FinishLoad(const Error* error) {
  if (error == nullptr) {
    loaded_ = true;
  } else {
    // The reason the load failed goes to Dart; the page closes as not loaded.
    const Error reason = *error;
    if (!closed_) Close(Error::Disconnected("the page did not load"));
    if (load_done_) {
      Done done = std::move(load_done_);
      load_done_ = nullptr;
      done(&reason);
    }
    return;
  }
  if (load_done_) {
    Done done = std::move(load_done_);
    load_done_ = nullptr;
    done(nullptr);
  }
}

void RailgunPage::OnController(HRESULT result, ICoreWebView2Controller* controller) {
  if (closed_) {
    if (controller != nullptr) controller->Close();
    return;
  }
  if (FAILED(result) || controller == nullptr) {
    FailLater(Error::Unavailable("the WebView2 page could not start"));
    return;
  }
  controller_ = controller;
  had_webview_ = true;
  if (FAILED(controller_->get_CoreWebView2(&webview_)) || !webview_ || !Configure()) {
    FailLater(Error::Unavailable("the WebView2 page could not start"));
  }
}

bool RailgunPage::Configure() {
  ComPtr<ICoreWebView2Settings> settings;
  if (FAILED(webview_->get_Settings(&settings)) || !settings) return false;
  settings->put_IsScriptEnabled(TRUE);
  settings->put_IsWebMessageEnabled(TRUE);
  settings->put_AreDefaultScriptDialogsEnabled(FALSE);
  settings->put_IsStatusBarEnabled(FALSE);
  settings->put_AreDevToolsEnabled(config_.debug ? TRUE : FALSE);
  settings->put_AreDefaultContextMenusEnabled(FALSE);
  settings->put_AreHostObjectsAllowed(FALSE);
  settings->put_IsZoomControlEnabled(FALSE);
  settings->put_IsBuiltInErrorPageEnabled(FALSE);
  // WebView2's own User-Agent names the runtime's version; a page without the fixed one never loads (H18).
  ComPtr<ICoreWebView2Settings2> settings2;
  if (FAILED(settings.As(&settings2)) || FAILED(settings2->put_UserAgent(Utf16(kUserAgent).c_str()))) return false;
  ComPtr<ICoreWebView2Settings3> settings3;
  if (SUCCEEDED(settings.As(&settings3))) settings3->put_AreBrowserAcceleratorKeysEnabled(FALSE);
  ComPtr<ICoreWebView2Settings4> settings4;
  if (SUCCEEDED(settings.As(&settings4))) {
    settings4->put_IsPasswordAutosaveEnabled(FALSE);
    settings4->put_IsGeneralAutofillEnabled(FALSE);
  }
  ComPtr<ICoreWebView2Settings5> settings5;
  if (SUCCEEDED(settings.As(&settings5))) settings5->put_IsPinchZoomEnabled(FALSE);
  ComPtr<ICoreWebView2Settings6> settings6;
  if (SUCCEEDED(settings.As(&settings6))) settings6->put_IsSwipeNavigationEnabled(FALSE);
  // SmartScreen would send Microsoft the page's URLs.
  ComPtr<ICoreWebView2Settings8> settings8;
  if (SUCCEEDED(settings.As(&settings8))) settings8->put_IsReputationCheckingRequired(FALSE);

  std::weak_ptr<int> alive = alive_;
  EventRegistrationToken token;

  webview_->add_NavigationStarting(
      Callback<ICoreWebView2NavigationStartingEventHandler>(
          [this, alive](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
            if (alive.expired()) return S_OK;
            CoString uri;
            args->get_Uri(uri.put());
            // Only the page's own first load; nothing navigates it after that.
            if (!navigated_ && uri.view() == kPageUrl) {
              navigated_ = true;
            } else {
              args->put_Cancel(TRUE);
            }
            return S_OK;
          })
          .Get(),
      &token);
  webview_->add_FrameNavigationStarting(
      Callback<ICoreWebView2NavigationStartingEventHandler>(
          [](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
            args->put_Cancel(TRUE);
            return S_OK;
          })
          .Get(),
      &token);
  webview_->add_NavigationCompleted(
      Callback<ICoreWebView2NavigationCompletedEventHandler>(
          [this, alive](ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
            if (alive.expired()) return S_OK;
            BOOL success = FALSE;
            args->get_IsSuccess(&success);
            // Without its own file the page never answers, so don't wait out the load for it.
            if (!success && !loaded_) FailLater(Error::Disconnected("the page did not load"));
            return S_OK;
          })
          .Get(),
      &token);
  webview_->add_WebMessageReceived(
      Callback<ICoreWebView2WebMessageReceivedEventHandler>(
          [this, alive](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
            if (alive.expired() || closed_) return S_OK;
            // Only the page's own document posts here (frames have their own event); it must still be the page.
            CoString source;
            if (FAILED(args->get_Source(source.put())) || source.view() != kPageUrl) return S_OK;
            CoString message;
            if (FAILED(args->TryGetWebMessageAsString(message.put()))) return S_OK;
            channel_.Receive(Utf8(message.view()));
            return S_OK;
          })
          .Get(),
      &token);
  webview_->add_WebResourceRequested(
      Callback<ICoreWebView2WebResourceRequestedEventHandler>(
          [this, alive](ICoreWebView2*, ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT {
            if (alive.expired() || closed_) return S_OK;
            OnResourceRequested(args);
            return S_OK;
          })
          .Get(),
      &token);
  webview_->add_NewWindowRequested(Callback<ICoreWebView2NewWindowRequestedEventHandler>(
                                       [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
                                         args->put_Handled(TRUE);
                                         return S_OK;
                                       })
                                       .Get(),
                                   &token);
  webview_->add_PermissionRequested(
      Callback<ICoreWebView2PermissionRequestedEventHandler>(
          [](ICoreWebView2*, ICoreWebView2PermissionRequestedEventArgs* args) -> HRESULT {
            args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
            return S_OK;
          })
          .Get(),
      &token);
  webview_->add_ProcessFailed(
      Callback<ICoreWebView2ProcessFailedEventHandler>(
          [this, alive](ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs* args) -> HRESULT {
            if (alive.expired()) return S_OK;
            COREWEBVIEW2_PROCESS_FAILED_KIND kind = COREWEBVIEW2_PROCESS_FAILED_KIND_UNKNOWN_PROCESS_EXITED;
            args->get_ProcessFailedKind(&kind);
            // Android's `onRenderProcessGone`, the Mac's content process: the page is gone, and Dart reopens it.
            // Other processes (the GPU's, a utility's) come back by themselves.
            if (kind == COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED ||
                kind == COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED) {
              FailLater(Error::Disconnected("the page's renderer stopped"));
            }
            return S_OK;
          })
          .Get(),
      &token);
  ComPtr<ICoreWebView2_4> webview4;
  if (SUCCEEDED(webview_.As(&webview4))) {
    webview4->add_DownloadStarting(
        Callback<ICoreWebView2DownloadStartingEventHandler>(
            [](ICoreWebView2*, ICoreWebView2DownloadStartingEventArgs* args) -> HRESULT {
              args->put_Cancel(TRUE);
              return S_OK;
            })
            .Get(),
        &token);
  }
  ComPtr<ICoreWebView2_5> webview5;
  if (SUCCEEDED(webview_.As(&webview5))) {
    webview5->add_ClientCertificateRequested(
        Callback<ICoreWebView2ClientCertificateRequestedEventHandler>(
            [](ICoreWebView2*, ICoreWebView2ClientCertificateRequestedEventArgs* args) -> HRESULT {
              args->put_Cancel(TRUE);
              return S_OK;
            })
            .Get(),
        &token);
  }
  ComPtr<ICoreWebView2_10> webview10;
  if (SUCCEEDED(webview_.As(&webview10))) {
    webview10->add_BasicAuthenticationRequested(
        Callback<ICoreWebView2BasicAuthenticationRequestedEventHandler>(
            [](ICoreWebView2*, ICoreWebView2BasicAuthenticationRequestedEventArgs* args) -> HRESULT {
              args->put_Cancel(TRUE);
              return S_OK;
            })
            .Get(),
        &token);
  }
  ComPtr<ICoreWebView2_11> webview11;
  if (SUCCEEDED(webview_.As(&webview11))) {
    webview11->add_ContextMenuRequested(
        Callback<ICoreWebView2ContextMenuRequestedEventHandler>(
            [](ICoreWebView2*, ICoreWebView2ContextMenuRequestedEventArgs* args) -> HRESULT {
              args->put_Handled(TRUE);
              return S_OK;
            })
            .Get(),
        &token);
  }
  ComPtr<ICoreWebView2_18> webview18;
  if (SUCCEEDED(webview_.As(&webview18))) {
    webview18->add_LaunchingExternalUriScheme(
        Callback<ICoreWebView2LaunchingExternalUriSchemeEventHandler>(
            [](ICoreWebView2*, ICoreWebView2LaunchingExternalUriSchemeEventArgs* args) -> HRESULT {
              args->put_Cancel(TRUE);
              return S_OK;
            })
            .Get(),
        &token);
  }

  // Every request, the page's workers' included.
  HRESULT filtered = E_NOINTERFACE;
  ComPtr<ICoreWebView2_22> webview22;
  if (SUCCEEDED(webview_.As(&webview22))) {
    filtered = webview22->AddWebResourceRequestedFilterWithRequestSourceKinds(
        L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL, COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_ALL);
  }
  if (FAILED(filtered)) filtered = webview_->AddWebResourceRequestedFilter(L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
  if (FAILED(filtered)) return false;

  controller_->add_GotFocus(Callback<ICoreWebView2FocusChangedEventHandler>(
                                [this, alive](ICoreWebView2Controller*, IUnknown*) -> HRESULT {
                                  if (alive.expired() || config_.focus_owner == nullptr) return S_OK;
                                  HWND owner = config_.focus_owner;
                                  Dispatch::Get().Post([owner]() { ::SetFocus(owner); });
                                  return S_OK;
                                })
                                .Get(),
                            &token);
  controller_->add_MoveFocusRequested(
      Callback<ICoreWebView2MoveFocusRequestedEventHandler>(
          [](ICoreWebView2Controller*, ICoreWebView2MoveFocusRequestedEventArgs* args) -> HRESULT {
            args->put_Handled(TRUE);
            return S_OK;
          })
          .Get(),
      &token);
  ComPtr<ICoreWebView2Controller2> controller2;
  if (SUCCEEDED(controller_.As(&controller2))) {
    COREWEBVIEW2_COLOR clear = {0, 0, 0, 0};
    controller2->put_DefaultBackgroundColor(clear);
  }
  RECT bounds = {0, 0, 1, 1};
  controller_->put_Bounds(bounds);
  controller_->put_IsVisible(visible_ ? TRUE : FALSE);

  // The transport goes in before the page loads, and so does the User-Agent's override.
  const HRESULT added = webview_->AddScriptToExecuteOnDocumentCreated(
      kTransport, Callback<ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler>(
                      [this, alive](HRESULT result, LPCWSTR) -> HRESULT {
                        if (alive.expired() || closed_) return S_OK;
                        if (FAILED(result)) {
                          FailLater(Error::Unavailable("the WebView2 page could not start"));
                        } else {
                          OverrideUserAgent();
                        }
                        return S_OK;
                      })
                      .Get());
  return SUCCEEDED(added);
}

// WebView2's `put_UserAgent` fixes the string but keeps the User-Agent client hints (`Sec-CH-UA*` and
// `navigator.userAgentData`), which name the platform and the runtime's version beside it. DevTools' override of the
// string alone, with no metadata, turns them off, as Android's WebView turns them off for a page whose User-Agent its
// host set. A runtime that refuses DevTools (a policy) keeps the fixed string and its hints.
void RailgunPage::OverrideUserAgent() {
  std::weak_ptr<int> alive = alive_;
  const std::wstring params = L"{\"userAgent\":\"" + Utf16(kUserAgent) + L"\"}";
  const HRESULT result = webview_->CallDevToolsProtocolMethod(
      L"Emulation.setUserAgentOverride", params.c_str(),
      Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>([this, alive](HRESULT, LPCWSTR) -> HRESULT {
        if (!alive.expired() && !closed_) Navigate();
        return S_OK;
      }).Get());
  if (FAILED(result)) Navigate();
}

void RailgunPage::Navigate() {
  if (!webview_ || FAILED(webview_->Navigate(kPageUrl))) FailLater(Error::Disconnected("the page did not load"));
}

bool RailgunPage::Deliver(const std::string& request) {
  if (closed_ || !loaded_ || !webview_) return false;
  const std::wstring message = Utf16(request);
  if (message.empty()) return false;
  return SUCCEEDED(webview_->PostWebMessageAsString(message.c_str()));
}

void RailgunPage::Call(const Method& method, const std::string& params_json, RailgunChannel::Reply reply) {
  std::weak_ptr<int> alive = alive_;
  channel_.Call(method, params_json, [this, alive, answer = std::move(reply)](const Error* error,
                                                                               const std::string& result_json) {
    // A call that timed out closes the page: the engine may be stuck.
    if (error != nullptr && error->kind == Error::Kind::kTimeout && !alive.expired()) Close(*error);
    answer(error, result_json);
  });
}

void RailgunPage::OnResourceRequested(ICoreWebView2WebResourceRequestedEventArgs* args) {
  ComPtr<ICoreWebView2WebResourceRequest> request;
  if (FAILED(args->get_Request(&request)) || !request) {
    Refuse(args, 403);
    return;
  }
  CoString uri;
  CoString method;
  request->get_Uri(uri.put());
  request->get_Method(method.put());
  ParsedUrl url;
  if (!ParseUrl(Utf8(uri.view()), &url)) {
    Refuse(args, 403);
    return;
  }
  Route route = RouteOf(url, Utf8(method.view()));
  if (route == Route::kAllowed && !config_.refused_host.empty() && url.host == config_.refused_host) {
    route = Route::kBlocked;
  }
  switch (route) {
    case Route::kOwnFile:
      ServeOwnFile(args, url.path, std::wstring(method.view()));
      break;
    case Route::kArchive:
      archive_.Start(environment_.Get(), args, url.path_and_query);
      break;
    case Route::kAllowed:
      // Out through the bridge, the environment's only proxy.
      break;
    case Route::kBlocked:
      Refuse(args, 403);
      break;
  }
}

void RailgunPage::ServeOwnFile(ICoreWebView2WebResourceRequestedEventArgs* args, const std::string& path,
                               const std::wstring& method) {
  if (method != L"GET") {
    Refuse(args, 405);
    return;
  }
  std::wstring type;
  const std::wstring file = OwnFile(config_.bundle_dir, path, &type);
  ComPtr<IStream> stream;
  WIN32_FILE_ATTRIBUTE_DATA info = {};
  if (file.empty() ||
      FAILED(::SHCreateStreamOnFileEx(file.c_str(), STGM_READ | STGM_SHARE_DENY_WRITE, FILE_ATTRIBUTE_NORMAL, FALSE,
                                      nullptr, &stream)) ||
      !::GetFileAttributesExW(file.c_str(), GetFileExInfoStandard, &info)) {
    Refuse(args, 404);
    // One of the page's own files (a type it loads) missing: the page never answers, so don't wait out the load. A
    // request the browser makes by itself (a favicon) is only refused.
    if (!type.empty() && !loaded_) FailLater(Error::Disconnected("one of the page's files did not load"));
    return;
  }
  const ULONGLONG size = (static_cast<ULONGLONG>(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
  const std::wstring headers = L"Content-Type: " + type + L"\r\nContent-Length: " + std::to_wstring(size) +
                               L"\r\nContent-Security-Policy: " + Utf16(railgun_page::ContentSecurityPolicy()) +
                               L"\r\nCache-Control: no-store";
  ComPtr<ICoreWebView2WebResourceResponse> response;
  if (SUCCEEDED(environment_->CreateWebResourceResponse(stream.Get(), 200, L"OK", headers.c_str(), &response))) {
    args->put_Response(response.Get());
  }
}

void RailgunPage::Refuse(ICoreWebView2WebResourceRequestedEventArgs* args, int status) {
  ComPtr<IStream> stream;
  stream.Attach(::SHCreateMemStream(nullptr, 0));
  ComPtr<ICoreWebView2WebResourceResponse> response;
  if (SUCCEEDED(environment_->CreateWebResourceResponse(stream.Get(), status, L"Refused",
                                                        L"Content-Type: text/plain\r\nCache-Control: no-store",
                                                        &response))) {
    args->put_Response(response.Get());
  }
}

void RailgunPage::Fail(const Error& reason) {
  // A page still loading answers its load with why; a loaded one closes.
  if (!loaded_) {
    FinishLoad(&reason);
  } else {
    Close(reason);
  }
}

void RailgunPage::FailLater(const Error& reason) {
  std::weak_ptr<int> alive = alive_;
  Dispatch::Get().Post([this, alive, reason]() {
    if (!alive.expired()) Fail(reason);
  });
}

void RailgunPage::Close(const Error& reason) {
  if (closed_) return;
  closed_ = true;
  // Every callback still on its way now finds the page gone.
  alive_.reset();
  channel_.Close(reason);
  archive_.Close();
  if (controller_) controller_->Close();
  webview_.Reset();
  controller_.Reset();
  if (window_ != nullptr) {
    ::DestroyWindow(window_);
    window_ = nullptr;
  }
  if (on_closed_) {
    OnClosed closed = std::move(on_closed_);
    on_closed_ = nullptr;
    closed(this);
  }
}

void RailgunPage::SetVisible(bool visible) {
  visible_ = visible;
  if (controller_) controller_->put_IsVisible(visible ? TRUE : FALSE);
}

void RailgunPage::Evaluate(const std::wstring& script, std::function<void(bool ok, const std::string& json)> done) {
  if (!webview_ || closed_) {
    done(false, std::string());
    return;
  }
  // DevTools' evaluation waits for a promise, which `ExecuteScript` doesn't.
  const std::string params = "{\"expression\":" + railgun_json::Quote(Utf8(script)) +
                             ",\"awaitPromise\":true,\"returnByValue\":true}";
  std::weak_ptr<int> alive = alive_;
  const HRESULT result = webview_->CallDevToolsProtocolMethod(
      L"Runtime.evaluate", Utf16(params).c_str(),
      Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
          [alive, done](HRESULT answered, LPCWSTR json) -> HRESULT {
            if (alive.expired()) return S_OK;
            done(SUCCEEDED(answered), json == nullptr ? std::string() : Utf8(json));
            return S_OK;
          })
          .Get());
  if (FAILED(result)) done(false, std::string());
}

}  // namespace railgun_windows
