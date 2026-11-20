// veylor-railgun-page: Shielded USD's Railgun page, in a process of its own (railgun_page.h). Veylor starts it as
//
//   veylor-railgun-page --probe
//   veylor-railgun-page --page --fd 3 --proxy-port <port> --data-dir <dir> --bundle-dir <dir> [--debug]
//
// with a clean environment, and nothing else does.

#include <gtk/gtk.h>
#include <signal.h>
#include <sys/prctl.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>
#include <string>

#include "private_usd/railgun_frames.h"
#include "railgun_page/railgun_page.h"
#include "railgun_page/webkit_api.h"

namespace {

// Tells Veylor, on the link, that the page can't run here, before there is a main loop to do it with.
void SendUnavailable(int fd, const std::string& reason) {
  if (fd < 3) return;
  std::string payload(1, railgun_frames::kClosedUnavailable);
  payload += reason;
  const uint32_t length = static_cast<uint32_t>(payload.size() + 1);
  std::string frame = {static_cast<char>((length >> 24) & 0xFF), static_cast<char>((length >> 16) & 0xFF),
                       static_cast<char>((length >> 8) & 0xFF), static_cast<char>(length & 0xFF),
                       railgun_frames::kClosed};
  frame += payload;
  (void)!write(fd, frame.data(), frame.size());
}

}  // namespace

int main(int argc, char** argv) {
  using railgun_page::kExitNoDisplay;
  using railgun_page::kExitNoWebKit;
  using railgun_page::kExitUsage;

  // Ends with Veylor, whatever ends it.
  const pid_t parent = getppid();
  prctl(PR_SET_PDEATHSIG, SIGTERM);
  if (getppid() != parent) return kExitUsage;

  bool probe = false;
  bool page = false;
  railgun_page::PageOptions options;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    const bool has_value = i + 1 < argc;
    if (arg == "--probe") {
      probe = true;
    } else if (arg == "--page") {
      page = true;
    } else if (arg == "--debug") {
      options.debug = true;
    } else if (arg == "--fd" && has_value) {
      options.link_fd = std::atoi(argv[++i]);
    } else if (arg == "--proxy-port" && has_value) {
      options.proxy_port = std::atoi(argv[++i]);
    } else if (arg == "--data-dir" && has_value) {
      options.data_dir = argv[++i];
    } else if (arg == "--bundle-dir" && has_value) {
      options.bundle_dir = argv[++i];
    } else {
      return kExitUsage;
    }
  }
  if (probe == page) return kExitUsage;
  if (page && (options.link_fd < 3 || options.proxy_port < 1 || options.proxy_port > 65535 ||
               options.data_dir.empty() || options.bundle_dir.empty())) {
    return kExitUsage;
  }

  g_set_prgname("veylor-railgun-page");
  if (!gtk_init_check(nullptr, nullptr)) {
    railgun_page::Log("unavailable: no display");
    SendUnavailable(options.link_fd, "the page has no display");
    return kExitNoDisplay;
  }
  railgun_page::WebKitApi api;
  std::string why;
  if (!railgun_page::LoadWebKit(&api, &why)) {
    railgun_page::Log("unavailable: " + why);
    SendUnavailable(options.link_fd, "WebKitGTK is missing or too old");
    return kExitNoWebKit;
  }
  return probe ? railgun_page::RunProbe() : railgun_page::RunPage(options);
}
