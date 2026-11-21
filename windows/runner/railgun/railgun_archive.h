#ifndef RUNNER_RAILGUN_RAILGUN_ARCHIVE_H_
#define RUNNER_RAILGUN_RAILGUN_ARCHIVE_H_

#include <windows.h>

#include <wrl.h>

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#pragma warning(push, 0)
#include "WebView2.h"
#pragma warning(pop)

// Anon's archive of Railgun's history, fetched for the page by the host, as Android's and the Mac's hosts fetch it
// (`RailgunArchiveFetch.kt`, `RailgunArchive.swift`). The archive sends no CORS headers, so the page can't read it
// itself. On Chromium the page finds no WebKit host and reads the archive by itself (checklist H22, no prelude), and
// WebView2's `WebResourceRequested` hands the host each of its GETs of `https://digest.anon.inc/…`; the host answers
// them later through the request's deferral, for the page's origin.
//
// Windows's HTTP stacks have no SOCKS5 client (WinHTTP has no SOCKS at all, WinINet only SOCKS4 with a local lookup),
// so the fetch itself is the wallet library's (`rust/src/railgun_archive.rs`, over its C ABI): HTTP/1.1 through the
// page's own bridge, hostnames unresolved, with Android's limits, headers and connection rules (checklist H23 to H31).
// This file only finds that fetch in `rust_lib_zcash_wallet.dll`, keeps the page's deferrals and answers them on the
// UI thread. Without the library's fetch every archive request is a 502, which the page tries again and then leaves
// for rail-squid. It logs nothing.
namespace railgun_windows {

// Why the wallet library's archive fetch isn't here, for the check program (tests/railgun_page): empty when it is.
std::string ArchiveLibraryProblem();

class RailgunArchive {
 public:
  // The archive's requests of a page whose bridge listens on loopback `bridge_port`.
  explicit RailgunArchive(int bridge_port);
  ~RailgunArchive();
  RailgunArchive(const RailgunArchive&) = delete;
  RailgunArchive& operator=(const RailgunArchive&) = delete;

  // Whether the wallet library's fetch is here.
  bool available() const { return session_ != 0; }

  // Takes `args`, a GET of the archive at `path_and_query`, and answers it later through its deferral: what the
  // archive answered (a 2xx, 4xx or 5xx, its body and its type), else a 502. `environment` makes the answer.
  void Start(ICoreWebView2Environment* environment, ICoreWebView2WebResourceRequestedEventArgs* args,
             const std::string& path_and_query);

  // The page closed: every fetch ends unanswered and every connection closes, kept ones included. Idempotent.
  void Close();

  // What the check program reads (tests/railgun_page): requests taken, and how they were answered.
  struct Counts {
    unsigned requests = 0;
    unsigned successes = 0;
    unsigned errors = 0;
    unsigned failures = 0;
  };
  const Counts& counts() const { return counts_; }

 private:
  struct Pending {
    Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment;
    Microsoft::WRL::ComPtr<ICoreWebView2WebResourceRequestedEventArgs> args;
    Microsoft::WRL::ComPtr<ICoreWebView2Deferral> deferral;
  };

  static void OnDone(void* context, uint64_t session, uint64_t request, uint16_t status, const char* content_type,
                     const uint8_t* body, size_t body_length);
  static void Answer(uint64_t session, uint64_t request, uint16_t status, std::string type, std::vector<uint8_t> body);
  void Complete(uint64_t request, uint16_t status, const std::string& type, const std::vector<uint8_t>& body);
  void Count(uint16_t status);

  uint64_t session_ = 0;
  uint64_t next_request_ = 0;
  bool closed_ = false;
  std::map<uint64_t, Pending> pending_;
  Counts counts_;
};

// Answers `args` now with `status`, `type` and `body`, for the page's origin (`Access-Control-Allow-Origin`), never
// cached. No reason phrase is read by the page.
void AnswerArchiveRequest(ICoreWebView2Environment* environment, ICoreWebView2WebResourceRequestedEventArgs* args,
                          uint16_t status, const std::string& type, const std::vector<uint8_t>& body);

}  // namespace railgun_windows

#endif  // RUNNER_RAILGUN_RAILGUN_ARCHIVE_H_
