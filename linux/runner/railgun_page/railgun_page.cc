#include "railgun_page/railgun_page.h"

#include <dirent.h>
#include <glib-unix.h>
#include <gtk/gtk.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>

#include "private_usd/railgun_frames.h"
#include "railgun_page/railgun_archive.h"
#include "railgun_page/railgun_endpoints.h"
#include "railgun_page/webkit_api.h"

namespace railgun_page {
namespace {

// The page's hello, `emit('ready', null)` in index.js, as JSON.stringify writes it.
constexpr char kReady[] = "{\"event\":\"ready\",\"data\":null}";
// Delivers one message as a `callAsyncJavaScript` argument, never spliced into the script; it returns at once.
constexpr char kDeliveryScript[] = "__railgunHostDeliver(m); return true;";
constexpr char kMessageHandler[] = "railgunHost";
constexpr char kFilterIdentifier[] = "railgun-allowlist";
constexpr guint kProbeTimeoutSeconds = 20;
// How much of the volume the page's one origin may keep. WebKitGTK's own quota for an origin is 1 GiB
// (`origin-storage-ratio` -1.0), and a write past it fails with a QuotaExceededError: Railgun's mainnet store, its notes
// trees, its transaction list and their records, passes 2 GB, and from there every scan's write failed, so every
// refresh did. 60% is what an origin may keep in Chromium, which Android's page runs on. The total is left unlimited
// (`total-storage-ratio` -1.0): a total reached evicts, which would take the page's store.
constexpr double kOriginStorageRatio = 0.6;
// What the page's own requests (the RPC, rail-squid, the screening node, the artifacts) say they come from: the same
// on every computer. WebKitGTK's own names the distribution and the processor; this one, like the Mac's WebKit,
// which freezes its OS version and names no model, names neither, and claims one platform for all.
constexpr char kPageUserAgent[] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko)";
// The check's page, on the page's own secure scheme: it must have what the page needs.
constexpr char kProbeUrl[] = "veylor-railgun://app/probe.html";
constexpr char kProbePage[] = "<!doctype html><meta charset=utf-8><title></title>";
constexpr char kProbeScript[] =
    "isSecureContext && typeof crypto?.subtle?.digest === 'function' && typeof WebAssembly === 'object' && "
    "typeof indexedDB === 'object' && typeof localStorage === 'object' && typeof Worker === 'function'";

// The link's descriptor, for the fatal path, where nothing else may run.
int g_link_fd = -1;
bool g_probing = false;
// The page said it was ready from inside WebKit's sandbox: a fatal error after that is not a sandbox that did not
// start, and must not read as one (Veylor would take this page as unable to run here).
bool g_page_ran = false;

void WriteAll(int fd, const char* data, size_t length) {
  while (length > 0) {
    const ssize_t written = write(fd, data, length);
    if (written <= 0) return;
    data += written;
    length -= static_cast<size_t>(written);
  }
}

// Ends the process after a fatal error once the page ran inside the sandbox: a stop, as a crash would be, said as one.
[[noreturn]] void ExitFatal() {
  static const char kLine[] = "veylor-railgun-page: a fatal error stopped the page\n";
  WriteAll(STDERR_FILENO, kLine, sizeof(kLine) - 1);
  if (g_link_fd >= 0) {
    static const char kReason[] = "the page's host process stopped";
    const uint32_t length = sizeof(kReason) - 1 + 2;
    std::string frame = {static_cast<char>((length >> 24) & 0xFF), static_cast<char>((length >> 16) & 0xFF),
                         static_cast<char>((length >> 8) & 0xFF), static_cast<char>(length & 0xFF),
                         railgun_frames::kClosed, railgun_frames::kClosedDisconnected};
    frame += kReason;
    send(g_link_fd, frame.data(), frame.size(), MSG_NOSIGNAL);
  }
  _exit(kExitFatal);
}

// GLib's messages could quote what WebKit loaded, so none is printed; this process's own lines are `Log`'s. An error
// is fatal: WebKit raises one for a sandbox that can't start (bubblewrap or its D-Bus proxy refused), and GLib would
// then abort the process, leaving a crash report. Before the page ran inside the sandbox (and always in the check),
// it becomes `kExitSandbox` instead, after telling Veylor; after, the sandbox had started, and it is a stop
// (`ExitFatal`), which Veylor answers by reopening the page on its next use.
GLogWriterOutput WriteLog(GLogLevelFlags level, const GLogField* fields, gsize count, gpointer) {
  if ((level & G_LOG_LEVEL_ERROR) == 0) return G_LOG_WRITER_HANDLED;
  if (g_page_ran && !g_probing) ExitFatal();
  std::string line = "veylor-railgun-page: the WebKit sandbox did not start";
  if (g_probing) {
    for (gsize i = 0; i < count; ++i) {
      if (std::strcmp(fields[i].key, "MESSAGE") == 0 && fields[i].length < 0) {
        line += ": ";
        line += static_cast<const char*>(fields[i].value);
      }
    }
  }
  line += "\n";
  WriteAll(STDERR_FILENO, line.data(), line.size());
  if (g_link_fd >= 0) {
    static const char kReason[] = "the page's sandbox did not start";
    const uint32_t length = sizeof(kReason) - 1 + 2;
    std::string frame = {static_cast<char>((length >> 24) & 0xFF), static_cast<char>((length >> 16) & 0xFF),
                         static_cast<char>((length >> 8) & 0xFF), static_cast<char>(length & 0xFF),
                         railgun_frames::kClosed, railgun_frames::kClosedUnavailable};
    frame += kReason;
    send(g_link_fd, frame.data(), frame.size(), MSG_NOSIGNAL);
  }
  _exit(kExitSandbox);
}

// MARK: The sandbox

enum class Sandbox { kInside, kOutside, kNoWebProcess };

// Whether this process's web processes run inside bubblewrap. WebKit starts each through `bwrap`, so a web process
// that is a direct child of this one ran without its sandbox; a WebKit built without the sandbox, or one that turned
// it off, starts it so. The network process is never in bubblewrap, on any distribution.
Sandbox CheckSandbox() {
  const pid_t self = getpid();
  bool bwrap = false;
  bool outside = false;
  DIR* proc = opendir("/proc");
  if (proc == nullptr) return Sandbox::kNoWebProcess;
  while (dirent* entry = readdir(proc)) {
    if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
    g_autofree gchar* path = g_build_filename("/proc", entry->d_name, "stat", nullptr);
    gchar* contents = nullptr;
    if (!g_file_get_contents(path, &contents, nullptr, nullptr)) continue;
    g_autofree gchar* stat = contents;
    // "pid (comm) state ppid …", where comm may hold spaces and parentheses.
    const char* open = std::strchr(stat, '(');
    const char* close = std::strrchr(stat, ')');
    if (open == nullptr || close == nullptr || close < open) continue;
    char state = 0;
    int parent = 0;
    if (std::sscanf(close + 1, " %c %d", &state, &parent) != 2 || parent != self) continue;
    const std::string comm(open + 1, static_cast<size_t>(close - open - 1));
    if (comm == "bwrap") bwrap = true;
    if (comm.rfind("WebKitWebProces", 0) == 0) outside = true;
  }
  closedir(proc);
  if (outside) return Sandbox::kOutside;
  return bwrap ? Sandbox::kInside : Sandbox::kNoWebProcess;
}

// MARK: The web view

// The settings the page runs with: script on, nothing it does not use (media, WebGL, WebRTC, audio, fullscreen,
// images, prefetching), no GPU (the page draws nothing). Set one by one, so a property an older WebKit lacks is
// skipped rather than ending the list.
GObject* NewSettings(bool debug) {
  const WebKitApi& wk = Wk();
  GObject* settings = static_cast<GObject*>(g_object_new(wk.webkit_settings_get_type(), nullptr));
  GObjectClass* klass = G_OBJECT_GET_CLASS(settings);
  auto flag = [&](const char* name, gboolean value) {
    if (g_object_class_find_property(klass, name) != nullptr) g_object_set(settings, name, value, nullptr);
  };
  flag("enable-javascript", TRUE);
  flag("javascript-can-open-windows-automatically", FALSE);
  flag("javascript-can-access-clipboard", FALSE);
  flag("enable-webgl", FALSE);
  flag("enable-webaudio", FALSE);
  flag("enable-webrtc", FALSE);
  flag("enable-media-stream", FALSE);
  flag("enable-media", FALSE);
  flag("enable-mediasource", FALSE);
  flag("enable-encrypted-media", FALSE);
  flag("enable-media-capabilities", FALSE);
  flag("media-playback-requires-user-gesture", TRUE);
  flag("enable-page-cache", FALSE);
  flag("enable-dns-prefetching", FALSE);
  flag("enable-hyperlink-auditing", FALSE);
  flag("enable-site-specific-quirks", FALSE);
  flag("enable-fullscreen", FALSE);
  flag("auto-load-images", FALSE);
  flag("enable-back-forward-navigation-gestures", FALSE);
  flag("allow-file-access-from-file-urls", FALSE);
  flag("allow-universal-access-from-file-urls", FALSE);
  flag("enable-write-console-messages-to-stdout", FALSE);
  flag("enable-developer-extras", debug ? TRUE : FALSE);
  if (g_object_class_find_property(klass, "user-agent") != nullptr) {
    g_object_set(settings, "user-agent", kPageUserAgent, nullptr);
  }
  if (g_object_class_find_property(klass, "hardware-acceleration-policy") != nullptr) {
    g_object_set(settings, "hardware-acceleration-policy", WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER, nullptr);
  }
  return settings;
}

// A context of its own: its data store, its proxy, the only route out (no direct fallback), and WebKit's sandbox,
// which is never off.
WebKitWebContext* NewContext(WebKitWebsiteDataManager* manager, int proxy_port) {
  const WebKitApi& wk = Wk();
  const std::string proxy = "socks5://127.0.0.1:" + std::to_string(proxy_port);
  WebKitNetworkProxySettings* settings = wk.webkit_network_proxy_settings_new(proxy.c_str(), nullptr);
  wk.webkit_website_data_manager_set_network_proxy_settings(manager, WEBKIT_NETWORK_PROXY_MODE_CUSTOM, settings);
  wk.webkit_network_proxy_settings_free(settings);
  WebKitWebContext* context = wk.webkit_web_context_new_with_website_data_manager(manager);
  wk.webkit_web_context_set_sandbox_enabled(context, TRUE);
  wk.webkit_web_context_set_cache_model(context, WEBKIT_CACHE_MODEL_DOCUMENT_VIEWER);
  return context;
}

gboolean Handled(GtkWidget*, gpointer) { return TRUE; }

gboolean DenyPermission(WebKitWebView*, WebKitPermissionRequest* request, gpointer) {
  Wk().webkit_permission_request_deny(request);
  return TRUE;
}

gboolean CancelFileChooser(WebKitWebView*, WebKitFileChooserRequest* request, gpointer) {
  Wk().webkit_file_chooser_request_cancel(request);
  return TRUE;
}

gboolean CancelAuthentication(WebKitWebView*, WebKitAuthenticationRequest* request, gpointer) {
  Wk().webkit_authentication_request_cancel(request);
  return TRUE;
}

void CancelDownload(WebKitWebContext*, WebKitDownload* download, gpointer) { Wk().webkit_download_cancel(download); }

// The page's web view, 1×1 in an offscreen window: it takes no pointer, keyboard, focus or accessibility (the
// process runs with NO_AT_BRIDGE), opens no dialog, window, file picker, download, notification, print or sign-in,
// and draws nothing. WebKit runs it unthrottled while the window is shown and treats it as hidden while it is not,
// which Veylor's host sets from its own window.
GtkWidget* NewView(WebKitWebContext* context, WebKitUserContentManager* content, bool debug, GtkWidget** window) {
  const WebKitApi& wk = Wk();
  GObject* settings = NewSettings(debug);
  GtkWidget* view = static_cast<GtkWidget*>(g_object_new(wk.webkit_web_view_get_type(), "web-context", context,
                                                         "user-content-manager", content, "settings", settings,
                                                         nullptr));
  g_object_unref(settings);
  const GdkRGBA clear = {0, 0, 0, 0};
  wk.webkit_web_view_set_background_color(reinterpret_cast<WebKitWebView*>(view), &clear);
  gtk_widget_set_can_focus(view, FALSE);
  gtk_widget_set_size_request(view, 1, 1);
  g_signal_connect(view, "script-dialog", G_CALLBACK(Handled), nullptr);
  g_signal_connect(view, "context-menu", G_CALLBACK(Handled), nullptr);
  g_signal_connect(view, "show-notification", G_CALLBACK(Handled), nullptr);
  g_signal_connect(view, "enter-fullscreen", G_CALLBACK(Handled), nullptr);
  g_signal_connect(view, "print", G_CALLBACK(Handled), nullptr);
  g_signal_connect(view, "permission-request", G_CALLBACK(DenyPermission), nullptr);
  g_signal_connect(view, "run-file-chooser", G_CALLBACK(CancelFileChooser), nullptr);
  g_signal_connect(view, "authenticate", G_CALLBACK(CancelAuthentication), nullptr);
  g_signal_connect(context, "download-started", G_CALLBACK(CancelDownload), nullptr);
  *window = gtk_offscreen_window_new();
  gtk_window_set_default_size(GTK_WINDOW(*window), 1, 1);
  gtk_container_add(GTK_CONTAINER(*window), view);
  gtk_widget_show_all(*window);
  return view;
}

// MARK: The page

struct Delivery {
  int64_t id;
  uint8_t flags;
  std::string request;
};

class Page;
// The one page of this process; it outlives every callback of its view, since the process exits with it.
Page* g_page = nullptr;

class Page {
 public:
  explicit Page(const PageOptions& options)
      : options_(options), csp_(ContentSecurityPolicy()), archive_(options.proxy_port) {}

  void Start();

  // Tells Veylor the page closed and why, then exits.
  [[noreturn]] void CloseWith(char kind, const char* reason, int status);
  [[noreturn]] void Shutdown();

 private:
  void OnFrame(char type, std::string payload);
  void Pump();
  void Send(const Delivery& delivery);
  void Serve(WebKitURISchemeRequest* request);
  void Refuse(WebKitURISchemeRequest* request, unsigned status);
  void Received(WebKitJavascriptResult* result);
  bool OwnPage() const;

  static void OnScheme(WebKitURISchemeRequest* request, gpointer data);
  static void OnFilterSaved(GObject* source, GAsyncResult* result, gpointer data);
  static void OnMessage(WebKitUserContentManager*, WebKitJavascriptResult* result, gpointer data);
  static gboolean OnDecidePolicy(WebKitWebView*, WebKitPolicyDecision* decision, WebKitPolicyDecisionType type,
                                 gpointer data);
  static gboolean OnLoadFailed(WebKitWebView*, WebKitLoadEvent, gchar*, GError*, gpointer data);
  static void OnProcessTerminated(WebKitWebView*, WebKitWebProcessTerminationReason, gpointer data);
  static void OnPrelude(GObject* source, GAsyncResult* result, gpointer data);
  static void OnDelivered(GObject* source, GAsyncResult* result, gpointer data);
  static gboolean OnTerminate(gpointer data);

  PageOptions options_;
  std::string csp_;
  ArchiveFetch archive_;
  std::unique_ptr<railgun_frames::Channel> link_;
  WebKitWebContext* context_ = nullptr;
  WebKitUserContentManager* content_ = nullptr;
  GtkWidget* view_ = nullptr;
  GtkWidget* window_ = nullptr;
  bool navigated_ = false;
  bool ready_ = false;
  bool closing_ = false;
  std::deque<Delivery> queue_;
  bool busy_ = false;
  std::string base_;
};

void Page::Start() {
  link_ = std::make_unique<railgun_frames::Channel>(
      options_.link_fd, [this](char type, std::string payload) { OnFrame(type, std::move(payload)); },
      [this]() { Shutdown(); });
  g_unix_signal_add(SIGTERM, OnTerminate, this);
  g_autofree char* base = realpath(options_.bundle_dir.c_str(), nullptr);
  if (base == nullptr) CloseWith(railgun_frames::kClosedUnavailable, "the page's files are missing", kExitPageFailed);
  base_ = base;

  const WebKitApi& wk = Wk();
  g_autofree gchar* data = g_build_filename(options_.data_dir.c_str(), "data", nullptr);
  g_autofree gchar* cache = g_build_filename(options_.data_dir.c_str(), "cache", nullptr);
  // WebKitGTK 2.42 has the ratio, and the page runs on 2.44 or later (`LoadWebKit`).
  WebKitWebsiteDataManager* manager =
      wk.webkit_website_data_manager_new("base-data-directory", data, "base-cache-directory", cache,
                                         "origin-storage-ratio", kOriginStorageRatio, nullptr);
  context_ = NewContext(manager, options_.proxy_port);
  g_object_unref(manager);
  if (!wk.webkit_web_context_get_sandbox_enabled(context_)) {
    CloseWith(railgun_frames::kClosedUnavailable, "the page's sandbox is off", kExitSandbox);
  }
  wk.webkit_web_context_register_uri_scheme(context_, kScheme, OnScheme, this, nullptr);
  WebKitSecurityManager* security = wk.webkit_web_context_get_security_manager(context_);
  wk.webkit_security_manager_register_uri_scheme_as_secure(security, kScheme);
  wk.webkit_security_manager_register_uri_scheme_as_cors_enabled(security, kScheme);

  content_ = wk.webkit_user_content_manager_new();
  // No user script: nothing is injected into the page as it loads. Only a start that reads Anon's archive runs the
  // prelude first.
  g_signal_connect(content_, "script-message-received::railgunHost", G_CALLBACK(OnMessage), this);
  if (!wk.webkit_user_content_manager_register_script_message_handler(content_, kMessageHandler)) {
    CloseWith(railgun_frames::kClosedUnavailable, "the page's message handler was refused", kExitPageFailed);
  }
  view_ = NewView(context_, content_, options_.debug, &window_);
  g_signal_connect(view_, "decide-policy", G_CALLBACK(OnDecidePolicy), this);
  g_signal_connect(view_, "load-failed", G_CALLBACK(OnLoadFailed), this);
  g_signal_connect(view_, "web-process-terminated", G_CALLBACK(OnProcessTerminated), this);

  // Compiled again by each page process, replacing the list stored under the same identifier.
  g_autofree gchar* filters = g_build_filename(options_.data_dir.c_str(), "filters", nullptr);
  WebKitUserContentFilterStore* store = wk.webkit_user_content_filter_store_new(filters);
  const std::string rules = ContentRules();
  g_autoptr(GBytes) source = g_bytes_new(rules.data(), rules.size());
  wk.webkit_user_content_filter_store_save(store, kFilterIdentifier, source, nullptr, OnFilterSaved, this);
  g_object_unref(store);
}

void Page::OnFilterSaved(GObject* source, GAsyncResult* result, gpointer data) {
  auto* self = static_cast<Page*>(data);
  const WebKitApi& wk = Wk();
  WebKitUserContentFilter* filter = wk.webkit_user_content_filter_store_save_finish(
      reinterpret_cast<WebKitUserContentFilterStore*>(source), result, nullptr);
  if (filter == nullptr) {
    self->CloseWith(railgun_frames::kClosedUnavailable, "the page's content rules did not compile", kExitPageFailed);
  }
  wk.webkit_user_content_manager_add_filter(self->content_, filter);
  wk.webkit_user_content_filter_unref(filter);
  wk.webkit_web_view_load_uri(reinterpret_cast<WebKitWebView*>(self->view_), kPageUrl);
}

void Page::OnFrame(char type, std::string payload) {
  switch (type) {
    case railgun_frames::kDeliver: {
      int64_t id = 0;
      if (!railgun_frames::DecodeId(payload, 0, &id) || payload.size() < 9) return;
      queue_.push_back(Delivery{id, static_cast<uint8_t>(payload[8]), payload.substr(9)});
      Pump();
      break;
    }
    case railgun_frames::kVisible:
      if (payload.empty() || window_ == nullptr) return;
      if (payload[0] != '\0') {
        gtk_widget_show_all(window_);
      } else {
        gtk_widget_hide(window_);
      }
      break;
    case railgun_frames::kQuit:
      Shutdown();
      break;
    default:
      break;
  }
}

// Requests reach the page in the order Veylor sent them; a `start` that reads the archive waits for its prelude.
void Page::Pump() {
  while (!busy_ && !queue_.empty()) {
    Delivery delivery = std::move(queue_.front());
    queue_.pop_front();
    if (delivery.flags & railgun_frames::kDeliverPrepareArchive) {
      busy_ = true;
      Wk().webkit_web_view_call_async_javascript_function(reinterpret_cast<WebKitWebView*>(view_), kArchivePrelude,
                                                         -1, nullptr, nullptr, nullptr, nullptr, OnPrelude,
                                                         new Delivery(std::move(delivery)));
      return;
    }
    Send(delivery);
  }
}

// The prelude took, so the page's start reads the archive; one that did not leaves the page as on iOS, syncing from
// rail-squid alone.
void Page::OnPrelude(GObject* source, GAsyncResult* result, gpointer data) {
  std::unique_ptr<Delivery> delivery(static_cast<Delivery*>(data));
  Page* self = g_page;
  const WebKitApi& wk = Wk();
  JSCValue* value = wk.webkit_web_view_call_async_javascript_function_finish(reinterpret_cast<WebKitWebView*>(source),
                                                                             result, nullptr);
  if (value != nullptr) {
    if (wk.jsc_value_is_boolean(value) && wk.jsc_value_to_boolean(value)) self->archive_.Enable();
    g_object_unref(value);
  }
  self->Send(*delivery);
  self->busy_ = false;
  self->Pump();
}

void Page::Send(const Delivery& delivery) {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&builder, "{sv}", "m", g_variant_new_string(delivery.request.c_str()));
  Wk().webkit_web_view_call_async_javascript_function(reinterpret_cast<WebKitWebView*>(view_), kDeliveryScript, -1,
                                                     g_variant_builder_end(&builder), nullptr, nullptr, nullptr,
                                                     OnDelivered, new int64_t(delivery.id));
}

void Page::OnDelivered(GObject* source, GAsyncResult* result, gpointer data) {
  std::unique_ptr<int64_t> id(static_cast<int64_t*>(data));
  JSCValue* value = Wk().webkit_web_view_call_async_javascript_function_finish(
      reinterpret_cast<WebKitWebView*>(source), result, nullptr);
  if (value != nullptr) {
    g_object_unref(value);
    return;
  }
  if (g_page != nullptr && g_page->link_ != nullptr) {
    g_page->link_->Send(railgun_frames::kUndelivered, railgun_frames::EncodeId(*id));
  }
}

// Only the page itself talks to the host: the handler is in the page's world alone, the page has no frames (its CSP
// allows none) and navigates nowhere after its first load.
bool Page::OwnPage() const {
  return g_strcmp0(Wk().webkit_web_view_get_uri(reinterpret_cast<WebKitWebView*>(view_)), kPageUrl) == 0;
}

void Page::OnMessage(WebKitUserContentManager*, WebKitJavascriptResult* result, gpointer data) {
  static_cast<Page*>(data)->Received(result);
}

void Page::Received(WebKitJavascriptResult* result) {
  if (closing_ || !OwnPage()) return;
  const WebKitApi& wk = Wk();
  JSCValue* value = wk.webkit_javascript_result_get_js_value(result);
  if (value == nullptr || !wk.jsc_value_is_string(value)) return;
  g_autofree char* text = wk.jsc_value_to_string(value);
  if (text == nullptr) return;
  if (!ready_ && std::strcmp(text, kReady) == 0) {
    ready_ = true;
    // The page ran script, so its web process is up: it must be inside the sandbox, or the page goes.
    if (CheckSandbox() != Sandbox::kInside) {
      CloseWith(railgun_frames::kClosedUnavailable, "the page ran outside WebKit's sandbox", kExitSandbox);
    } else {
      g_page_ran = true;
    }
  }
  link_->Send(railgun_frames::kMessage, text);
}

// MARK: The page's files

void Page::OnScheme(WebKitURISchemeRequest* request, gpointer data) { static_cast<Page*>(data)->Serve(request); }

// `veylor-railgun://app/<path>` from the bundle's `data/railgun/` and nothing else: no path outside it, no directory,
// only GET, and only the types the page loads; under `kArchivePath`, Anon's archive.
void Page::Serve(WebKitURISchemeRequest* request) {
  const WebKitApi& wk = Wk();
  const char* path = wk.webkit_uri_scheme_request_get_path(request);
  if (path == nullptr) path = "";
  if (g_str_has_prefix(path, kArchivePath)) {
    archive_.Start(request);
    return;
  }
  const char* method = wk.webkit_uri_scheme_request_get_http_method(request);
  if (method != nullptr && g_ascii_strcasecmp(method, "GET") != 0) {
    Refuse(request, 405);
    return;
  }
  while (*path == '/') ++path;
  if (*path == '\0') {
    Refuse(request, 404);
    return;
  }
  g_autofree gchar* joined = g_build_filename(base_.c_str(), path, nullptr);
  g_autofree char* file = realpath(joined, nullptr);
  struct stat info;
  if (file == nullptr || !g_str_has_prefix(file, (base_ + "/").c_str()) || stat(file, &info) != 0 ||
      !S_ISREG(info.st_mode)) {
    Refuse(request, 404);
    return;
  }
  // The types the page loads; anything else is refused. `instantiateStreaming` needs `application/wasm`.
  const char* type = nullptr;
  if (g_str_has_suffix(file, ".html")) {
    type = "text/html; charset=utf-8";
  } else if (g_str_has_suffix(file, ".js")) {
    type = "text/javascript; charset=utf-8";
  } else if (g_str_has_suffix(file, ".wasm")) {
    type = "application/wasm";
  } else if (g_str_has_suffix(file, ".txt")) {
    type = "text/plain; charset=utf-8";
  }
  GMappedFile* mapped = type != nullptr ? g_mapped_file_new(file, FALSE, nullptr) : nullptr;
  if (mapped == nullptr) {
    Refuse(request, 404);
    return;
  }
  g_autoptr(GBytes) body = g_mapped_file_get_bytes(mapped);
  g_mapped_file_unref(mapped);
  AnswerSchemeRequest(request, 200, type, body, csp_.c_str());
}

// Without its own files the page never answers, so Veylor does not wait out the load for it.
void Page::Refuse(WebKitURISchemeRequest* request, unsigned status) {
  AnswerSchemeRequest(request, status, "text/plain; charset=utf-8", nullptr, nullptr);
  if (ready_) return;
  // After the answer: nothing closes the page inside WebKit's callback.
  g_idle_add(
      [](gpointer data) -> gboolean {
        static_cast<Page*>(data)->CloseWith(railgun_frames::kClosedDisconnected, "one of the page's files did not load",
                                            kExitPageFailed);
      },
      this);
}

// MARK: Navigation and the end

// Only the page's own first load; nothing navigates it after that, and it opens no window.
gboolean Page::OnDecidePolicy(WebKitWebView*, WebKitPolicyDecision* decision, WebKitPolicyDecisionType type,
                              gpointer data) {
  auto* self = static_cast<Page*>(data);
  const WebKitApi& wk = Wk();
  if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
    WebKitNavigationAction* action = wk.webkit_navigation_policy_decision_get_navigation_action(
        reinterpret_cast<WebKitNavigationPolicyDecision*>(decision));
    const char* uri = wk.webkit_uri_request_get_uri(wk.webkit_navigation_action_get_request(action));
    const bool first = !self->navigated_ && g_strcmp0(uri, kPageUrl) == 0;
    if (first) {
      self->navigated_ = true;
      wk.webkit_policy_decision_use(decision);
    } else {
      wk.webkit_policy_decision_ignore(decision);
    }
    return TRUE;
  }
  if (type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
    wk.webkit_policy_decision_ignore(decision);
    return TRUE;
  }
  return FALSE;
}

gboolean Page::OnLoadFailed(WebKitWebView*, WebKitLoadEvent, gchar*, GError*, gpointer data) {
  auto* self = static_cast<Page*>(data);
  if (!self->ready_) self->CloseWith(railgun_frames::kClosedDisconnected, "the page did not load", kExitPageFailed);
  return TRUE;
}

// The content process died (Android's `onRenderProcessGone`): the page is gone, and Dart reopens it lazily.
void Page::OnProcessTerminated(WebKitWebView*, WebKitWebProcessTerminationReason, gpointer data) {
  static_cast<Page*>(data)->CloseWith(railgun_frames::kClosedDisconnected, "the page's content process stopped",
                                      kExitPageFailed);
}

gboolean Page::OnTerminate(gpointer data) { static_cast<Page*>(data)->Shutdown(); }

void Page::CloseWith(char kind, const char* reason, int status) {
  closing_ = true;
  if (link_ != nullptr) {
    std::string payload(1, kind);
    payload += reason;
    link_->Send(railgun_frames::kClosed, payload);
    // What the link still holds goes before the process does.
    link_->Drain();
  }
  archive_.Close();
  Log(std::string("page closed: ") + reason);
  // WebKit's own processes exit as their link to this one closes.
  link_.reset();
  _exit(status);
}

void Page::Shutdown() {
  closing_ = true;
  archive_.Close();
  link_.reset();
  _exit(kExitOk);
}

}  // namespace

void Log(const std::string& line) {
  const std::string text = "veylor-railgun-page: " + line + "\n";
  WriteAll(STDERR_FILENO, text.data(), text.size());
}

int RunPage(const PageOptions& options) {
  g_log_set_writer_func(WriteLog, nullptr, nullptr);
  g_link_fd = options.link_fd;
  static Page page(options);
  g_page = &page;
  page.Start();
  gtk_main();
  return kExitOk;
}

// MARK: The check

namespace {

struct Probe {
  GtkWidget* view = nullptr;
  GtkWidget* window = nullptr;
};

void ProbeLoaded(WebKitWebView* view, WebKitLoadEvent event, gpointer) {
  if (event != WEBKIT_LOAD_FINISHED) return;
  // The page's own needs (a secure context with `crypto.subtle`, WebAssembly, IndexedDB, `localStorage` and
  // workers), in a page whose web process is inside the sandbox.
  Wk().webkit_web_view_evaluate_javascript(
      view, kProbeScript, -1, nullptr, nullptr, nullptr,
      [](GObject* source, GAsyncResult* result, gpointer) {
        const WebKitApi& wk = Wk();
        JSCValue* value =
            wk.webkit_web_view_evaluate_javascript_finish(reinterpret_cast<WebKitWebView*>(source), result, nullptr);
        const bool capable = value != nullptr && wk.jsc_value_is_boolean(value) && wk.jsc_value_to_boolean(value);
        if (!capable) {
          Log("unavailable: the page's engine lacks a secure context, crypto.subtle, WebAssembly, storage or workers");
          _exit(kExitPageFailed);
        }
        if (CheckSandbox() != Sandbox::kInside) {
          Log("unavailable: WebKit's web process ran outside its sandbox");
          _exit(kExitSandbox);
        }
        Log("WebKitGTK " + std::to_string(wk.webkit_get_major_version()) + "." +
            std::to_string(wk.webkit_get_minor_version()) + "." + std::to_string(wk.webkit_get_micro_version()) +
            ": a sandboxed page ran");
        _exit(kExitOk);
      },
      nullptr);
}

}  // namespace

int RunProbe() {
  g_probing = true;
  g_log_set_writer_func(WriteLog, nullptr, nullptr);
  const WebKitApi& wk = Wk();
  // Nothing in the check's page reaches the network; its proxy goes nowhere.
  WebKitWebsiteDataManager* manager = wk.webkit_website_data_manager_new_ephemeral();
  WebKitWebContext* context = NewContext(manager, 1);
  g_object_unref(manager);
  if (!wk.webkit_web_context_get_sandbox_enabled(context)) {
    Log("unavailable: WebKit's sandbox is off");
    return kExitSandbox;
  }
  // The page's scheme, registered as the page's is, serving one empty page.
  wk.webkit_web_context_register_uri_scheme(
      context, kScheme,
      [](WebKitURISchemeRequest* request, gpointer) {
        g_autoptr(GBytes) page = g_bytes_new_static(kProbePage, sizeof(kProbePage) - 1);
        AnswerSchemeRequest(request, 200, "text/html; charset=utf-8", page, nullptr);
      },
      nullptr, nullptr);
  WebKitSecurityManager* security = wk.webkit_web_context_get_security_manager(context);
  wk.webkit_security_manager_register_uri_scheme_as_secure(security, kScheme);
  wk.webkit_security_manager_register_uri_scheme_as_cors_enabled(security, kScheme);
  WebKitUserContentManager* content = wk.webkit_user_content_manager_new();
  static Probe probe;
  probe.view = NewView(context, content, false, &probe.window);
  g_signal_connect(probe.view, "load-changed", G_CALLBACK(ProbeLoaded), nullptr);
  g_signal_connect(probe.view, "web-process-terminated",
                   G_CALLBACK(+[](WebKitWebView*, WebKitWebProcessTerminationReason, gpointer) {
                     Log("unavailable: WebKit's web process stopped");
                     _exit(kExitPageFailed);
                   }),
                   nullptr);
  wk.webkit_web_view_load_uri(reinterpret_cast<WebKitWebView*>(probe.view), kProbeUrl);
  g_timeout_add_seconds(
      kProbeTimeoutSeconds,
      [](gpointer) -> gboolean {
        Log("unavailable: the check's page did not load");
        _exit(kExitPageFailed);
      },
      nullptr);
  gtk_main();
  return kExitPageFailed;
}

}  // namespace railgun_page
