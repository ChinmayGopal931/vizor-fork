#include "railgun_page/railgun_archive.h"

#include <algorithm>
#include <cstring>

#include "railgun_page/webkit_api.h"

namespace railgun_page {

const char kArchivePrelude[] = R"JS(
const archive = 'https://digest.anon.inc/';
const own = '/anon-archive/';
const marker = Symbol.for('veylor.railgunArchive');
const webkit = globalThis.webkit;
if (typeof webkit !== 'object' || webkit === null) return false;
if (globalThis[marker] === undefined) {
  const pageFetch = globalThis.fetch;
  if (typeof pageFetch !== 'function') return false;
  const routed = function (input, init) {
    const method = init?.method === undefined ? 'GET' : String(init.method).toUpperCase();
    if (typeof input === 'string' && method === 'GET' && input.startsWith(archive)) {
      return pageFetch.call(globalThis, own + input.slice(archive.length), init);
    }
    return pageFetch.call(globalThis, input, init);
  };
  Object.defineProperty(globalThis, 'fetch', { value: routed, writable: true, configurable: true });
}
try {
  Object.defineProperty(webkit, 'messageHandlers', { value: Object.freeze({}), configurable: true });
} catch {
  return false;
}
Object.defineProperty(globalThis, marker, { value: webkit, configurable: true });
return globalThis.webkit?.messageHandlers?.railgunHost === undefined;
)JS";

std::string ArchiveUpstream(const char* page_uri) {
  if (page_uri == nullptr) return std::string();
  g_autoptr(GUri) uri = g_uri_parse(page_uri, G_URI_FLAGS_ENCODED, nullptr);
  if (uri == nullptr) return std::string();
  if (g_strcmp0(g_uri_get_scheme(uri), "veylor-railgun") != 0 || g_strcmp0(g_uri_get_host(uri), "app") != 0 ||
      g_uri_get_fragment(uri) != nullptr) {
    return std::string();
  }
  const char* path = g_uri_get_path(uri);
  if (path == nullptr || !g_str_has_prefix(path, kArchivePath)) return std::string();
  const char* rest = path + std::strlen(kArchivePath);
  if (rest[0] == '\0' || rest[0] == '/') return std::string();
  std::string upstream = std::string("https://") + kArchiveHost + "/" + rest;
  if (const char* query = g_uri_get_query(uri)) upstream += std::string("?") + query;
  return upstream;
}

bool ArchiveServable(unsigned status) { return (status >= 200 && status <= 299) || (status >= 400 && status <= 599); }

void AnswerSchemeRequest(WebKitURISchemeRequest* request, unsigned status, const char* type, GBytes* body,
                         const char* content_security_policy) {
  const WebKitApi& wk = Wk();
  g_autoptr(GBytes) empty = g_bytes_new(nullptr, 0);
  GBytes* bytes = body != nullptr ? body : empty;
  g_autoptr(GInputStream) stream = g_memory_input_stream_new_from_bytes(bytes);
  WebKitURISchemeResponse* response =
      wk.webkit_uri_scheme_response_new(stream, static_cast<gint64>(g_bytes_get_size(bytes)));
  wk.webkit_uri_scheme_response_set_status(response, status, nullptr);
  wk.webkit_uri_scheme_response_set_content_type(response, type);
  SoupMessageHeaders* headers = wk.soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
  wk.soup_message_headers_append(headers, "Cache-Control", "no-store");
  if (content_security_policy != nullptr) {
    wk.soup_message_headers_append(headers, "Content-Security-Policy", content_security_policy);
  }
  // Takes the headers.
  wk.webkit_uri_scheme_response_set_http_headers(response, headers);
  wk.webkit_uri_scheme_request_finish_with_response(request, response);
  g_object_unref(response);
}

// One archive request on its way: the page's request, the archive's answer and its body so far, and the session
// (the connection pool) it went out on.
struct ArchiveFetch::Fetch {
  ArchiveFetch* owner;
  WebKitURISchemeRequest* request;
  SoupSession* session;
  SoupMessage* message;
  GCancellable* cancellable;
  GInputStream* body_stream = nullptr;
  GByteArray* body = nullptr;
  guint deadline = 0;
  unsigned status = 0;
  std::string type;
  bool abandoned = false;
};

namespace {

using Fetch = ArchiveFetch::Fetch;

// Ends `fetch`, answering the page unless it was abandoned. An answer read whole leaves its connection to the pool
// for the next request; any other end closes it first, cancelled so nothing more is read from it, and libsoup never
// uses it again: the page's next try goes out on another connection.
void Finish(Fetch* fetch, bool whole, unsigned status, const char* type, GBytes* body) {
  if (fetch->deadline != 0) g_source_remove(fetch->deadline);
  fetch->deadline = 0;
  if (fetch->body_stream != nullptr) {
    if (!whole) g_cancellable_cancel(fetch->cancellable);
    g_input_stream_close(fetch->body_stream, whole ? nullptr : fetch->cancellable, nullptr);
    g_object_unref(fetch->body_stream);
    fetch->body_stream = nullptr;
  }
  if (!fetch->abandoned) AnswerSchemeRequest(fetch->request, status, type, body, nullptr);
  if (fetch->owner != nullptr) fetch->owner->Remove(fetch);
  g_object_unref(fetch->message);
  g_object_unref(fetch->cancellable);
  g_object_unref(fetch->request);
  g_object_unref(fetch->session);
  if (fetch->body != nullptr) g_byte_array_unref(fetch->body);
  delete fetch;
}

void Fail(Fetch* fetch) { Finish(fetch, false, 502, "text/plain; charset=utf-8", nullptr); }

void OnRead(GObject* source, GAsyncResult* result, gpointer data) {
  auto* fetch = static_cast<Fetch*>(data);
  g_autoptr(GBytes) chunk = g_input_stream_read_bytes_finish(G_INPUT_STREAM(source), result, nullptr);
  if (chunk == nullptr || fetch->abandoned) {
    Fail(fetch);
    return;
  }
  const gsize size = g_bytes_get_size(chunk);
  if (size == 0) {
    g_autoptr(GBytes) body = g_byte_array_free_to_bytes(g_byte_array_ref(fetch->body));
    Finish(fetch, true, fetch->status, fetch->type.empty() ? "application/octet-stream" : fetch->type.c_str(), body);
    return;
  }
  if (fetch->body->len + size > kArchiveMaxBytes) {
    Fail(fetch);
    return;
  }
  g_byte_array_append(fetch->body, static_cast<const guint8*>(g_bytes_get_data(chunk, nullptr)), size);
  g_input_stream_read_bytes_async(fetch->body_stream, 64 * 1024, G_PRIORITY_DEFAULT, fetch->cancellable, OnRead,
                                  fetch);
}

void OnSent(GObject* source, GAsyncResult* result, gpointer data) {
  auto* fetch = static_cast<Fetch*>(data);
  const WebKitApi& wk = Wk();
  GInputStream* stream = wk.soup_session_send_finish(reinterpret_cast<SoupSession*>(source), result, nullptr);
  if (stream == nullptr || fetch->abandoned) {
    if (stream != nullptr) {
      fetch->body_stream = stream;
    }
    Fail(fetch);
    return;
  }
  fetch->body_stream = stream;
  fetch->status = wk.soup_message_get_status(fetch->message);
  SoupMessageHeaders* headers = wk.soup_message_get_response_headers(fetch->message);
  const bool declared = wk.soup_message_headers_get_encoding(headers) == SOUP_ENCODING_CONTENT_LENGTH;
  const goffset length = declared ? wk.soup_message_headers_get_content_length(headers) : 0;
  if (!ArchiveServable(fetch->status) || length > static_cast<goffset>(kArchiveMaxBytes)) {
    Fail(fetch);
    return;
  }
  // A body that says how long it is is kept in one piece, as Android's host sizes its buffer.
  fetch->body = g_byte_array_sized_new(length > 0 ? static_cast<guint>(length) : 64 * 1024);
  if (const char* type = wk.soup_message_headers_get_content_type(headers, nullptr)) fetch->type = type;
  g_input_stream_read_bytes_async(stream, 64 * 1024, G_PRIORITY_DEFAULT, fetch->cancellable, OnRead, fetch);
}

gboolean OnDeadline(gpointer data) {
  auto* fetch = static_cast<Fetch*>(data);
  fetch->deadline = 0;
  // The pending send or read then fails, and answers.
  g_cancellable_cancel(fetch->cancellable);
  return G_SOURCE_REMOVE;
}

}  // namespace

ArchiveFetch::ArchiveFetch(int bridge_port) : bridge_port_(bridge_port) {}

void ArchiveFetch::Remove(Fetch* fetch) {
  fetches_.erase(std::remove(fetches_.begin(), fetches_.end(), fetch), fetches_.end());
}

ArchiveFetch::~ArchiveFetch() {
  Close();
}

SoupSession* NewArchiveSession(int bridge_port) {
  const WebKitApi& wk = Wk();
  const std::string proxy = "socks5://127.0.0.1:" + std::to_string(bridge_port);
  g_autoptr(GProxyResolver) resolver = g_simple_proxy_resolver_new(proxy.c_str(), nullptr);
  SoupSession* session = wk.soup_session_new_with_options(
      "proxy-resolver", resolver, "timeout", kArchiveStallSeconds, "idle-timeout", kArchiveKeepAliveSeconds,
      "max-conns", static_cast<int>(kArchiveMaxConnections * 2), "max-conns-per-host",
      static_cast<int>(kArchiveMaxConnections), "user-agent", kArchiveUserAgent, "accept-language-auto", FALSE,
      nullptr);
  if (session == nullptr) return nullptr;
  // The files are checked against the archive's checksums as served: never unzipped, sniffed or authenticated.
  wk.soup_session_remove_feature_by_type(session, wk.soup_content_decoder_get_type());
  wk.soup_session_remove_feature_by_type(session, wk.soup_content_sniffer_get_type());
  wk.soup_session_remove_feature_by_type(session, wk.soup_auth_manager_get_type());
  return session;
}

SoupMessage* NewArchiveMessage(const char* upstream) {
  const WebKitApi& wk = Wk();
  SoupMessage* message = wk.soup_message_new("GET", upstream);
  if (message == nullptr) return nullptr;
  wk.soup_message_set_flags(message, SOUP_MESSAGE_NO_REDIRECT);
  // HTTP/1.1, as Android's HttpURLConnection speaks: one request per connection at a time, never multiplexed. libsoup
  // offers HTTP/2 only on a direct connection, never through a proxy (`new_tls_connection` in 3.0.7, 3.2.2 and 3.4.4),
  // so the bridge's route alone gives HTTP/1.1; the call, where libsoup has it (3.4 and later), keeps it so whatever
  // a later libsoup offers.
  if (wk.soup_message_set_force_http1 != nullptr) wk.soup_message_set_force_http1(message, TRUE);
  SoupMessageHeaders* headers = wk.soup_message_get_request_headers(message);
  wk.soup_message_headers_replace(headers, "Accept-Encoding", "identity");
  wk.soup_message_headers_replace(headers, "Connection", "Keep-Alive");
  return message;
}

// The connections' pool: a session, through the bridge alone (no direct route to fall back on), with no cache, cookie
// or credential store. A change of network makes the next request start a new one, so no connection made before is
// used again; requests in flight finish on theirs, and the old pool goes with the last of them.
SoupSession* ArchiveFetch::Session() {
  if (network_changed_handler_ == 0) {
    GNetworkMonitor* monitor = g_network_monitor_get_default();
    network_changed_handler_ = g_signal_connect(monitor, "network-changed", G_CALLBACK(OnNetworkChanged), this);
  }
  if (session_ == nullptr) session_ = NewArchiveSession(bridge_port_);
  return session_;
}

void ArchiveFetch::OnNetworkChanged(GNetworkMonitor*, gboolean, gpointer data) {
  auto* self = static_cast<ArchiveFetch*>(data);
  if (self->session_ != nullptr) g_object_unref(self->session_);
  self->session_ = nullptr;
}

void ArchiveFetch::Start(WebKitURISchemeRequest* request) {
  const WebKitApi& wk = Wk();
  const char* method = wk.webkit_uri_scheme_request_get_http_method(request);
  if (method != nullptr && g_ascii_strcasecmp(method, "GET") != 0) {
    AnswerSchemeRequest(request, 405, "text/plain; charset=utf-8", nullptr, nullptr);
    return;
  }
  const std::string upstream = ArchiveUpstream(wk.webkit_uri_scheme_request_get_uri(request));
  if (!enabled_ || closed_ || upstream.empty()) {
    AnswerSchemeRequest(request, 404, "text/plain; charset=utf-8", nullptr, nullptr);
    return;
  }
  SoupSession* session = Session();
  SoupMessage* message = session != nullptr ? NewArchiveMessage(upstream.c_str()) : nullptr;
  if (message == nullptr) {
    AnswerSchemeRequest(request, 502, "text/plain; charset=utf-8", nullptr, nullptr);
    return;
  }
  auto* fetch = new Fetch{this, static_cast<WebKitURISchemeRequest*>(g_object_ref(request)),
                          static_cast<SoupSession*>(g_object_ref(session)), message, g_cancellable_new()};
  fetch->deadline = g_timeout_add_seconds(kArchiveDeadlineSeconds, OnDeadline, fetch);
  fetches_.push_back(fetch);
  wk.soup_session_send_async(session, message, G_PRIORITY_DEFAULT, fetch->cancellable, OnSent, fetch);
}

void ArchiveFetch::Close() {
  closed_ = true;
  enabled_ = false;
  if (network_changed_handler_ != 0) {
    g_signal_handler_disconnect(g_network_monitor_get_default(), network_changed_handler_);
    network_changed_handler_ = 0;
  }
  // Each fetch ends once its cancelled step returns, and a closed page reads none of them; every connection, kept ones
  // included, closes with its pool.
  std::vector<Fetch*> fetches = fetches_;
  for (Fetch* fetch : fetches) {
    fetch->abandoned = true;
    fetch->owner = nullptr;
    g_cancellable_cancel(fetch->cancellable);
    Wk().soup_session_abort(fetch->session);
  }
  fetches_.clear();
  if (session_ != nullptr) {
    Wk().soup_session_abort(session_);
    g_object_unref(session_);
    session_ = nullptr;
  }
}

}  // namespace railgun_page
