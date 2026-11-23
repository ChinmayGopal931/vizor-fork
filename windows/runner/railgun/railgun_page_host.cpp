#include "railgun/railgun_page_host.h"

#include <filesystem>
#include <system_error>
#include <utility>

#pragma warning(push, 0)
#include "WebView2EnvironmentOptions.h"
#pragma warning(pop)

#include "railgun/railgun_dispatch.h"
#include "railgun/railgun_network.h"
#include "railgun/railgun_requests.h"

namespace railgun_windows {
namespace {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;

constexpr size_t kEventBuffer = 256;
// The oldest runtime whose APIs the host uses (custom schemes, the proxy, the request filter). The Evergreen runtime
// updates itself, so a computer with any is far past it.
constexpr wchar_t kMinimumRuntime[] = L"120.0.0.0";
// How long a new page waits for the last one's browser process to let go of the store.
constexpr UINT kBrowserExitWaitMs = 20 * 1000;
constexpr int kEnvironmentAttempts = 10;
constexpr UINT kEnvironmentRetryMs = 500;
// Windows (or an antivirus) can hold a file of the store briefly after the browser process exits.
constexpr int kWipeAttempts = 5;
constexpr UINT kWipeRetryMs = 500;

// The browser's arguments: every connection through the bridge, by name, and nothing around it.
// - The bridge is the only proxy, loopback included (`<-loopback>` drops Chromium's implicit direct route to it).
// - Chromium hands a SOCKS5 proxy the hostname unresolved; anything it would look up itself resolves to nothing.
// - No QUIC (it can't go through SOCKS5) and no WebRTC UDP (the page also deletes WebRTC, shims.js).
// - No background services (component updates, domain reliability reports, pings): they would only be refused.
// - No accessibility tree: the page shows nothing, and a screen reader must not find it.
// - No native occlusion: the page's window sits under the Flutter view. (The page's User-Agent client hints go with
//   DevTools' override, railgun_page.cpp: no switch turns them off.)
std::wstring BrowserArguments(int bridge_port) {
  return L"--proxy-server=socks5://127.0.0.1:" + std::to_wstring(bridge_port) +
         L" --proxy-bypass-list=<-loopback>"
         L" --host-resolver-rules=\"MAP * ~NOTFOUND , EXCLUDE 127.0.0.1\""
         L" --disable-quic"
         L" --force-webrtc-ip-handling-policy=disable_non_proxied_udp"
         L" --disable-background-networking"
         L" --disable-component-update"
         L" --disable-domain-reliability"
         L" --no-pings"
         L" --disable-renderer-accessibility"
         L" --disable-features=CalculateNativeWinOcclusion";
}

// The options every environment shares: the stable runtime only.
ComPtr<CoreWebView2EnvironmentOptions> BaseOptions() {
  auto options = Make<CoreWebView2EnvironmentOptions>();
  ComPtr<ICoreWebView2EnvironmentOptions7> options7;
  if (options && SUCCEEDED(options.As(&options7))) options7->put_ReleaseChannels(COREWEBVIEW2_RELEASE_CHANNELS_STABLE);
  return options;
}

// The page's environment on `bridge_port`, or null when the runtime can't take what the page needs.
ComPtr<CoreWebView2EnvironmentOptions> PageOptions(int bridge_port) {
  ComPtr<CoreWebView2EnvironmentOptions> options = BaseOptions();
  if (!options) return nullptr;
  options->put_AdditionalBrowserArguments(BrowserArguments(bridge_port).c_str());
  // One language on every computer: the page sets `en-US,en;q=0.9` on its own requests on every host
  // (accept-language.js), Chromium's header for en-US, so whatever it doesn't set names the same. It has no UI.
  options->put_Language(L"en-US");
  ComPtr<ICoreWebView2EnvironmentOptions2> options2;
  if (SUCCEEDED(options.As(&options2))) options2->put_ExclusiveUserDataFolderAccess(TRUE);
  // A crash's dump stays in the store, never sent to Microsoft: it can hold what the page held.
  ComPtr<ICoreWebView2EnvironmentOptions3> options3;
  if (SUCCEEDED(options.As(&options3))) options3->put_IsCustomCrashReportingEnabled(TRUE);
  ComPtr<ICoreWebView2EnvironmentOptions5> options5;
  if (SUCCEEDED(options.As(&options5))) options5->put_EnableTrackingPrevention(FALSE);
  ComPtr<ICoreWebView2EnvironmentOptions6> options6;
  if (SUCCEEDED(options.As(&options6))) options6->put_AreBrowserExtensionsEnabled(FALSE);
  // The page's own origin, a secure context with an authority, as iOS's, the Mac's and Linux's.
  ComPtr<ICoreWebView2EnvironmentOptions4> options4;
  if (FAILED(options.As(&options4))) return nullptr;
  auto scheme = Make<CoreWebView2CustomSchemeRegistration>(kPageScheme);
  if (!scheme) return nullptr;
  scheme->put_TreatAsSecure(TRUE);
  scheme->put_HasAuthorityComponent(TRUE);
  LPCWSTR origins[] = {kPageOrigin};
  scheme->SetAllowedOrigins(1, origins);
  ICoreWebView2CustomSchemeRegistration* registrations[] = {scheme.Get()};
  if (FAILED(options4->SetCustomSchemeRegistrations(1, registrations))) return nullptr;
  return options;
}

}  // namespace

RailgunPageHost& RailgunPageHost::Get() {
  static RailgunPageHost host;
  return host;
}

RailgunPageHost::RailgunPageHost() {
  // Made here, on the UI thread, before any other thread hands it work.
  Dispatch::Get();
}

void RailgunPageHost::Attach(HWND parent, HWND focus_owner) {
  parent_ = parent;
  focus_owner_ = focus_owner;
}

void RailgunPageHost::SetPaths(Paths paths) { paths_ = std::move(paths); }

std::wstring RailgunPageHost::RuntimeVersion() {
  ComPtr<CoreWebView2EnvironmentOptions> options = BaseOptions();
  LPWSTR version = nullptr;
  if (!options || FAILED(::GetAvailableCoreWebView2BrowserVersionStringWithOptions(nullptr, options.Get(), &version)) ||
      version == nullptr) {
    return std::wstring();
  }
  std::wstring found(version);
  ::CoTaskMemFree(version);
  return found;
}

bool RailgunPageHost::IsSupported() {
  const std::wstring version = RuntimeVersion();
  int comparison = -1;
  return !version.empty() && SUCCEEDED(::CompareBrowserVersions(version.c_str(), kMinimumRuntime, &comparison)) &&
         comparison >= 0;
}

void RailgunPageHost::Load(int bridge_port, bool debug, Done done) {
  ClosePage(Error::Disconnected("a new page replaced it"));
  const uint64_t loading = generation_;
  if (!IsSupported()) {
    const Error error = Error::Unavailable("Shielded USD needs the WebView2 Runtime");
    done(&error);
    return;
  }
  if (parent_ == nullptr || paths_.bundle_dir.empty() || paths_.user_data_folder.empty()) {
    const Error error = Error::Unavailable("the Railgun host is not set up");
    done(&error);
    return;
  }
  // Never a page without its proxy.
  if (!LoopbackAccepts(bridge_port)) {
    const Error error = Error::Unavailable("the bridge is not running");
    done(&error);
    return;
  }
  auto waiting = std::make_shared<Done>(std::move(done));
  WhenBrowsersExited([this, loading, bridge_port, debug, waiting]() {
    if (loading != generation_) {
      const Error error = Error::Disconnected("closed while loading");
      (*waiting)(&error);
      return;
    }
    std::error_code ignored;
    std::filesystem::create_directories(paths_.user_data_folder, ignored);
    MakeEnvironment(
        bridge_port, loading, 1,
        [this, loading, bridge_port, debug, waiting](HRESULT result, ComPtr<ICoreWebView2Environment> environment) {
          if (loading != generation_) {
            // Never used: it lets go of the store once released.
            const Error error = Error::Disconnected("closed while loading");
            (*waiting)(&error);
            return;
          }
          if (FAILED(result) || !environment) {
            const Error error = Error::Unavailable(result == HRESULT_FROM_WIN32(ERROR_INVALID_STATE)
                                                       ? "the last page's WebView2 did not close"
                                                       : "the WebView2 Runtime did not start");
            (*waiting)(&error);
            return;
          }
          environment_ = environment;
          RailgunPage::Config config;
          config.parent = parent_;
          config.focus_owner = focus_owner_;
          config.bundle_dir = paths_.bundle_dir;
          config.bridge_port = bridge_port;
          config.debug = debug;
          config.visible = Visible();
          config.refused_host = refused_host_;
          page_ = std::make_unique<RailgunPage>(
              std::move(config), environment, [this](const std::string& raw_json) { Emit(raw_json); },
              [this](RailgunPage* closed) { Forget(closed); });
          RailgunPage* page = page_.get();
          page->Load([this, loading, page, waiting](const Error* error) {
            Done finished = std::move(*waiting);
            if (error != nullptr) {
              finished(error);
              return;
            }
            if (loading != generation_ || page_.get() != page || !page->IsOpen()) {
              const Error closed = Error::Disconnected("closed while loading");
              finished(&closed);
              return;
            }
            finished(nullptr);
          });
        });
  });
}

void RailgunPageHost::MakeEnvironment(
    int bridge_port, uint64_t loading, int attempt,
    std::function<void(HRESULT, ComPtr<ICoreWebView2Environment>)> made) {
  ComPtr<CoreWebView2EnvironmentOptions> options = PageOptions(bridge_port);
  if (!options) {
    made(E_NOINTERFACE, nullptr);
    return;
  }
  auto shared = std::make_shared<std::function<void(HRESULT, ComPtr<ICoreWebView2Environment>)>>(std::move(made));
  const HRESULT started = ::CreateCoreWebView2EnvironmentWithOptions(
      nullptr, paths_.user_data_folder.c_str(), options.Get(),
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [this, bridge_port, loading, attempt, shared](HRESULT result,
                                                        ICoreWebView2Environment* environment) -> HRESULT {
            ComPtr<ICoreWebView2Environment> made_environment = environment;
            // The last browser process still holds the store with its own arguments: try again shortly.
            if (result == HRESULT_FROM_WIN32(ERROR_INVALID_STATE) && attempt < kEnvironmentAttempts &&
                loading == generation_) {
              Dispatch::Get().After(kEnvironmentRetryMs, [this, bridge_port, loading, attempt, shared]() {
                MakeEnvironment(bridge_port, loading, attempt + 1, std::move(*shared));
              });
              return S_OK;
            }
            (*shared)(result, made_environment);
            return S_OK;
          })
          .Get());
  if (FAILED(started)) (*shared)(started, nullptr);
}

void RailgunPageHost::Call(const Method& method, const std::string& params_json, RailgunChannel::Reply reply) {
  if (!page_ || !page_->IsLoaded() || !page_->IsOpen()) {
    const Error error = Error::Disconnected("no page");
    reply(&error, std::string());
    return;
  }
  page_->Call(method, params_json, std::move(reply));
}

void RailgunPageHost::Close() { ClosePage(Error::Disconnected("closed")); }

void RailgunPageHost::Wipe(Done done) {
  ClosePage(Error::Disconnected("wiped"));
  auto waiting = std::make_shared<Done>(std::move(done));
  WhenBrowsersExited([this, waiting]() { RemoveStore(1, std::move(*waiting)); });
}

void RailgunPageHost::Shutdown() {
  ClosePage(Error::Disconnected("closed"));
  closed_pages_.clear();
  environment_.Reset();
  for (auto& entry : retired_) {
    ComPtr<ICoreWebView2Environment5> environment5;
    if (SUCCEEDED(entry.second.environment.As(&environment5))) {
      environment5->remove_BrowserProcessExited(entry.second.token);
    }
  }
  retired_.clear();
  Dispatch::Get().Cancel(exit_timer_);
  exit_timer_ = 0;
  exit_waiters_.clear();
  sink_ = nullptr;
  buffered_.clear();
}

void RailgunPageHost::RemoveStore(int attempt, Done done) {
  std::error_code error;
  if (page_ != nullptr) {
    // A page loaded since: its store is in use.
    const Error busy = Error::Failed("the page's data could not be removed");
    done(&busy);
    return;
  }
  if (paths_.user_data_folder.empty() || !std::filesystem::exists(paths_.user_data_folder, error)) {
    done(nullptr);
    return;
  }
  std::filesystem::remove_all(paths_.user_data_folder, error);
  if (!error) {
    done(nullptr);
    return;
  }
  if (attempt >= kWipeAttempts) {
    const Error failed = Error::Failed("the page's data could not be removed");
    done(&failed);
    return;
  }
  auto waiting = std::make_shared<Done>(std::move(done));
  Dispatch::Get().After(kWipeRetryMs, [this, attempt, waiting]() { RemoveStore(attempt + 1, std::move(*waiting)); });
}

bool RailgunPageHost::IsOpen() const { return page_ != nullptr && page_->IsLoaded() && page_->IsOpen(); }

void RailgunPageHost::SetEventSink(std::function<void(const std::string& raw_json)> sink) {
  sink_ = std::move(sink);
  if (!sink_) return;
  std::deque<std::string> waiting;
  waiting.swap(buffered_);
  for (const std::string& raw_json : waiting) sink_(raw_json);
}

void RailgunPageHost::Emit(const std::string& raw_json) {
  if (sink_) {
    sink_(raw_json);
    return;
  }
  buffered_.push_back(raw_json);
  while (buffered_.size() > kEventBuffer) buffered_.pop_front();
}

void RailgunPageHost::SetWindowShown(bool shown) {
  window_shown_ = shown;
  if (page_) page_->SetVisible(Visible());
}

void RailgunPageHost::SetSessionAway(bool away) {
  session_away_ = away;
  if (page_) page_->SetVisible(Visible());
}

void RailgunPageHost::ClosePage(const Error& reason) {
  ++generation_;
  if (page_) page_->Close(reason);
}

void RailgunPageHost::Forget(RailgunPage* closed) {
  if (page_.get() != closed) return;
  ComPtr<ICoreWebView2Environment> environment = std::move(environment_);
  const bool had_webview = closed->HadWebView();
  closed_pages_.push_back(std::move(page_));
  // A browser process that ran a page exits once the page's controller has closed; one that never did lets go of the
  // store when it is released.
  if (had_webview) Retire(std::move(environment));
  Dispatch::Get().Post([this]() { closed_pages_.clear(); });
}

void RailgunPageHost::Retire(ComPtr<ICoreWebView2Environment> environment) {
  if (!environment) return;
  ComPtr<ICoreWebView2Environment5> environment5;
  if (FAILED(environment.As(&environment5))) return;
  const uint64_t id = ++next_retired_;
  Retired retired;
  retired.environment = environment;
  // Registered before this call returns to the message loop, which is where the exit is reported.
  if (FAILED(environment5->add_BrowserProcessExited(
          Callback<ICoreWebView2BrowserProcessExitedEventHandler>(
              [this, id](ICoreWebView2Environment*, ICoreWebView2BrowserProcessExitedEventArgs*) -> HRESULT {
                // Not inside the environment's own event: it is released there.
                Dispatch::Get().Post([this, id]() { Exited(id); });
                return S_OK;
              })
              .Get(),
          &retired.token))) {
    return;
  }
  retired_[id] = std::move(retired);
}

void RailgunPageHost::Exited(uint64_t id) {
  auto found = retired_.find(id);
  if (found == retired_.end()) return;
  ComPtr<ICoreWebView2Environment5> environment5;
  if (SUCCEEDED(found->second.environment.As(&environment5))) {
    environment5->remove_BrowserProcessExited(found->second.token);
  }
  retired_.erase(found);
  if (retired_.empty()) RunExitWaiters();
}

void RailgunPageHost::WhenBrowsersExited(std::function<void()> then) {
  if (retired_.empty()) {
    then();
    return;
  }
  exit_waiters_.push_back(std::move(then));
  if (exit_timer_ != 0) return;
  exit_timer_ = Dispatch::Get().After(kBrowserExitWaitMs, [this]() {
    exit_timer_ = 0;
    // Given up on: the next environment tries again while the store is held.
    for (auto& entry : retired_) {
      ComPtr<ICoreWebView2Environment5> environment5;
      if (SUCCEEDED(entry.second.environment.As(&environment5))) {
        environment5->remove_BrowserProcessExited(entry.second.token);
      }
    }
    retired_.clear();
    RunExitWaiters();
  });
}

void RailgunPageHost::RunExitWaiters() {
  Dispatch::Get().Cancel(exit_timer_);
  exit_timer_ = 0;
  std::vector<std::function<void()>> waiters;
  waiters.swap(exit_waiters_);
  for (auto& waiter : waiters) waiter();
}

}  // namespace railgun_windows
