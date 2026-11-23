#include "railgun/railgun_archive.h"

#include <shlwapi.h>

#include <mutex>
#include <set>
#include <utility>

#include "railgun/railgun_dispatch.h"
#include "railgun/railgun_network.h"
#include "railgun/railgun_requests.h"
#include "railgun/railgun_text.h"

namespace railgun_windows {
namespace {

constexpr uint16_t kBadGateway = 502;

// The wallet library's archive fetch (`rust/src/railgun_archive.rs`), found by name in its DLL, which Dart has already
// loaded by the time a page opens. Never linked: a library without it leaves the archive to rail-squid.
using DoneFn = void (*)(void* context, uint64_t session, uint64_t request, uint16_t status, const char* content_type,
                        const uint8_t* body, size_t body_length);
using OpenFn = uint64_t (*)(uint16_t bridge_port);
using FetchFn = bool (*)(uint64_t session, uint64_t request, const char* path_and_query, DoneFn done, void* context);
using SessionFn = void (*)(uint64_t session);

struct Library {
  OpenFn open = nullptr;
  FetchFn fetch = nullptr;
  SessionFn network_changed = nullptr;
  SessionFn close = nullptr;
  // Why the fetch isn't here, for the check program; empty once found.
  std::string problem;
};

const Library& WalletLibrary() {
  static const Library library = []() {
    Library found;
    HMODULE module = ::GetModuleHandleW(L"rust_lib_zcash_wallet.dll");
    if (module == nullptr) {
      // Beside the executable, with its own dependencies (the C runtime) from System32: never the search path or the
      // current directory. The app never gets here (Dart has loaded the library); the check program does.
      module = ::LoadLibraryExW(L"rust_lib_zcash_wallet.dll", nullptr,
                                LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    }
    if (module == nullptr) {
      found.problem = "the wallet library did not load (" + std::to_string(::GetLastError()) + ")";
      return found;
    }
    found.open = reinterpret_cast<OpenFn>(::GetProcAddress(module, "veylor_railgun_archive_open"));
    found.fetch = reinterpret_cast<FetchFn>(::GetProcAddress(module, "veylor_railgun_archive_fetch"));
    found.network_changed =
        reinterpret_cast<SessionFn>(::GetProcAddress(module, "veylor_railgun_archive_network_changed"));
    found.close = reinterpret_cast<SessionFn>(::GetProcAddress(module, "veylor_railgun_archive_close"));
    if (found.open == nullptr || found.fetch == nullptr || found.network_changed == nullptr ||
        found.close == nullptr) {
      Library missing;
      missing.problem = "the wallet library has no archive fetch";
      return missing;
    }
    return found;
  }();
  return library;
}

// The archives of open pages, by session: the UI thread's, so an answer that arrives for a closed page finds none.
std::map<uint64_t, RailgunArchive*>& Archives() {
  static std::map<uint64_t, RailgunArchive*> archives;
  return archives;
}

// A change of network drops every kept connection, as Android's pool does (checklist H27, rule 4): the tunnels the
// bridge opened on the old network may be dead without having closed. Windows says so on a thread of its own, so the
// live sessions are kept under a lock.
struct NetworkWatch {
  std::mutex lock;
  std::set<uint64_t> sessions;
};

NetworkWatch& Watch() {
  // Never freed: Windows may call back while the process ends.
  static NetworkWatch* watch = new NetworkWatch();
  return *watch;
}

void OnNetworkChanged() {
  const Library& library = WalletLibrary();
  NetworkWatch& watch = Watch();
  std::set<uint64_t> sessions;
  {
    std::lock_guard<std::mutex> guard(watch.lock);
    sessions = watch.sessions;
  }
  for (uint64_t session : sessions) library.network_changed(session);
}

void WatchSession(uint64_t session, bool watched) {
  NetworkWatch& watch = Watch();
  {
    std::lock_guard<std::mutex> guard(watch.lock);
    if (watched) {
      watch.sessions.insert(session);
    } else {
      watch.sessions.erase(session);
    }
  }
  if (watched) WatchNetworkChanges(&OnNetworkChanged);
}

}  // namespace

void AnswerArchiveRequest(ICoreWebView2Environment* environment, ICoreWebView2WebResourceRequestedEventArgs* args,
                          uint16_t status, const std::string& type, const std::vector<uint8_t>& body) {
  if (environment == nullptr || args == nullptr) return;
  Microsoft::WRL::ComPtr<IStream> stream;
  stream.Attach(::SHCreateMemStream(body.empty() ? nullptr : body.data(), static_cast<UINT>(body.size())));
  const std::string content_type = type.empty() ? std::string("application/octet-stream") : type;
  const std::wstring headers = L"Content-Type: " + Utf16(content_type) + L"\r\nAccess-Control-Allow-Origin: " +
                               kPageOrigin + L"\r\nCache-Control: no-store";
  Microsoft::WRL::ComPtr<ICoreWebView2WebResourceResponse> response;
  const bool success = status >= 200 && status < 300;
  if (SUCCEEDED(environment->CreateWebResourceResponse(stream.Get(), static_cast<int>(status),
                                                       success ? L"OK" : L"Error", headers.c_str(), &response))) {
    args->put_Response(response.Get());
  }
}

std::string ArchiveLibraryProblem() { return WalletLibrary().problem; }

RailgunArchive::RailgunArchive(int bridge_port) {
  const Library& library = WalletLibrary();
  if (library.open == nullptr || bridge_port <= 0 || bridge_port > 65535) return;
  session_ = library.open(static_cast<uint16_t>(bridge_port));
  if (session_ == 0) return;
  Archives()[session_] = this;
  WatchSession(session_, true);
}

RailgunArchive::~RailgunArchive() { Close(); }

void RailgunArchive::Start(ICoreWebView2Environment* environment, ICoreWebView2WebResourceRequestedEventArgs* args,
                           const std::string& path_and_query) {
  ++counts_.requests;
  if (closed_ || session_ == 0) {
    Count(kBadGateway);
    AnswerArchiveRequest(environment, args, kBadGateway, "text/plain", {});
    return;
  }
  Pending pending;
  pending.environment = environment;
  pending.args = args;
  if (FAILED(args->GetDeferral(&pending.deferral))) {
    Count(kBadGateway);
    AnswerArchiveRequest(environment, args, kBadGateway, "text/plain", {});
    return;
  }
  const uint64_t request = ++next_request_;
  pending_[request] = std::move(pending);
  if (!WalletLibrary().fetch(session_, request, path_and_query.c_str(), &RailgunArchive::OnDone, nullptr)) {
    Complete(request, kBadGateway, "text/plain", {});
  }
}

void RailgunArchive::Close() {
  if (closed_) return;
  closed_ = true;
  if (session_ != 0) {
    WatchSession(session_, false);
    // After this returns the library calls `OnDone` for none of the session's fetches.
    WalletLibrary().close(session_);
    Archives().erase(session_);
  }
  // Unanswered: the page is going.
  pending_.clear();
}

void RailgunArchive::OnDone(void*, uint64_t session, uint64_t request, uint16_t status, const char* content_type,
                            const uint8_t* body, size_t body_length) {
  // On one of the library's threads, with `body` lent for this call only.
  std::string type = content_type == nullptr ? std::string() : std::string(content_type);
  std::vector<uint8_t> bytes;
  if (body != nullptr && body_length > 0) bytes.assign(body, body + body_length);
  Dispatch::Get().Post([session, request, status, kind = std::move(type), data = std::move(bytes)]() mutable {
    Answer(session, request, status, std::move(kind), std::move(data));
  });
}

void RailgunArchive::Answer(uint64_t session, uint64_t request, uint16_t status, std::string type,
                            std::vector<uint8_t> body) {
  auto found = Archives().find(session);
  if (found == Archives().end()) return;
  found->second->Complete(request, status, type, body);
}

void RailgunArchive::Complete(uint64_t request, uint16_t status, const std::string& type,
                              const std::vector<uint8_t>& body) {
  auto found = pending_.find(request);
  if (found == pending_.end()) return;
  Pending pending = std::move(found->second);
  pending_.erase(found);
  Count(status);
  AnswerArchiveRequest(pending.environment.Get(), pending.args.Get(), status, type, body);
  pending.deferral->Complete();
}

void RailgunArchive::Count(uint16_t status) {
  if (status >= 200 && status < 300) {
    ++counts_.successes;
  } else if (status == kBadGateway) {
    ++counts_.failures;
  } else {
    ++counts_.errors;
  }
}

}  // namespace railgun_windows
