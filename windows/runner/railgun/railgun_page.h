#ifndef RUNNER_RAILGUN_RAILGUN_PAGE_H_
#define RUNNER_RAILGUN_RAILGUN_PAGE_H_

#include <windows.h>

#include <wrl.h>

#include <functional>
#include <memory>
#include <string>

#pragma warning(push, 0)
#include "WebView2.h"
#pragma warning(pop)

#include "railgun/railgun_archive.h"
#include "railgun/railgun_channel.h"

namespace railgun_windows {

// One hidden Railgun page in WebView2, as the Mac's `RailgunPage` is in WebKit: a controller of its own in an
// environment whose every connection goes through the Rust bridge (railgun_page_host.h makes it), loading the bundle
// from `veylor-railgun://app/` and talking to the host over the page's own transport. Free of Flutter, so the check
// program (tests/railgun_page) runs it as the app does.
//
// - The transport (checklist H7). The page takes Android's MessagePort when it finds no WebKit host (`index.js`), and
//   WebView2 can hand a page no port. A script that runs before the page's own, in the page's world, bridges one: it
//   keeps one end of a MessageChannel, relays it to and from `chrome.webview` (WebView2's message API), and once the
//   page has loaded hands the other end over as Android's `postWebMessage` does, in a `message` event with no source
//   window. The page is unchanged; only its own main frame's messages count.
// - The filter (H15). `WebResourceRequested` sees every request: the page's own files are served from the bundle,
//   Anon's archive is answered by the host (railgun_archive.h), the allowlisted hosts go out through the bridge, and
//   anything else gets a 403 (railgun_requests.h).
// - Locked down (H8). Only the first navigation, to the page, goes ahead; no frame navigates, and no window, dialog,
//   download, permission, external scheme, sign-in, client certificate or context menu is allowed. A renderer or browser
//   process that dies closes the page, and Dart reopens it on its next use.
// - Out of sight (H10). The page's 1x1 window sits beneath the window it is given (in the app, under the Flutter view,
//   as the Mac's 1x1 web view sits below its Flutter view), disabled, so it takes no pointer or keyboard; focus that
//   reaches it goes back to `focus_owner`.
class RailgunPage {
 public:
  struct Config {
    // The window the page's own 1x1 window goes in.
    HWND parent = nullptr;
    // Where focus goes back if the page ever takes it: the Flutter view.
    HWND focus_owner = nullptr;
    // The bundle's folder (`data\railgun` beside the executable).
    std::wstring bundle_dir;
    // The bridge the environment's proxy names, which the archive's requests go through too.
    int bridge_port = 0;
    // DevTools and the page's `log` events; only a debug build passes it.
    bool debug = false;
    // Whether the page starts shown (Veylor's window showing, the session not away).
    bool visible = true;
    // The check program's alone (tests/railgun_page): one allowlisted host the filter refuses too, to show it refusing
    // what the page's CSP lets through (checklist H15). Empty in the app.
    std::string refused_host;
  };
  using OnEvent = std::function<void(const std::string& raw_json)>;
  using OnClosed = std::function<void(RailgunPage* page)>;
  using Done = std::function<void(const Error* error)>;

  RailgunPage(Config config, Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment, OnEvent on_event,
              OnClosed on_closed);
  ~RailgunPage();
  RailgunPage(const RailgunPage&) = delete;
  RailgunPage& operator=(const RailgunPage&) = delete;

  // Makes the page's controller and loads the page; `done` is called once, when it says it is ready (30 s), or with
  // why it won't. A page that fails to load is closed.
  void Load(Done done);

  // One call; one that times out closes the page, as on Android and the Mac: the engine may be stuck.
  void Call(const Method& method, const std::string& params_json, RailgunChannel::Reply reply);

  // Fails every call still waiting and takes the page down. Idempotent. Never call it from inside one of WebView2's
  // callbacks (post it): the controller closes here.
  void Close(const Error& reason);

  bool IsOpen() const { return channel_.IsOpen(); }
  bool IsLoaded() const { return loaded_; }
  // Whether a controller was ever made: only then is there a browser process to wait out after the close.
  bool HadWebView() const { return had_webview_; }

  // Shown while Veylor's window shows and the session is not away; hidden, WebView2 throttles the page, as WebKit
  // suspends the Mac's.
  void SetVisible(bool visible);

  // The check program's (tests/railgun_page): runs `script` in the page and hands back its result as JSON. Nothing Dart
  // sends reaches it.
  void Evaluate(const std::wstring& script, std::function<void(bool ok, const std::string& json)> done);
  ICoreWebView2* webview() const { return webview_.Get(); }
  const RailgunArchive& archive() const { return archive_; }

 private:
  void OnController(HRESULT result, ICoreWebView2Controller* controller);
  bool Configure();
  void OverrideUserAgent();
  void Navigate();
  bool Deliver(const std::string& request);
  void OnResourceRequested(ICoreWebView2WebResourceRequestedEventArgs* args);
  void ServeOwnFile(ICoreWebView2WebResourceRequestedEventArgs* args, const std::string& path,
                    const std::wstring& method);
  void Refuse(ICoreWebView2WebResourceRequestedEventArgs* args, int status);
  // Fails the load (which closes the page) or, once loaded, closes it; later, after the current callback returns.
  void Fail(const Error& reason);
  void FailLater(const Error& reason);
  void FinishLoad(const Error* error);

  Config config_;
  Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment_;
  Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller_;
  Microsoft::WRL::ComPtr<ICoreWebView2> webview_;
  HWND window_ = nullptr;
  OnEvent on_event_;
  OnClosed on_closed_;
  RailgunChannel channel_;
  RailgunArchive archive_;
  Done load_done_;
  bool navigated_ = false;
  bool had_webview_ = false;
  bool loaded_ = false;
  bool closed_ = false;
  bool visible_ = true;
  // Callbacks hold it weakly: one that comes after the page went does nothing.
  std::shared_ptr<int> alive_ = std::make_shared<int>(0);
};

}  // namespace railgun_windows

#endif  // RUNNER_RAILGUN_RAILGUN_PAGE_H_
