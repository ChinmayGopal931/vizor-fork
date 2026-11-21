// The Windows Railgun page host's check program: the host's own page code (runner/railgun), driven as Dart drives
// it, with the real bundle and a stand-in for the Rust bridge, and nothing of the wallet. Each mode loads a page,
// checks what the hosts checklist asks (docs/private-usd-railgun-hosts.md) and prints one JSON object per line;
// scripts/windows-railgun/check_railgun_page.py runs the modes and judges the lines. It prints no mnemonic, key or
// page message: the wallet it opens is BIP-39's public test wallet, and nothing is spent.
//
//   railgun_page_check --mode <supported|environment|sync|reopen|wipe> --bundle <dir> --data <dir>
//                      --proxy-port <port> [--network sepolia|mainnet] [--rpc <url>] [--archive] [--seconds <n>]
//                      [--mnemonic <words>] [--key <hex>] [--blocked-host <host>]
#include <windows.h>

#include <wrl.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#pragma warning(push, 0)
#include "WebView2.h"
#pragma warning(pop)

#include "private_usd/railgun_json.h"
#include "private_usd/railgun_protocol.h"
#include "railgun/railgun_dispatch.h"
#include "railgun/railgun_page_host.h"
#include "railgun/railgun_requests.h"
#include "railgun/railgun_text.h"

namespace {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using railgun_windows::Dispatch;
using railgun_windows::Error;
using railgun_windows::RailgunPageHost;
using railgun_windows::Utf16;
using railgun_windows::Utf8;

struct Options {
  std::string mode;
  std::wstring bundle;
  std::wstring data;
  int proxy_port = 0;
  std::string network = "sepolia";
  std::string rpc;
  std::string poi = "https://ppoi.fdi.network/";
  bool archive = false;
  int seconds = 600;
  std::string mnemonic;
  std::string key;
  std::string blocked_host;
};

Options g_options;
int g_exit = 0;
HWND g_view = nullptr;
std::chrono::steady_clock::time_point g_started = std::chrono::steady_clock::now();
std::map<std::string, int> g_events;
std::function<void(const std::string& name, const std::string& raw_json)> g_on_event;

long long Ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - g_started).count();
}

void Print(const std::string& line) {
  std::fputs(line.c_str(), stdout);
  std::fputc('\n', stdout);
  std::fflush(stdout);
}

std::string Quote(const std::string& text) { return railgun_json::Quote(text); }

void Fail(const std::string& step, const std::string& why) {
  g_exit = 1;
  Print("{\"step\":" + Quote(step) + ",\"ok\":false,\"why\":" + Quote(why) + ",\"ms\":" + std::to_string(Ms()) + "}");
}

void Finish() { ::PostQuitMessage(g_exit); }

// Runs `steps` one after the other, each calling its `next` when done; a step that fails ends the run.
class Steps {
 public:
  using Step = std::function<void(std::function<void(bool ok)> next)>;
  void Add(Step step) { steps_.push_back(std::move(step)); }
  void Run() {
    if (index_ >= steps_.size()) {
      Finish();
      return;
    }
    Step step = steps_[index_++];
    step([this](bool ok) {
      if (!ok) {
        Finish();
        return;
      }
      Dispatch::Get().Post([this]() { Run(); });
    });
  }

 private:
  std::vector<Step> steps_;
  size_t index_ = 0;
};

std::string ErrorJson(const Error& error) {
  return "{\"code\":" + Quote(error.Code()) + ",\"message\":" + Quote(error.message) + "}";
}

// The `value` CDP's `Runtime.evaluate` returned, or empty.
std::string EvaluatedValue(const std::string& json) {
  railgun_json::Value root;
  railgun_json::Members members;
  if (!railgun_json::Parse(json, &root) || !railgun_json::ObjectMembers(json, root, &members)) return std::string();
  if (railgun_json::Find(members, "exceptionDetails") != nullptr) return std::string();
  const railgun_json::Value* result = railgun_json::Find(members, "result");
  railgun_json::Members inner;
  if (result == nullptr || !railgun_json::ObjectMembers(json, *result, &inner)) return std::string();
  const railgun_json::Value* value = railgun_json::Find(inner, "value");
  return value == nullptr ? std::string() : std::string(railgun_json::Raw(json, *value));
}

void Evaluate(const std::string& step, const std::wstring& script, std::function<void(bool ok)> next) {
  railgun_windows::RailgunPage* page = RailgunPageHost::Get().page();
  if (page == nullptr) {
    Fail(step, "no page");
    next(false);
    return;
  }
  page->Evaluate(script, [step, next](bool ok, const std::string& json) {
    const std::string value = ok ? EvaluatedValue(json) : std::string();
    if (value.empty()) {
      Fail(step, "the evaluation failed");
      next(false);
      return;
    }
    Print("{\"step\":" + Quote(step) + ",\"ok\":true,\"value\":" + value + ",\"ms\":" + std::to_string(Ms()) + "}");
    next(true);
  });
}

void Load(std::function<void(bool ok)> next) {
  const long long started = Ms();
  RailgunPageHost::Get().Load(g_options.proxy_port, false, [next, started](const Error* error) {
    if (error != nullptr) {
      Print("{\"step\":\"load\",\"ok\":false,\"error\":" + ErrorJson(*error) + "}");
      g_exit = 1;
      next(false);
      return;
    }
    Print("{\"step\":\"load\",\"ok\":true,\"ms\":" + std::to_string(Ms() - started) + "}");
    next(true);
  });
}

// One page call. Only the result's own keys are printed: its values can name the wallet. A call whose step went on
// without it (`abandoned` set) is not reported when its answer comes.
void Call(const std::string& method_name, const std::string& params_json, std::function<void(bool ok)> next,
          std::function<void(const std::string& result_json)> result = nullptr,
          std::shared_ptr<bool> abandoned = nullptr) {
  const railgun_protocol::Method* method = railgun_protocol::FindMethod(method_name);
  const railgun_protocol::Method debug_method = {method_name.c_str(), 600};
  if (method == nullptr) method = &debug_method;
  const long long started = Ms();
  const railgun_protocol::Method copy = *method;
  const std::string name = method_name;
  RailgunPageHost::Get().Call(copy, params_json, [name, next, result, started, abandoned](
                                                     const Error* error, const std::string& result_json) {
    if (abandoned && *abandoned) return;
    if (error != nullptr) {
      Print("{\"step\":" + Quote(name) + ",\"ok\":false,\"error\":" + ErrorJson(*error) + "}");
      g_exit = 1;
      next(false);
      return;
    }
    std::string keys;
    railgun_json::Value root;
    railgun_json::Members members;
    if (railgun_json::Parse(result_json, &root) && railgun_json::ObjectMembers(result_json, root, &members)) {
      for (const auto& member : members) keys += (keys.empty() ? "" : ",") + Quote(member.first);
    }
    Print("{\"step\":" + Quote(name) + ",\"ok\":true,\"keys\":[" + keys + "],\"ms\":" + std::to_string(Ms() - started) +
          "}");
    if (result) result(result_json);
    next(true);
  });
}

std::string StartParams() {
  return "{\"network\":" + Quote(g_options.network) + ",\"rpcUrls\":[" + Quote(g_options.rpc) +
         "],\"poiNodeUrls\":[" + Quote(g_options.poi) + "],\"archive\":" + (g_options.archive ? "true" : "false") +
         ",\"debug\":true}";
}

std::string OpenParams() {
  // Created three weeks ago: the notes scan works out keys for some leaves in its workers.
  const long long created_at = static_cast<long long>(std::time(nullptr)) - 21LL * 24 * 60 * 60;
  return "{\"encryptionKey\":" + Quote(g_options.key) + ",\"mnemonic\":" + Quote(g_options.mnemonic) +
         ",\"createdAt\":" + std::to_string(created_at) + "}";
}

// Waits for the event `name` (or `seconds`), then goes on whatever came.
void AwaitEvent(const std::string& name, int seconds, std::function<void(bool ok)> next) {
  if (g_events[name] > 0) {
    next(true);
    return;
  }
  auto done = std::make_shared<bool>(false);
  auto previous = g_on_event;
  g_on_event = [name, next, done, previous](const std::string& event, const std::string& raw_json) {
    if (previous) previous(event, raw_json);
    if (event != name || *done) return;
    *done = true;
    Print("{\"step\":\"event\",\"ok\":true,\"name\":" + Quote(name) + ",\"ms\":" + std::to_string(Ms()) + "}");
    Dispatch::Get().Post([next]() { next(true); });
  };
  Dispatch::Get().After(static_cast<UINT>(seconds) * 1000u, [name, next, done]() {
    if (*done) return;
    *done = true;
    Print("{\"step\":\"event\",\"ok\":false,\"name\":" + Quote(name) + ",\"why\":\"not in time\",\"ms\":" +
          std::to_string(Ms()) + "}");
    next(true);
  });
}

void PrintCounts(std::function<void(bool ok)> next) {
  std::string events;
  for (const auto& entry : g_events) {
    events += (events.empty() ? "" : ",") + Quote(entry.first) + ":" + std::to_string(entry.second);
  }
  std::string archive = "null";
  if (railgun_windows::RailgunPage* page = RailgunPageHost::Get().page()) {
    const auto& counts = page->archive().counts();
    archive = "{\"available\":" + std::string(page->archive().available() ? "true" : "false") +
              ",\"requests\":" + std::to_string(counts.requests) + ",\"successes\":" +
              std::to_string(counts.successes) + ",\"errors\":" + std::to_string(counts.errors) +
              ",\"failures\":" + std::to_string(counts.failures) + "}";
  }
  Print("{\"step\":\"counts\",\"ok\":true,\"events\":{" + events + "},\"archive\":" + archive + ",\"ms\":" +
        std::to_string(Ms()) + "}");
  next(true);
}

// Every header the network stack sends for the page's own requests, as DevTools sees them on the wire.
struct Headers {
  ComPtr<ICoreWebView2DevToolsProtocolEventReceiver> receiver;
  EventRegistrationToken token = {};
  std::vector<std::string> seen;
};
std::shared_ptr<Headers> g_headers;

void WatchHeaders(std::function<void(bool ok)> next) {
  railgun_windows::RailgunPage* page = RailgunPageHost::Get().page();
  if (page == nullptr || page->webview() == nullptr) {
    Fail("headers", "no page");
    next(false);
    return;
  }
  g_headers = std::make_shared<Headers>();
  std::shared_ptr<Headers> headers = g_headers;
  page->webview()->GetDevToolsProtocolEventReceiver(L"Network.requestWillBeSentExtraInfo", &headers->receiver);
  if (headers->receiver) {
    headers->receiver->add_DevToolsProtocolEventReceived(
        Callback<ICoreWebView2DevToolsProtocolEventReceivedEventHandler>(
            [headers](ICoreWebView2*, ICoreWebView2DevToolsProtocolEventReceivedEventArgs* args) -> HRESULT {
              railgun_windows::CoString json;
              if (SUCCEEDED(args->get_ParameterObjectAsJson(json.put()))) headers->seen.push_back(Utf8(json.view()));
              return S_OK;
            })
            .Get(),
        &headers->token);
  }
  page->webview()->CallDevToolsProtocolMethod(
      L"Network.enable", L"{}",
      Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>([next](HRESULT, LPCWSTR) -> HRESULT {
        next(true);
        return S_OK;
      }).Get());
}

// The quota Chromium enforces for the page's origin, which DevTools reads: since Chromium 133 the page's own
// `navigator.storage.estimate()` reports its usage plus 10 GiB whatever the disk (StaticStorageQuota).
void PrintQuota(std::function<void(bool ok)> next) {
  railgun_windows::RailgunPage* page = RailgunPageHost::Get().page();
  if (page == nullptr || page->webview() == nullptr) {
    Fail("quota", "no page");
    next(false);
    return;
  }
  page->webview()->CallDevToolsProtocolMethod(
      L"Storage.getUsageAndQuota", L"{\"origin\":\"veylor-railgun://app\"}",
      Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>([next](HRESULT result, LPCWSTR json)
                                                                             -> HRESULT {
        if (FAILED(result) || json == nullptr) {
          Fail("quota", "DevTools did not answer");
        } else {
          railgun_json::Value root;
          railgun_json::Members members;
          const std::string text = Utf8(json);
          std::string quota = "null";
          if (railgun_json::Parse(text, &root) && railgun_json::ObjectMembers(text, root, &members)) {
            if (const railgun_json::Value* value = railgun_json::Find(members, "quota")) {
              quota = std::string(railgun_json::Raw(text, *value));
            }
          }
          Print("{\"step\":\"quota\",\"ok\":true,\"quota\":" + quota + ",\"ms\":" + std::to_string(Ms()) + "}");
        }
        next(true);
        return S_OK;
      }).Get());
}

void PrintHeaders(std::function<void(bool ok)> next) {
  std::string seen;
  if (g_headers) {
    for (const std::string& json : g_headers->seen) {
      // Only the headers: the event's other members carry ids and cookies' details.
      railgun_json::Value root;
      railgun_json::Members members;
      if (!railgun_json::Parse(json, &root) || !railgun_json::ObjectMembers(json, root, &members)) continue;
      const railgun_json::Value* headers = railgun_json::Find(members, "headers");
      if (headers == nullptr) continue;
      seen += (seen.empty() ? "" : ",") + std::string(railgun_json::Raw(json, *headers));
    }
  }
  Print("{\"step\":\"headers\",\"ok\":true,\"requests\":[" + seen + "],\"ms\":" + std::to_string(Ms()) + "}");
  next(true);
}

// What the page's world offers (H6, H12, H18, H9's room), its timers while shown (H10), and its requests' fate: one to
// a host the CSP allows but the filter is told to refuse (H15), one the CSP forbids, and one to Anon's archive, which
// the host answers for the page's origin (H22, H26).
constexpr wchar_t kEnvironmentScript[] = LR"JS((async () => {
  const out = {};
  out.origin = location.origin;
  out.secure = isSecureContext;
  out.subtle = typeof crypto.subtle?.digest === 'function';
  out.digest = out.subtle ? Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new Uint8Array([1])))).length : 0;
  out.wasm = WebAssembly.validate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]));
  try { await WebAssembly.instantiate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])); out.wasmInstantiate = true; } catch (e) { out.wasmInstantiate = String(e); }
  try { localStorage.setItem('veylor-check', '1'); out.localStorage = localStorage.getItem('veylor-check') === '1'; localStorage.removeItem('veylor-check'); } catch (e) { out.localStorage = String(e); }
  try {
    out.indexedDB = await new Promise((resolve, reject) => {
      const request = indexedDB.open('veylor-check', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('s');
      request.onerror = () => reject(String(request.error));
      request.onsuccess = () => {
        const db = request.result;
        const tx = db.transaction('s', 'readwrite');
        tx.objectStore('s').put('ok', 'k');
        tx.oncomplete = () => { db.close(); indexedDB.deleteDatabase('veylor-check'); resolve(true); };
        tx.onerror = () => reject(String(tx.error));
      };
    });
  } catch (e) { out.indexedDB = String(e); }
  try {
    const url = URL.createObjectURL(new Blob(['self.onmessage = (e) => self.postMessage(e.data * 2);'], { type: 'text/javascript' }));
    const worker = new Worker(url, { type: 'module' });
    out.worker = await new Promise((resolve) => {
      worker.onmessage = (e) => resolve(e.data === 42);
      worker.onerror = (e) => resolve(String(e.message));
      setTimeout(() => resolve('no answer'), 5000);
      worker.postMessage(21);
    });
    worker.terminate();
  } catch (e) { out.worker = String(e); }
  out.userAgent = navigator.userAgent;
  out.userAgentData = navigator.userAgentData === undefined ? null : JSON.stringify(navigator.userAgentData.brands);
  out.languages = navigator.languages;
  out.visibility = document.visibilityState;
  out.cores = navigator.hardwareConcurrency;
  out.webrtc = typeof RTCPeerConnection;
  const estimate = await navigator.storage.estimate();
  out.quota = estimate.quota;
  out.usage = estimate.usage;
  out.timerTicks = await new Promise((resolve) => {
    let ticks = 0;
    const started = performance.now();
    const tick = () => { ticks += 1; if (performance.now() - started < 2000) setTimeout(tick, 0); else resolve(ticks); };
    tick();
  });
  const attempt = async (url, init) => {
    try { const response = await fetch(url, init); return { status: response.status, body: (await response.text()).slice(0, 64).length }; }
    catch (e) { return { failed: String(e?.name ?? e) }; }
  };
  out.refused = await attempt('https://BLOCKED_HOST/', { cache: 'no-store' });
  out.forbidden = await attempt('https://example.com/', { cache: 'no-store' });
  out.archive = await attempt('https://digest.anon.inc/v4/1/meta.json', { cache: 'no-store' });
  out.allowed = await attempt(RPC_URL, {
    method: 'POST', cache: 'no-store', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] }),
  });
  return out;
})())JS";

std::wstring ReplaceAll(std::wstring text, const std::wstring& from, const std::wstring& to) {
  for (size_t at = text.find(from); at != std::wstring::npos; at = text.find(from, at + to.size())) {
    text.replace(at, from.size(), to);
  }
  return text;
}

// The page's databases, before anything opens one: a store kept from an earlier run shows here (H9).
constexpr wchar_t kDatabasesScript[] =
    LR"JS((async () => ({ databases: (await indexedDB.databases()).map((db) => db.name).sort() }))())JS";

void BuildSteps(Steps* steps) {
  const std::string& mode = g_options.mode;
  if (mode == "supported") {
    steps->Add([](std::function<void(bool)> next) {
      Print(std::string("{\"step\":\"supported\",\"ok\":true,\"value\":") +
            (RailgunPageHost::IsSupported() ? "true" : "false") + ",\"runtime\":" +
            Quote(Utf8(RailgunPageHost::RuntimeVersion())) + "}");
      next(true);
    });
    return;
  }
  if (mode == "wipe") {
    steps->Add([](std::function<void(bool)> next) {
      RailgunPageHost::Get().Wipe([next](const Error* error) {
        std::error_code ignored;
        const bool gone = !std::filesystem::exists(RailgunPageHost::Get().paths().user_data_folder, ignored);
        if (error != nullptr || !gone) {
          Fail("wipe", error != nullptr ? error->message : "the store is still there");
          next(false);
          return;
        }
        Print("{\"step\":\"wipe\",\"ok\":true}");
        next(true);
      });
    });
    return;
  }
  steps->Add(Load);
  if (mode == "environment") {
    steps->Add(WatchHeaders);
    steps->Add([](std::function<void(bool)> next) {
      std::wstring script = ReplaceAll(kEnvironmentScript, L"BLOCKED_HOST", Utf16(g_options.blocked_host));
      script = ReplaceAll(script, L"RPC_URL", Utf16(Quote(g_options.rpc)));
      Evaluate("environment", script, next);
    });
    steps->Add(PrintHeaders);
    steps->Add(PrintQuota);
    steps->Add([](std::function<void(bool)> next) {
      RailgunPageHost::Get().Close();
      Print(std::string("{\"step\":\"close\",\"ok\":true,\"open\":") +
            (RailgunPageHost::Get().IsOpen() ? "true" : "false") + "}");
      next(true);
    });
    return;
  }
  if (mode == "reopen") {
    steps->Add([](std::function<void(bool)> next) { Evaluate("databases", kDatabasesScript, next); });
  }
  if (mode == "sync" || mode == "reopen") {
    steps->Add([](std::function<void(bool)> next) { Call("start", StartParams(), next); });
    steps->Add([](std::function<void(bool)> next) { Call("openWallet", OpenParams(), next); });
    steps->Add([](std::function<void(bool)> next) {
      // The refresh answers once the notes are scanned; the rest of the sync ends with a `synced` event.
      auto answered = std::make_shared<bool>(false);
      Dispatch::Get().After(static_cast<UINT>(g_options.seconds) * 1000u, [answered, next]() {
        if (*answered) return;
        *answered = true;
        Print("{\"step\":\"refresh\",\"ok\":true,\"stopped\":true,\"ms\":" + std::to_string(Ms()) + "}");
        next(true);
      });
      Call(
          "refresh", "{}",
          [answered, next](bool ok) {
            *answered = true;
            next(ok);
          },
          nullptr, answered);
    });
    if (g_options.network == "sepolia") {
      steps->Add([](std::function<void(bool)> next) { AwaitEvent("synced", 300, next); });
      steps->Add([](std::function<void(bool)> next) {
        Call("noteKeys", "{}", next, [](const std::string& result_json) {
          // Counts only: how many workers ran, and how many points they prepared.
          Print("{\"step\":\"noteKeysCounts\",\"ok\":true,\"value\":" + result_json + "}");
        });
      });
    }
    steps->Add(PrintCounts);
    steps->Add([](std::function<void(bool)> next) {
      RailgunPageHost::Get().Close();
      Print("{\"step\":\"close\",\"ok\":true}");
      next(true);
    });
  }
}

std::string Arg(int argc, wchar_t** argv, int* index) {
  if (*index + 1 >= argc) return std::string();
  ++*index;
  return Utf8(argv[*index]);
}

bool ReadOptions(int argc, wchar_t** argv) {
  for (int i = 1; i < argc; ++i) {
    const std::string name = Utf8(argv[i]);
    if (name == "--mode") {
      g_options.mode = Arg(argc, argv, &i);
    } else if (name == "--bundle") {
      g_options.bundle = Utf16(Arg(argc, argv, &i));
    } else if (name == "--data") {
      g_options.data = Utf16(Arg(argc, argv, &i));
    } else if (name == "--proxy-port") {
      g_options.proxy_port = std::atoi(Arg(argc, argv, &i).c_str());
    } else if (name == "--network") {
      g_options.network = Arg(argc, argv, &i);
    } else if (name == "--rpc") {
      g_options.rpc = Arg(argc, argv, &i);
    } else if (name == "--archive") {
      g_options.archive = true;
    } else if (name == "--seconds") {
      g_options.seconds = std::atoi(Arg(argc, argv, &i).c_str());
    } else if (name == "--mnemonic") {
      g_options.mnemonic = Arg(argc, argv, &i);
    } else if (name == "--key") {
      g_options.key = Arg(argc, argv, &i);
    } else if (name == "--blocked-host") {
      g_options.blocked_host = Arg(argc, argv, &i);
    } else {
      return false;
    }
  }
  return !g_options.mode.empty();
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_SIZE && g_view != nullptr) {
    // The stand-in for the Flutter view fills the window and covers the page's 1x1 window, as in the app.
    RECT client;
    ::GetClientRect(window, &client);
    ::MoveWindow(g_view, 0, 0, client.right - client.left, client.bottom - client.top, TRUE);
  }
  if (message == WM_DESTROY) ::PostQuitMessage(g_exit);
  return ::DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (!ReadOptions(argc, argv)) {
    std::fputs("usage: railgun_page_check --mode <mode> --bundle <dir> --data <dir> --proxy-port <port> ...\n", stderr);
    return 2;
  }
  if (FAILED(::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 3;

  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.hbrBackground = static_cast<HBRUSH>(::GetStockObject(BLACK_BRUSH));
  window_class.lpszClassName = L"VeylorRailgunPageCheck";
  ::RegisterClassExW(&window_class);
  HWND window = ::CreateWindowExW(0, window_class.lpszClassName, L"Railgun page check", WS_OVERLAPPEDWINDOW, 40, 40,
                                  640, 480, nullptr, nullptr, window_class.hInstance, nullptr);
  // The stand-in for the Flutter view: a child that fills the window, above the page's.
  g_view = ::CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, 0, 0, 640, 480, window,
                             nullptr, window_class.hInstance, nullptr);
  ::ShowWindow(window, SW_SHOWNOACTIVATE);
  ::UpdateWindow(window);

  RailgunPageHost& host = RailgunPageHost::Get();
  host.Attach(window, g_view);
  host.SetPaths({g_options.bundle, g_options.data});
  host.SetRefusedHostForCheck(g_options.blocked_host);
  host.SetEventSink([](const std::string& raw_json) {
    railgun_protocol::Message message = railgun_protocol::Decode(raw_json);
    if (message.type != railgun_protocol::Message::Type::kEvent) return;
    g_events[message.event] += 1;
    if (g_on_event) g_on_event(message.event, raw_json);
  });

  Steps steps;
  BuildSteps(&steps);
  // A whole run never outlasts its budget.
  Dispatch::Get().After(static_cast<UINT>(g_options.seconds + 600) * 1000u, []() {
    Fail("run", "the run took too long");
    Finish();
  });
  Dispatch::Get().Post([&steps]() { steps.Run(); });

  MSG message;
  while (::GetMessageW(&message, nullptr, 0, 0) > 0) {
    ::TranslateMessage(&message);
    ::DispatchMessageW(&message);
  }
  g_headers.reset();
  host.Shutdown();
  ::DestroyWindow(window);
  ::CoUninitialize();
  return g_exit;
}
