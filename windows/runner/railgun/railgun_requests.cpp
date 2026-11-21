#include "railgun/railgun_requests.h"

#include <windows.h>

#include <cctype>

#include "railgun/railgun_text.h"
#include "railgun_page/railgun_endpoints.h"

namespace railgun_windows {
namespace {

char Lower(char c) { return static_cast<char>(std::tolower(static_cast<unsigned char>(c))); }

std::string LowerAscii(std::string_view text) {
  std::string out(text);
  for (char& c : out) c = Lower(c);
  return out;
}

bool EqualsIgnoringCase(std::string_view a, std::string_view b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    if (Lower(a[i]) != Lower(b[i])) return false;
  }
  return true;
}

bool IsAlnum(char c) { return std::isalnum(static_cast<unsigned char>(c)) != 0; }

// A hostname label as iOS's content rules match one: letters, digits and inner hyphens.
bool IsLabel(std::string_view label) {
  if (label.empty() || !IsAlnum(label.front()) || !IsAlnum(label.back())) return false;
  for (char c : label) {
    if (!IsAlnum(c) && c != '-') return false;
  }
  return true;
}

bool Matches(std::string_view pattern, std::string_view host) {
  if (pattern.substr(0, 2) != "*.") return EqualsIgnoringCase(pattern, host);
  const std::string_view suffix = pattern.substr(1);  // ".domain"
  if (host.size() <= suffix.size() || !EqualsIgnoringCase(host.substr(host.size() - suffix.size()), suffix)) {
    return false;
  }
  std::string_view labels = host.substr(0, host.size() - suffix.size());
  while (true) {
    const size_t dot = labels.find('.');
    if (!IsLabel(labels.substr(0, dot))) return false;
    if (dot == std::string_view::npos) return true;
    labels.remove_prefix(dot + 1);
  }
}

}  // namespace

bool ParseUrl(std::string_view url, ParsedUrl* out) {
  *out = ParsedUrl();
  const size_t colon = url.find(':');
  if (colon == std::string_view::npos || colon == 0) return false;
  for (char c : url.substr(0, colon)) {
    if (!IsAlnum(c) && c != '+' && c != '-' && c != '.') return false;
  }
  out->scheme = LowerAscii(url.substr(0, colon));
  std::string_view rest = url.substr(colon + 1);
  if (rest.substr(0, 2) == "//") {
    rest.remove_prefix(2);
    const size_t authority_end = rest.find_first_of("/?#");
    std::string_view authority = rest.substr(0, authority_end);
    rest = authority_end == std::string_view::npos ? std::string_view() : rest.substr(authority_end);
    const size_t at = authority.rfind('@');
    if (at != std::string_view::npos) {
      out->has_userinfo = true;
      authority.remove_prefix(at + 1);
    }
    size_t host_end;
    if (!authority.empty() && authority.front() == '[') {
      host_end = authority.find(']');
      if (host_end == std::string_view::npos) return false;
      ++host_end;
    } else {
      host_end = authority.find(':');
      if (host_end == std::string_view::npos) host_end = authority.size();
    }
    out->host = LowerAscii(authority.substr(0, host_end));
    out->has_port = host_end < authority.size();
  }
  const size_t fragment = rest.find('#');
  std::string_view path_and_query = rest.substr(0, fragment);
  if (path_and_query.empty() || path_and_query.front() == '?') {
    out->path_and_query = "/" + std::string(path_and_query);
  } else {
    out->path_and_query = std::string(path_and_query);
  }
  out->path = out->path_and_query.substr(0, out->path_and_query.find('?'));
  return true;
}

bool HostAllowed(std::string_view host) {
  for (const char* pattern : railgun_page::kHosts) {
    if (Matches(pattern, host)) return true;
  }
  return false;
}

Route RouteOf(const ParsedUrl& url, std::string_view method) {
  // Never leave the page; the CSP governs them.
  if (url.scheme == "blob" || url.scheme == "data") return Route::kAllowed;
  if (url.has_userinfo || url.has_port) return Route::kBlocked;
  if (url.scheme == railgun_page::kScheme) {
    return url.host == railgun_page::kHost ? Route::kOwnFile : Route::kBlocked;
  }
  if (url.scheme != "https" || url.host.empty()) return Route::kBlocked;
  if (url.host == kArchiveHost && method == "GET") return Route::kArchive;
  return HostAllowed(url.host) ? Route::kAllowed : Route::kBlocked;
}

std::wstring OwnFile(const std::wstring& root, const std::string& path, std::wstring* type) {
  if (root.empty() || path.size() < 2 || path.front() != '/') return std::wstring();
  const std::string relative = path.substr(1);
  for (char c : relative) {
    if (!IsAlnum(c) && c != '.' && c != '_' && c != '-' && c != '/') return std::wstring();
  }
  size_t start = 0;
  while (start <= relative.size()) {
    const size_t slash = relative.find('/', start);
    const std::string segment = relative.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
    if (segment.empty() || segment == "." || segment == "..") return std::wstring();
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  const size_t dot = relative.rfind('.');
  const std::string extension = dot == std::string::npos ? std::string() : LowerAscii(relative.substr(dot + 1));
  if (extension == "html") {
    *type = L"text/html; charset=utf-8";
  } else if (extension == "js") {
    *type = L"text/javascript; charset=utf-8";
  } else if (extension == "wasm") {
    *type = L"application/wasm";
  } else if (extension == "txt") {
    *type = L"text/plain; charset=utf-8";
  } else {
    return std::wstring();
  }
  std::wstring file = root;
  if (file.back() != L'\\') file.push_back(L'\\');
  for (char c : relative) file.push_back(c == '/' ? L'\\' : static_cast<wchar_t>(c));
  const DWORD attributes = ::GetFileAttributesW(file.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0) {
    return std::wstring();
  }
  return file;
}

}  // namespace railgun_windows
