#ifndef RUNNER_RAILGUN_RAILGUN_REQUESTS_H_
#define RUNNER_RAILGUN_RAILGUN_REQUESTS_H_

#include <string>
#include <string_view>

// Where the Railgun page's requests go on Windows: Android's `RailgunRequests.route` and `RailgunArchiveFetch.handles`
// (RailgunWebViewHost.kt, RailgunArchiveFetch.kt), for WebView2's `WebResourceRequested`, which sees every request the
// page makes. The page's own files, on its own origin; a GET of Anon's archive, which the host answers itself; https to
// the allowlisted hosts on the default port, which goes out through the bridge; and nothing else (403). The hosts are
// Linux's `kHosts` (railgun_page/railgun_endpoints.h), which the Windows build compiles unchanged, and which a Rust test
// (`railgun_bridge.rs`) pins to the bridge's allowlist, Kotlin's and Swift's hosts and the page's CSP. Nothing here
// logs a URL: a keyed RPC URL carries its key.
namespace railgun_windows {

// The page's own origin, as on iOS, the Mac and Linux: WebView2 registers the scheme as secure, with an authority, so
// the page's requests carry `Origin: veylor-railgun://app`, the other desktop hosts' (an Alchemy origin allowlist
// needs it).
inline constexpr wchar_t kPageScheme[] = L"veylor-railgun";
inline constexpr wchar_t kPageOrigin[] = L"veylor-railgun://app";
inline constexpr wchar_t kPageUrl[] = L"veylor-railgun://app/index.html";

// The User-Agent of every request the page makes, and of the host's archive fetches: Android's
// (`RailgunRequests.USER_AGENT`), the same on every computer, naming no model, build or version. WebView2's own names
// the runtime's version. A Rust test (`railgun_bridge.rs`) reads this literal.
inline constexpr char kUserAgent[] = "Mozilla/5.0";

// Anon's archive, which the host fetches for the page (railgun_archive.h): the host the page's `ARCHIVES` names, which
// the bridge's allowlist and the page's CSP list. A Rust test (`railgun_bridge.rs`) reads this literal.
inline constexpr char kArchiveHost[] = "digest.anon.inc";

enum class Route {
  // One of the page's own files (`veylor-railgun://app/…`).
  kOwnFile,
  // A GET of Anon's archive on the default https port: the host fetches it through the bridge.
  kArchive,
  // https to an allowlisted host on the default port, or `blob:` and `data:`: the request goes on, through the bridge.
  kAllowed,
  // Anything else: refused with a 403, never sent.
  kBlocked,
};

// A URL as WebView2 gives it (Chromium's canonical form: the scheme and host lower case, a default port dropped).
struct ParsedUrl {
  std::string scheme;
  std::string host;
  bool has_port = false;
  bool has_userinfo = false;
  // From the first `/` of the path, without the query or the fragment.
  std::string path;
  // The path and the query, without the fragment: what the archive's request asks for.
  std::string path_and_query;
};

// `url` read into `out`; false when it can't be read, which the caller refuses.
bool ParseUrl(std::string_view url, ParsedUrl* out);

// Whether `host` is one of the page's hosts, a `*.` entry taking any subdomain (one label or more of letters, digits
// and inner hyphens, never the domain itself), as Kotlin's `RailgunEndpoints.allows`.
bool HostAllowed(std::string_view host);

// Where a request for `url` with `method` goes.
Route RouteOf(const ParsedUrl& url, std::string_view method);

// The file `path` (a URL path on the page's origin) names inside `root`, or empty: nothing outside it, no directory, no
// link, and only the types the page loads, whose Content-Type goes to `type` (`instantiateStreaming` needs
// `application/wasm`). As iOS's `RailgunSchemeHandler`.
std::wstring OwnFile(const std::wstring& root, const std::string& path, std::wstring* type);

}  // namespace railgun_windows

#endif  // RUNNER_RAILGUN_RAILGUN_REQUESTS_H_
