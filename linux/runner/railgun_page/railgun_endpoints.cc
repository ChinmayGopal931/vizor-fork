#include "railgun_page/railgun_endpoints.h"

#include <string_view>

namespace railgun_page {
namespace {

// `^https://host/`; for a `*.domain` entry, one label or more before the domain (letters, digits and hyphens, as
// hostnames are on the wire), never the domain itself. WebKit matches the rules regardless of case.
std::string Pattern(std::string_view host) {
  auto escaped = [](std::string_view part) {
    std::string out;
    for (char c : part) {
      if (c == '.') out += "\\";
      out.push_back(c);
    }
    return out;
  };
  if (host.substr(0, 2) == "*.") {
    return "^https://([a-z0-9]+(-+[a-z0-9]+)*\\.)+" + escaped(host.substr(2)) + "/";
  }
  return "^https://" + escaped(host) + "/";
}

// `text` as a JSON string; the patterns hold only ASCII, backslashes and quotes to escape.
std::string Json(std::string_view text) {
  std::string out = "\"";
  for (char c : text) {
    if (c == '\\' || c == '"') out.push_back('\\');
    out.push_back(c);
  }
  out.push_back('"');
  return out;
}

}  // namespace

std::string ContentSecurityPolicy() {
  std::string hosts;
  for (const char* host : kHosts) {
    if (!hosts.empty()) hosts += " ";
    hosts += "https://";
    hosts += host;
  }
  return "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src blob:; connect-src 'self' " + hosts +
         "; base-uri 'none'; form-action 'none'";
}

std::string ContentRules() {
  std::string rules = "[{\"action\":{\"type\":\"block\"},\"trigger\":{\"url-filter\":\".*\"}}";
  auto allow = [&rules](const std::string& pattern) {
    rules += ",{\"action\":{\"type\":\"ignore-previous-rules\"},\"trigger\":{\"url-filter\":" + Json(pattern) + "}}";
  };
  allow(std::string("^") + kScheme + "://" + kHost + "/");
  allow("^blob:");
  allow("^data:");
  for (const char* host : kHosts) allow(Pattern(host));
  rules += "]";
  return rules;
}

}  // namespace railgun_page
