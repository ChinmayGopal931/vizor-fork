#ifndef RUNNER_RAILGUN_PAGE_RAILGUN_ARCHIVE_H_
#define RUNNER_RAILGUN_PAGE_RAILGUN_ARCHIVE_H_

#include <webkit2/webkit2.h>

#include <string>
#include <vector>

// Anon's archive of Railgun's history, fetched for the page by this process as Android's and the Mac's hosts fetch it
// (`RailgunArchiveFetch.kt`, `RailgunArchive.swift`). The archive sends no CORS headers, so the page can't read it,
// and WebKit can't intercept `https`. Before a `start` that reads the archive the host runs `kArchivePrelude` in the
// page: the page's archive requests then go to `kArchivePath` on its own origin, which `ArchiveFetch` answers through
// the page's own bridge, and its start reads the archive, as the Android page's does (the page reads it only where it
// finds no WebKit host). Every request goes through the Rust loopback SOCKS5 bridge, which resolves the hostname on
// the wallet's route (Tor when that is on) and checks it against its allowlist, as it does the page's own connections;
// never directly. A Rust test (`railgun_bridge.rs`) reads `kArchiveHost`, so keep it literal.
namespace railgun_page {

// Anon's archive: the host the page's `ARCHIVES` names, which the bridge's allowlist and the page's CSP list.
inline constexpr char kArchiveHost[] = "digest.anon.inc";

// Where the page's archive requests go on its own origin: no file of the bundle lives under it.
inline constexpr char kArchivePath[] = "/anon-archive/";

// Far above the archive's largest file and far below the app's memory: a body past it is refused, never kept.
inline constexpr size_t kArchiveMaxBytes = 16 * 1024 * 1024;

// The page gives up on a request after a minute, and so does the host.
inline constexpr unsigned kArchiveDeadlineSeconds = 60;

// A connection or a read that stalls this long fails, as Android's connect and read timeouts.
inline constexpr unsigned kArchiveStallSeconds = 20;

// The same for every computer, and Android's: the platform's own would name the system and its build.
inline constexpr char kArchiveUserAgent[] = "Mozilla/5.0";

// Android's connection pool (`ConfigAwareConnectionPool`'s defaults): five connections at most, each kept idle for
// five minutes at most. Five also leaves the page's four requests in flight a connection each.
inline constexpr unsigned kArchiveMaxConnections = 5;
inline constexpr unsigned kArchiveKeepAliveSeconds = 5 * 60;

// Run in the page's world before every `start` that reads the archive; idempotent, and true once the page will read
// it. WebKit's `window.webkit` can't be redefined, so it hides the host behind an own `messageHandlers` on the
// `webkit` object instead, and holds that object on the global: WebKit makes it anew, with the real handlers, once
// nothing in the page refers to it, so a garbage collection between the prelude and the start would show the start
// the host again (the Mac's page skipped the archive so). The page took its transport (`railgunHost`) when it loaded,
// which keeps posting, and only the start's archive check reads the handlers again. Archive GETs then go to
// `kArchivePath`, the rest of the page's requests as they were. Nothing is spliced into it.
extern const char kArchivePrelude[];

// The archive URL a request to `kArchivePath` on the page's origin stands for: the same path and query on the
// archive's host, over https on its default port. Empty for anything else.
std::string ArchiveUpstream(const char* page_uri);

// Whether WebKit takes `status` as an answer the page reads: a success or an error. A redirect is never followed, and
// is a failure.
bool ArchiveServable(unsigned status);

// The archive's session, a pool of connections through the bridge at `bridge_port` alone, and a request for
// `upstream`, as Android's host makes them: HTTP/1.1, so a connection carries one request at a time (never multiplexed
// on one HTTP/2 connection, which a stalled connection would hold whole); at most five, each kept idle five minutes;
// a 20 s connect or read stall; no cookie, cache, credential, decoding or sniffing; and exactly Android's headers:
// `Host`, `User-Agent: Mozilla/5.0`, `Accept-Encoding: identity` and `Connection: Keep-Alive`, no `Accept-Language`
// and no cache directive. Separate so a check can see what they send.
SoupSession* NewArchiveSession(int bridge_port);
SoupMessage* NewArchiveMessage(const char* upstream);

// One page's archive requests, fetched through its bridge as Android's host fetches them (`RailgunArchiveFetch.kt`):
// a GET of the archive on the default https port, a minute and 16 MB an answer at most, no redirect followed, and the
// files as served (never unzipped on the way, since the page checks them against the archive's checksums as served).
// A failure is a 502, which the page tries again and then takes as the archive's, as on Android. Its connections are
// kept as Android keeps them: one whose answer was read whole goes back to the pool for the next request, one whose
// request failed, stalled, was refused for its size or was abandoned is closed, and a change of network starts a new
// pool. WebKitGTK doesn't say when the page aborts a request, so such a fetch runs to its own end and its answer is
// dropped, as on Android. Everything runs on the main loop. It logs nothing.
class ArchiveFetch {
 public:
  explicit ArchiveFetch(int bridge_port);
  ~ArchiveFetch();
  ArchiveFetch(const ArchiveFetch&) = delete;
  ArchiveFetch& operator=(const ArchiveFetch&) = delete;

  // Off until the page's start reads the archive: before that, a request under `kArchivePath` is refused.
  void Enable() { enabled_ = true; }

  void Start(WebKitURISchemeRequest* request);

  // The page closed: every fetch is cancelled and nothing is fetched again.
  void Close();

  struct Fetch;
  // `fetch` answered.
  void Remove(Fetch* fetch);

 private:
  SoupSession* Session();
  static void OnNetworkChanged(GNetworkMonitor* monitor, gboolean available, gpointer data);

  int bridge_port_;
  bool enabled_ = false;
  bool closed_ = false;
  SoupSession* session_ = nullptr;
  gulong network_changed_handler_ = 0;
  std::vector<Fetch*> fetches_;
};

// Answers `request` in full, once.
void AnswerSchemeRequest(WebKitURISchemeRequest* request, unsigned status, const char* type, GBytes* body,
                         const char* content_security_policy);

}  // namespace railgun_page

#endif  // RUNNER_RAILGUN_PAGE_RAILGUN_ARCHIVE_H_
