#ifndef RUNNER_RAILGUN_RAILGUN_PAGE_HOST_H_
#define RUNNER_RAILGUN_RAILGUN_PAGE_HOST_H_

#include <windows.h>

#include <wrl.h>

#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#pragma warning(push, 0)
#include "WebView2.h"
#pragma warning(pop)

#include "railgun/railgun_page.h"

namespace railgun_windows {

// The process-wide Railgun page on Windows, as the Mac's `RailgunPageHost`: one page at a time, in a WebView2
// environment of its own whose every connection goes through the Rust bridge's loopback SOCKS5 port, so the page
// follows the wallet's route. Free of Flutter (railgun_host_channels.h binds it to Dart's channels), so the check
// program (tests/railgun_page) drives it as Dart does. UI thread only.
//
// - A new bridge is a new browser (checklist H13, H17). The proxy is the environment's (`--proxy-server`), set before
//   the browser process starts, with no direct route: every load makes a new environment on the bridge it is given,
//   after the last page's browser process has exited, so no pooled socket outlives a route.
// - Hostnames, never addresses (H14): Chromium hands a SOCKS5 proxy the name unresolved, and every name that would be
//   looked up locally resolves to nothing (`--host-resolver-rules`), so nothing reaches the local resolver.
// - One store, fixed, wiped whole (H9): the environment's user data folder, in the app's local data (out of roaming
//   profiles and File History), beside the wallet's support directory. Chromium lets an origin keep about 60% of the
//   disk, as on Android, whose WebView it is.
// - Never closed for memory (H11): only Dart closes the page, and a call that timed out or a renderer that died.
class RailgunPageHost {
 public:
  using Done = RailgunPage::Done;

  struct Paths {
    // The bundle's folder.
    std::wstring bundle_dir;
    // The page's store: WebView2's user data folder.
    std::wstring user_data_folder;
  };

  static RailgunPageHost& Get();

  RailgunPageHost(const RailgunPageHost&) = delete;
  RailgunPageHost& operator=(const RailgunPageHost&) = delete;

  // Where pages go (the app's window) and the view that keeps the keyboard. Set when the app's channels are registered.
  void Attach(HWND parent, HWND focus_owner);
  void SetPaths(Paths paths);
  const Paths& paths() const { return paths_; }
  // The check program's alone (RailgunPage::Config::refused_host).
  void SetRefusedHostForCheck(std::string host) { refused_host_ = std::move(host); }

  // Whether the page can run here: the system's Evergreen WebView2 Runtime, new enough. Without it Shielded USD stays
  // hidden.
  static bool IsSupported();

  // Loads a fresh page, closing the one before it, with every connection through the bridge at `bridge_port`;
  // `done` is called once, when the page says it is ready, or with why it won't.
  void Load(int bridge_port, bool debug, Done done);

  void Call(const Method& method, const std::string& params_json, RailgunChannel::Reply reply);

  // Closes the page, if any; a load still waiting gives up. Idempotent.
  void Close();

  // Closes the page, then deletes its store, every account's wallet with it.
  void Wipe(Done done);

  // A loaded page that is still open.
  bool IsOpen() const;

  // Where events go; with nobody listening they wait, 256 at most, the oldest going first.
  void SetEventSink(std::function<void(const std::string& raw_json)> sink);

  // The page is shown while Veylor's window shows (not minimised or hidden) and the session is not away; hidden, it is
  // throttled, as WebKit suspends the Mac's.
  void SetWindowShown(bool shown);
  void SetSessionAway(bool away);

  // The current page, for the check program.
  RailgunPage* page() const { return page_.get(); }

 private:
  RailgunPageHost();

  void ClosePage(const Error& reason);
  void Forget(RailgunPage* closed);
  void Emit(const std::string& raw_json);
  bool Visible() const { return window_shown_ && !session_away_; }

  // Makes an environment on `bridge_port`, trying again while the last browser process still holds the store.
  void MakeEnvironment(int bridge_port, uint64_t loading, int attempt,
                       std::function<void(HRESULT, Microsoft::WRL::ComPtr<ICoreWebView2Environment>)> made);
  // Waits for the browser process of `environment`, whose pages are closing, to exit.
  void Retire(Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment);
  void Exited(uint64_t id);
  // Runs `then` once every retired browser process has exited, or after a while regardless.
  void WhenBrowsersExited(std::function<void()> then);
  void RunExitWaiters();
  void RemoveStore(int attempt, Done done);

  HWND parent_ = nullptr;
  HWND focus_owner_ = nullptr;
  Paths paths_;
  std::string refused_host_;
  std::unique_ptr<RailgunPage> page_;
  // Closed pages, deleted once their own call stack has unwound.
  std::vector<std::unique_ptr<RailgunPage>> closed_pages_;
  Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment_;
  // Bumped by every close and load; a load from an older one gives up.
  uint64_t generation_ = 0;

  struct Retired {
    Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment;
    EventRegistrationToken token = {};
  };
  std::map<uint64_t, Retired> retired_;
  uint64_t next_retired_ = 0;
  std::vector<std::function<void()>> exit_waiters_;
  UINT_PTR exit_timer_ = 0;

  std::function<void(const std::string&)> sink_;
  std::deque<std::string> buffered_;
  bool window_shown_ = true;
  bool session_away_ = false;
};

}  // namespace railgun_windows

#endif  // RUNNER_RAILGUN_RAILGUN_PAGE_HOST_H_
