#ifndef RUNNER_RAILGUN_PAGE_RAILGUN_PAGE_H_
#define RUNNER_RAILGUN_PAGE_RAILGUN_PAGE_H_

#include <string>

// `veylor-railgun-page`: the Railgun page in a process of its own, on the system's WebKitGTK, in WebKit's sandbox.
// Veylor starts it with a clean environment and one end of a socket pair (railgun_frames.h); it never starts without
// both. The process exits with its page.
namespace railgun_page {

// Exit statuses, which Veylor's host reads (private_usd/railgun_host.cc).
inline constexpr int kExitOk = 0;
inline constexpr int kExitUsage = 1;
// WebKitGTK 4.1 or libsoup 3 is missing, or too old.
inline constexpr int kExitNoWebKit = 2;
// WebKit's sandbox did not start, or a page ran outside it.
inline constexpr int kExitSandbox = 3;
// The check's page did not load in time.
inline constexpr int kExitPageFailed = 4;
// No display to run on.
inline constexpr int kExitNoDisplay = 5;
// A fatal error after the page ran inside WebKit's sandbox: the page stopped, its sandbox had started.
inline constexpr int kExitFatal = 6;

struct PageOptions {
  int link_fd = -1;
  int proxy_port = 0;
  std::string data_dir;
  std::string bundle_dir;
  bool debug = false;
};

// Whether the page can run here, Veylor's `supported`: loads WebKitGTK, starts a sandboxed page and checks that its
// web process runs inside bubblewrap. WebKit aborts a process whose sandbox can't start, which is why this runs in a
// process of its own; that abort becomes `kExitSandbox`, never a crash.
int RunProbe();

// Runs the page until it closes.
int RunPage(const PageOptions& options);

// Our own diagnostic line on stderr, which Veylor logs (fixed text only, never a payload).
void Log(const std::string& line);

}  // namespace railgun_page

#endif  // RUNNER_RAILGUN_PAGE_RAILGUN_PAGE_H_
