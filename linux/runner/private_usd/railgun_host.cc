#include "private_usd/railgun_host.h"

#include <arpa/inet.h>
#include <errno.h>
#include <ftw.h>
#include <gio/gio.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "private_usd/railgun_frames.h"
#include "private_usd/railgun_protocol.h"

// Never log a call's params, its result or a failure's message: `start` carries keyed RPC URLs, `openWallet` and
// `deleteWallet` a mnemonic, and engine errors can quote either. What is logged is fixed text.

namespace {

using railgun_protocol::Error;
using railgun_protocol::Message;

constexpr size_t kEventBuffer = 256;
constexpr guint kLoadTimeoutSeconds = 30;
constexpr guint kProbeTimeoutSeconds = 30;
constexpr int kWipeAttempts = 5;
constexpr guint kWipeRetryMs = 500;
constexpr guint kQuitGraceMs = 2000;
// How long a page process waits after the one before it exited: WebKit's own processes exit as their link to it
// closes, a moment later, and two pages must never share the data store.
constexpr gint64 kAfterExitUs = 500 * 1000;
constexpr char kHelperName[] = "veylor-railgun-page";
// The page process's own diagnostic lines; whatever else WebKit prints there is dropped, since it could quote a URL.
constexpr char kLogPrefix[] = "veylor-railgun-page: ";
// The page process's exit status when WebKit's sandbox did not start (railgun_page/railgun_page_main.cc).
constexpr int kExitSandbox = 3;

// Whether this build may debug the page at all; `load`'s `debug` can only narrow it.
#ifdef NDEBUG
constexpr bool kDebuggable = false;
#else
constexpr bool kDebuggable = true;
#endif

// MARK: Answers

// Answers `call` once; `value` (transfer full) may be null.
void AnswerValue(FlMethodCall* call, FlValue* value) {
  g_autoptr(GError) error = nullptr;
  fl_method_call_respond_success(call, value, &error);
  if (value != nullptr) fl_value_unref(value);
}

void AnswerError(FlMethodCall* call, const Error& failure) {
  g_autoptr(GError) error = nullptr;
  fl_method_call_respond_error(call, failure.Code(), failure.message.c_str(), nullptr, &error);
}

void AnswerBadArgs(FlMethodCall* call, const char* what) {
  g_autoptr(GError) error = nullptr;
  fl_method_call_respond_error(call, "bad_args", what, nullptr, &error);
}

FlValue* Argument(FlMethodCall* call, const char* key) {
  FlValue* args = fl_method_call_get_args(call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  return fl_value_lookup_string(args, key);
}

// MARK: Places

// The directory Veylor's executable is in: the bundle's root, which holds the page process and `data/railgun`.
std::string ExecutableDirectory() {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) return std::string();
  g_autofree gchar* dir = g_path_get_dirname(exe);
  return dir;
}

std::string HelperPath() {
  const std::string dir = ExecutableDirectory();
  if (dir.empty()) return std::string();
  g_autofree gchar* path = g_build_filename(dir.c_str(), kHelperName, nullptr);
  return path;
}

std::string BundleDirectory() {
  const std::string dir = ExecutableDirectory();
  if (dir.empty()) return std::string();
  g_autofree gchar* path = g_build_filename(dir.c_str(), "data", "railgun", nullptr);
  return path;
}

// The page's only data store, in this identity's data directory (`$XDG_DATA_HOME/<application id>`, where the wallet
// lives too), so Veylor's never mixes with Vizor's or the testnet app's.
std::string DataDirectory() {
  g_autofree gchar* path = g_build_filename(g_get_user_data_dir(), APPLICATION_ID, "railgun-page", nullptr);
  return path;
}

// The page's IndexedDB holds the encrypted Railgun wallet and the notes the engine decrypted for it, which it keeps
// unencrypted: keep it out of backups, as the Mac keeps it out of Time Machine. Linux has no one switch for that; a
// CACHEDIR.TAG is what Déjà Dup, Borg, restic and tar's --exclude-caches honour. A failed mark never blocks the load.
bool PrepareDataDirectory(const std::string& dir) {
  if (g_mkdir_with_parents(dir.c_str(), 0700) != 0) return false;
  chmod(dir.c_str(), 0700);
  g_autofree gchar* tag = g_build_filename(dir.c_str(), "CACHEDIR.TAG", nullptr);
  if (!g_file_test(tag, G_FILE_TEST_EXISTS)) {
    static const char kTag[] =
        "Signature: 8a477f597d28d172789f06886806bc55\n"
        "# Veylor's Railgun page data: decrypted notes, kept out of backups.\n";
    g_file_set_contents(tag, kTag, -1, nullptr);
  }
  return true;
}

int RemoveEntry(const char* path, const struct stat*, int type, struct FTW*) {
  // Depth first and without following links: nothing outside the directory is touched.
  const int result = (type == FTW_DP) ? rmdir(path) : unlink(path);
  return result == 0 || errno == ENOENT ? 0 : -1;
}

bool RemoveTree(const std::string& dir) {
  if (!g_file_test(dir.c_str(), G_FILE_TEST_EXISTS)) return true;
  nftw(dir.c_str(), RemoveEntry, 16, FTW_DEPTH | FTW_PHYS);
  return !g_file_test(dir.c_str(), G_FILE_TEST_EXISTS);
}

// Whether something accepts TCP connections on loopback `port`: a connection made and dropped at once, which the
// bridge refuses quietly. A loopback connect is answered at once, so this never waits.
bool LoopbackAccepts(int port) {
  const int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return false;
  sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_port = htons(static_cast<uint16_t>(port));
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  const bool connected = connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0;
  close(fd);
  return connected;
}

// The page process's environment: the session's display, bus, locale and home, and nothing that could make it load
// other libraries or plugins (the AppImage's LD_LIBRARY_PATH and GStreamer paths), turn WebKit's sandbox off
// (WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS) or route it around its proxy (http_proxy and the like). It stays out of
// accessibility, as the Mac's page does.
gchar** CleanEnvironment() {
  static const char* const kKept[] = {
      "HOME",
      "USER",
      "LOGNAME",
      "PATH",
      "LANG",
      "LANGUAGE",
      "TZ",
      "DISPLAY",
      "WAYLAND_DISPLAY",
      "XAUTHORITY",
      "XDG_RUNTIME_DIR",
      "XDG_SESSION_TYPE",
      "XDG_SESSION_DESKTOP",
      "XDG_CURRENT_DESKTOP",
      "DESKTOP_SESSION",
      "DBUS_SESSION_BUS_ADDRESS",
      "XDG_DATA_HOME",
      "XDG_CONFIG_HOME",
      "XDG_CACHE_HOME",
      "XDG_STATE_HOME",
      "XDG_CONFIG_DIRS",
      "XDG_DATA_DIRS",
      "GDK_BACKEND",
  };
  const gchar* appdir = g_getenv("APPDIR");
  gchar** environment = nullptr;
  for (const char* name : kKept) {
    const gchar* value = g_getenv(name);
    if (value == nullptr) continue;
    std::string kept = value;
    // AppRun puts the AppImage's own share directory first; the page process uses the system's.
    if (appdir != nullptr && appdir[0] != '\0' && (std::strcmp(name, "XDG_DATA_DIRS") == 0 || std::strcmp(name, "PATH") == 0)) {
      g_auto(GStrv) parts = g_strsplit(value, ":", -1);
      std::string filtered;
      for (gchar** part = parts; *part != nullptr; ++part) {
        if (g_str_has_prefix(*part, appdir) || (*part)[0] == '\0') continue;
        if (!filtered.empty()) filtered += ":";
        filtered += *part;
      }
      kept = filtered;
    }
    if (kept.empty()) continue;
    environment = g_environ_setenv(environment, name, kept.c_str(), TRUE);
  }
  g_auto(GStrv) all = g_get_environ();
  for (gchar** entry = all; *entry != nullptr; ++entry) {
    if (g_str_has_prefix(*entry, "LC_")) {
      const gchar* equals = std::strchr(*entry, '=');
      if (equals == nullptr) continue;
      std::string name(*entry, static_cast<size_t>(equals - *entry));
      environment = g_environ_setenv(environment, name.c_str(), equals + 1, TRUE);
    }
  }
  environment = g_environ_setenv(environment, "NO_AT_BRIDGE", "1", TRUE);
  return environment;
}

// Logs the page process's own lines from its stderr and drops the rest.
struct LogReader {
  GDataInputStream* stream;
};

void ReadLogLine(GObject* source, GAsyncResult* result, gpointer data) {
  auto* reader = static_cast<LogReader*>(data);
  gsize length = 0;
  g_autofree gchar* line =
      g_data_input_stream_read_line_finish_utf8(G_DATA_INPUT_STREAM(source), result, &length, nullptr);
  if (line == nullptr) {
    g_object_unref(reader->stream);
    delete reader;
    return;
  }
  if (g_str_has_prefix(line, kLogPrefix)) g_message("Railgun page: %s", line + std::strlen(kLogPrefix));
  g_data_input_stream_read_line_async(reader->stream, G_PRIORITY_LOW, nullptr, ReadLogLine, reader);
}

void ReadLog(GSubprocess* process) {
  GInputStream* pipe = g_subprocess_get_stderr_pipe(process);
  if (pipe == nullptr) return;
  auto* reader = new LogReader{g_data_input_stream_new(pipe)};
  g_data_input_stream_read_line_async(reader->stream, G_PRIORITY_LOW, nullptr, ReadLogLine, reader);
}

class Host;
Host* g_host = nullptr;

// MARK: Page

// One page: one page process and its end of the link. Every call is answered exactly once, by its reply, its
// failure, its timeout or the close, and everything fails once the page closes. Params, results and events stay raw
// JSON text, as in Kotlin's `RailgunChannel`; nothing here logs them.
class Page : public std::enable_shared_from_this<Page> {
 public:
  Page(Host* host, bool debug) : host_(host), debug_(debug) {}
  ~Page();

  bool Start(const std::string& helper, int port, const std::string& data_dir, const std::string& bundle_dir,
             Error* error);
  void AwaitReady(FlMethodCall* call);
  void Call(const railgun_protocol::Method& method, const std::string& params_json, FlMethodCall* call);
  void SendVisible(bool visible);
  // Fails every call still waiting and ends the page process. Idempotent.
  void Close(const Error& reason);
  // The page process ended.
  void Exited(int status, bool signalled);

  bool loaded() const { return loaded_; }
  bool open() const { return !closed_by_.has_value(); }
  bool has_pending_calls() const { return !pending_.empty(); }

 private:
  struct Pending {
    FlMethodCall* call;
    guint timer;
    std::string method;
  };
  struct Timer {
    std::weak_ptr<Page> page;
    int64_t id;
  };

  void OnFrame(char type, std::string payload);
  void Receive(const std::string& text);
  void Settle(int64_t id, const std::string* result, const Error* failure);
  void SettleReady(const Error* failure);
  void CallTimedOut(int64_t id);
  void ReadyTimedOut();

  static gboolean OnCallTimer(gpointer data);
  static gboolean OnReadyTimer(gpointer data);
  static void FreeTimer(gpointer data) { delete static_cast<Timer*>(data); }

  Host* host_;
  bool debug_;
  GSubprocess* process_ = nullptr;
  std::unique_ptr<railgun_frames::Channel> channel_;
  bool loaded_ = false;
  std::optional<Error> closed_by_;
  FlMethodCall* ready_call_ = nullptr;
  guint ready_timer_ = 0;
  int64_t last_id_ = 0;
  std::map<int64_t, Pending> pending_;
  // The page process starts with its window shown.
  bool sent_visible_ = true;
};

// MARK: Host

// The process-wide host: the channels, the page process's sandbox check, one page at a time, the event buffer and
// the wipe. It outlives the page. A load waits for the page processes before it to exit, and gives up when a close,
// a wipe or another load comes first.
class Host {
 public:
  Host(FlBinaryMessenger* messenger, GtkWindow* window);

  void HandleCall(FlMethodCall* call);
  void SetListening(bool listening);
  void Emit(const std::string& raw);
  void Forget(Page* page);
  void Terminate(GSubprocess* process);
  void SetSessionAway(bool away);
  void WindowStateChanged();
  bool visible() const { return window_showing_ && !session_away_; }
  gchar** environment() const { return environment_; }
  void Spawned(GSubprocess* process, std::weak_ptr<Page> page);

 private:
  struct WipeJob {
    FlMethodCall* call;
    int attempts;
  };
  struct PendingLoad {
    int port;
    bool debug;
    FlMethodCall* call;
  };

  void Supported(FlMethodCall* call);
  void StartProbe();
  void ProbeEnded(bool passed);
  void Load(int port, bool debug, FlMethodCall* call);
  void StartPendingLoad();
  void Spawn(PendingLoad load);
  void ClosePage(const Error& reason);
  void Wipe(FlMethodCall* call);
  void RunWipes();
  void TryWipe(WipeJob* job);
  void ProcessExited(GSubprocess* process);
  void MemoryWarning();
  bool WindowShowing() const;

  static void OnProbeExited(GObject* source, GAsyncResult* result, gpointer data);
  static gboolean OnProbeTimeout(gpointer data);
  static void OnProcessExited(GObject* source, GAsyncResult* result, gpointer data);
  static gboolean OnKill(gpointer data);
  static gboolean OnLoadTimer(gpointer data);
  static void OnLowMemory(GMemoryMonitor* monitor, GMemoryMonitorWarningLevel level, gpointer data);

  FlMethodChannel* methods_ = nullptr;
  FlEventChannel* events_ = nullptr;
  GtkWindow* window_;
  bool listening_ = false;
  std::deque<std::string> buffered_;

  enum class Probe { kUnknown, kRunning, kPassed, kFailed };
  Probe probe_ = Probe::kUnknown;
  std::vector<FlMethodCall*> waiting_supported_;
  GSubprocess* probe_process_ = nullptr;
  guint probe_timer_ = 0;

  std::shared_ptr<Page> page_;
  // The load waiting for the page processes before it to exit, if any.
  std::optional<PendingLoad> pending_load_;
  guint load_timer_ = 0;
  gint64 last_exit_ = 0;
  // Every page process started and not yet exited, each with the page it served.
  std::map<GSubprocess*, std::weak_ptr<Page>> processes_;
  std::vector<WipeJob*> wipes_;

  bool window_showing_ = false;
  bool session_away_ = false;
  gchar** environment_;
  GMemoryMonitor* memory_ = nullptr;
};

Page::~Page() {
  if (ready_timer_ != 0) g_source_remove(ready_timer_);
  for (auto& entry : pending_) {
    if (entry.second.timer != 0) g_source_remove(entry.second.timer);
    g_object_unref(entry.second.call);
  }
  if (ready_call_ != nullptr) g_object_unref(ready_call_);
  if (process_ != nullptr) g_object_unref(process_);
}

bool Page::Start(const std::string& helper, int port, const std::string& data_dir, const std::string& bundle_dir,
                 Error* error) {
  int fds[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, fds) != 0) {
    *error = Error::Unavailable("the page's link could not be made");
    return false;
  }
  g_autoptr(GSubprocessLauncher) launcher =
      g_subprocess_launcher_new(static_cast<GSubprocessFlags>(G_SUBPROCESS_FLAGS_STDOUT_SILENCE |
                                                              G_SUBPROCESS_FLAGS_STDERR_PIPE));
  g_subprocess_launcher_set_environ(launcher, host_->environment());
  g_subprocess_launcher_set_cwd(launcher, "/");
  // The child's end, as its fd 3; GSubprocess closes every other descriptor in the child.
  g_subprocess_launcher_take_fd(launcher, fds[1], 3);
  const std::string port_text = std::to_string(port);
  std::vector<const gchar*> argv = {
      helper.c_str(), "--page",           "--fd",           "3", "--proxy-port", port_text.c_str(),
      "--data-dir",   data_dir.c_str(), "--bundle-dir", bundle_dir.c_str(),
  };
  if (debug_) argv.push_back("--debug");
  argv.push_back(nullptr);
  g_autoptr(GError) spawn_error = nullptr;
  process_ = g_subprocess_launcher_spawnv(launcher, argv.data(), &spawn_error);
  if (process_ == nullptr) {
    close(fds[0]);
    g_message("Railgun page: the page process did not start");
    *error = Error::Unavailable("the page's host process did not start");
    return false;
  }
  ReadLog(process_);
  host_->Spawned(process_, weak_from_this());
  std::weak_ptr<Page> weak = weak_from_this();
  channel_ = std::make_unique<railgun_frames::Channel>(
      fds[0],
      [weak](char type, std::string payload) {
        if (auto page = weak.lock()) page->OnFrame(type, std::move(payload));
      },
      [weak]() {
        if (auto page = weak.lock()) page->Close(Error::Disconnected("the page's host process stopped"));
      });
  SendVisible(host_->visible());
  return true;
}

void Page::AwaitReady(FlMethodCall* call) {
  ready_call_ = static_cast<FlMethodCall*>(g_object_ref(call));
  ready_timer_ = g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, kLoadTimeoutSeconds, OnReadyTimer,
                                            new Timer{weak_from_this(), 0}, FreeTimer);
}

void Page::Call(const railgun_protocol::Method& method, const std::string& params_json, FlMethodCall* call) {
  if (closed_by_.has_value()) {
    AnswerError(call, Error::Disconnected(closed_by_->message));
    return;
  }
  const int64_t id = ++last_id_;
  std::string request;
  Error failure;
  if (!railgun_protocol::Request(id, method, params_json, &request, &failure)) {
    AnswerError(call, failure);
    return;
  }
  uint8_t flags = 0;
  // A `start` that reads Anon's archive gets the page ready for it first.
  if (std::strcmp(method.name, "start") == 0 && railgun_protocol::StartsWithArchive(params_json)) {
    flags |= railgun_frames::kDeliverPrepareArchive;
  }
  const guint timer = g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, static_cast<guint>(method.timeout_seconds),
                                                 OnCallTimer, new Timer{weak_from_this(), id}, FreeTimer);
  pending_[id] = Pending{static_cast<FlMethodCall*>(g_object_ref(call)), timer, method.name};
  std::string payload = railgun_frames::EncodeId(id);
  payload.push_back(static_cast<char>(flags));
  payload += request;
  if (channel_ == nullptr || !channel_->Send(railgun_frames::kDeliver, payload)) {
    const Error undelivered = Error::Disconnected("the page did not take the call");
    Settle(id, nullptr, &undelivered);
  }
}

void Page::SendVisible(bool visible) {
  if (channel_ == nullptr || visible == sent_visible_) return;
  sent_visible_ = visible;
  channel_->Send(railgun_frames::kVisible, std::string(1, visible ? '\1' : '\0'));
}

void Page::OnFrame(char type, std::string payload) {
  if (closed_by_.has_value()) return;
  switch (type) {
    case railgun_frames::kMessage:
      Receive(payload);
      break;
    case railgun_frames::kUndelivered: {
      int64_t id = 0;
      if (railgun_frames::DecodeId(payload, 0, &id)) {
        const Error undelivered = Error::Disconnected("the page did not take the call");
        Settle(id, nullptr, &undelivered);
      }
      break;
    }
    case railgun_frames::kClosed: {
      const char kind = payload.empty() ? railgun_frames::kClosedDisconnected : payload[0];
      std::string reason = payload.size() > 1 ? payload.substr(1) : std::string("the page closed");
      Close(kind == railgun_frames::kClosedUnavailable ? Error::Unavailable(std::move(reason))
                                                       : Error::Disconnected(std::move(reason)));
      break;
    }
    default:
      break;
  }
}

// One message from the page, as it sent it.
void Page::Receive(const std::string& text) {
  const Message message = railgun_protocol::Decode(text);
  switch (message.type) {
    case Message::Type::kReady:
      if (!loaded_) {
        loaded_ = true;
        SettleReady(nullptr);
      }
      break;
    case Message::Type::kEvent:
      // Engine lines can quote anything the engine saw: only a debug page forwards them.
      if (debug_ || message.event != railgun_protocol::kLogEvent) host_->Emit(text);
      break;
    case Message::Type::kReply:
      Settle(message.id, &message.result_json, nullptr);
      break;
    case Message::Type::kFailure:
      Settle(message.id, nullptr, &message.error);
      break;
    case Message::Type::kNone:
      break;
  }
}

// Whoever removes a call answers it, so it is answered once.
void Page::Settle(int64_t id, const std::string* result, const Error* failure) {
  auto found = pending_.find(id);
  if (found == pending_.end()) return;
  Pending call = found->second;
  pending_.erase(found);
  if (call.timer != 0) g_source_remove(call.timer);
  if (failure != nullptr) {
    AnswerError(call.call, *failure);
  } else {
    AnswerValue(call.call, fl_value_new_string(result->c_str()));
  }
  g_object_unref(call.call);
}

void Page::SettleReady(const Error* failure) {
  if (ready_timer_ != 0) g_source_remove(ready_timer_);
  ready_timer_ = 0;
  FlMethodCall* call = ready_call_;
  ready_call_ = nullptr;
  if (call == nullptr) return;
  if (failure != nullptr) {
    AnswerError(call, *failure);
  } else {
    g_message("Railgun page: loaded");
    AnswerValue(call, nullptr);
  }
  g_object_unref(call);
}

// A call that times out closes the page, as on Android, iOS and the Mac: the engine may be stuck.
void Page::CallTimedOut(int64_t id) {
  auto found = pending_.find(id);
  if (found == pending_.end()) return;
  found->second.timer = 0;
  const Error timeout = Error::Timeout(found->second.method);
  Settle(id, nullptr, &timeout);
  auto self = shared_from_this();
  host_->Forget(this);
  Close(timeout);
}

void Page::ReadyTimedOut() {
  ready_timer_ = 0;
  const Error timeout = Error::Timeout("loading the page");
  SettleReady(&timeout);
  auto self = shared_from_this();
  host_->Forget(this);
  Close(Error::Disconnected("the page did not load"));
}

void Page::Close(const Error& reason) {
  if (closed_by_.has_value()) return;
  closed_by_ = reason;
  auto self = shared_from_this();
  // A page that never said it was ready did not load.
  const Error not_loaded = Error::Disconnected(reason.message);
  SettleReady(reason.kind == Error::Kind::kUnavailable ? &reason : &not_loaded);
  std::map<int64_t, Pending> calls;
  calls.swap(pending_);
  for (auto& entry : calls) {
    if (entry.second.timer != 0) g_source_remove(entry.second.timer);
    AnswerError(entry.second.call, Error::Disconnected(reason.message));
    g_object_unref(entry.second.call);
  }
  if (channel_ != nullptr) {
    channel_->Send(railgun_frames::kQuit, std::string());
    channel_.reset();
  }
  if (process_ != nullptr) host_->Terminate(process_);
  if (loaded_) g_message("Railgun page: closed");
  host_->Forget(this);
}

void Page::Exited(int status, bool signalled) {
  if (closed_by_.has_value()) return;
  if (!signalled && status == kExitSandbox) {
    Close(Error::Unavailable("the page's sandbox did not start"));
  } else {
    Close(Error::Disconnected("the page's host process stopped"));
  }
}

gboolean Page::OnCallTimer(gpointer data) {
  auto* timer = static_cast<Timer*>(data);
  if (auto page = timer->page.lock()) page->CallTimedOut(timer->id);
  return G_SOURCE_REMOVE;
}

gboolean Page::OnReadyTimer(gpointer data) {
  auto* timer = static_cast<Timer*>(data);
  if (auto page = timer->page.lock()) page->ReadyTimedOut();
  return G_SOURCE_REMOVE;
}

// MARK: Host

Host::Host(FlBinaryMessenger* messenger, GtkWindow* window) : window_(window), environment_(CleanEnvironment()) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  methods_ = fl_method_channel_new(messenger, "com.zcash.wallet/railgun", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      methods_,
      [](FlMethodChannel*, FlMethodCall* call, gpointer data) { static_cast<Host*>(data)->HandleCall(call); }, this,
      nullptr);
  events_ = fl_event_channel_new(messenger, "com.zcash.wallet/railgun/events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(
      events_,
      [](FlEventChannel*, FlValue*, gpointer data) -> FlMethodErrorResponse* {
        static_cast<Host*>(data)->SetListening(true);
        return nullptr;
      },
      [](FlEventChannel*, FlValue*, gpointer data) -> FlMethodErrorResponse* {
        static_cast<Host*>(data)->SetListening(false);
        return nullptr;
      },
      this, nullptr);
  memory_ = g_memory_monitor_dup_default();
  if (memory_ != nullptr) g_signal_connect(memory_, "low-memory-warning", G_CALLBACK(OnLowMemory), this);
  window_showing_ = WindowShowing();
}

void Host::HandleCall(FlMethodCall* call) {
  const gchar* method = fl_method_call_get_name(call);
  if (std::strcmp(method, "supported") == 0) {
    Supported(call);
  } else if (std::strcmp(method, "load") == 0) {
    FlValue* port = Argument(call, "proxyPort");
    if (port == nullptr || fl_value_get_type(port) != FL_VALUE_TYPE_INT || fl_value_get_int(port) < 1 ||
        fl_value_get_int(port) > 65535) {
      AnswerBadArgs(call, "proxyPort");
      return;
    }
    FlValue* debug = Argument(call, "debug");
    const bool debugging =
        kDebuggable && debug != nullptr && fl_value_get_type(debug) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(debug);
    Load(static_cast<int>(fl_value_get_int(port)), debugging, call);
  } else if (std::strcmp(method, "call") == 0) {
    FlValue* name = Argument(call, "method");
    FlValue* params = Argument(call, "paramsJson");
    const railgun_protocol::Method* found =
        name != nullptr && fl_value_get_type(name) == FL_VALUE_TYPE_STRING
            ? railgun_protocol::FindMethod(fl_value_get_string(name))
            : nullptr;
    if (found == nullptr || params == nullptr || fl_value_get_type(params) != FL_VALUE_TYPE_STRING) {
      AnswerBadArgs(call, "method or paramsJson");
      return;
    }
    if (page_ == nullptr || !page_->loaded() || !page_->open()) {
      AnswerError(call, Error::Disconnected("no page"));
      return;
    }
    // The page may close while this call runs; hold it until it answers.
    auto page = page_;
    page->Call(*found, fl_value_get_string(params), call);
  } else if (std::strcmp(method, "close") == 0) {
    ClosePage(Error::Disconnected("closed"));
    AnswerValue(call, nullptr);
  } else if (std::strcmp(method, "wipe") == 0) {
    Wipe(call);
  } else if (std::strcmp(method, "isOpen") == 0) {
    AnswerValue(call, fl_value_new_bool(page_ != nullptr && page_->loaded() && page_->open()));
  } else {
    g_autoptr(GError) error = nullptr;
    fl_method_call_respond_not_implemented(call, &error);
  }
}

// MARK: The sandbox check

// Whether the page can run here: the page process loads WebKitGTK and starts a sandboxed page, once per process. It
// never runs a page without WebKit's sandbox, and WebKit aborts a process whose sandbox can't start, so the check
// runs in a process of its own. Asked after the first frame (app_bootstrap.dart), so it never delays the start.
void Host::Supported(FlMethodCall* call) {
  if (probe_ == Probe::kPassed || probe_ == Probe::kFailed) {
    AnswerValue(call, fl_value_new_bool(probe_ == Probe::kPassed));
    return;
  }
  waiting_supported_.push_back(static_cast<FlMethodCall*>(g_object_ref(call)));
  if (probe_ == Probe::kUnknown) StartProbe();
}

void Host::StartProbe() {
  probe_ = Probe::kRunning;
  const std::string helper = HelperPath();
  if (helper.empty() || !g_file_test(helper.c_str(), G_FILE_TEST_IS_EXECUTABLE)) {
    g_message("Railgun page: unavailable: this build has no page process");
    ProbeEnded(false);
    return;
  }
  g_autoptr(GSubprocessLauncher) launcher =
      g_subprocess_launcher_new(static_cast<GSubprocessFlags>(G_SUBPROCESS_FLAGS_STDOUT_SILENCE |
                                                              G_SUBPROCESS_FLAGS_STDERR_PIPE));
  g_subprocess_launcher_set_environ(launcher, environment_);
  g_subprocess_launcher_set_cwd(launcher, "/");
  const gchar* argv[] = {helper.c_str(), "--probe", nullptr};
  g_autoptr(GError) error = nullptr;
  probe_process_ = g_subprocess_launcher_spawnv(launcher, argv, &error);
  if (probe_process_ == nullptr) {
    g_message("Railgun page: unavailable: the page process did not start");
    ProbeEnded(false);
    return;
  }
  ReadLog(probe_process_);
  g_subprocess_wait_async(probe_process_, nullptr, OnProbeExited, this);
  probe_timer_ = g_timeout_add_seconds(kProbeTimeoutSeconds, OnProbeTimeout, this);
}

void Host::OnProbeExited(GObject* source, GAsyncResult* result, gpointer data) {
  auto* self = static_cast<Host*>(data);
  GSubprocess* process = G_SUBPROCESS(source);
  g_subprocess_wait_finish(process, result, nullptr);
  const bool passed = g_subprocess_get_if_exited(process) && g_subprocess_get_exit_status(process) == 0;
  if (!passed) {
    if (g_subprocess_get_if_exited(process)) {
      g_message("Railgun page: unavailable (the check exited with %d)", g_subprocess_get_exit_status(process));
    } else {
      g_message("Railgun page: unavailable (the check was stopped)");
    }
  }
  if (self->probe_process_ == process) {
    g_clear_object(&self->probe_process_);
    if (self->probe_timer_ != 0) g_source_remove(self->probe_timer_);
    self->probe_timer_ = 0;
    self->ProbeEnded(passed);
  }
}

gboolean Host::OnProbeTimeout(gpointer data) {
  auto* self = static_cast<Host*>(data);
  self->probe_timer_ = 0;
  if (self->probe_process_ != nullptr) {
    g_message("Railgun page: unavailable (the check took too long)");
    g_subprocess_force_exit(self->probe_process_);
    g_clear_object(&self->probe_process_);
    self->ProbeEnded(false);
  }
  return G_SOURCE_REMOVE;
}

void Host::ProbeEnded(bool passed) {
  probe_ = passed ? Probe::kPassed : Probe::kFailed;
  if (passed) g_message("Railgun page: WebKit's sandbox started; Shielded USD can run here");
  std::vector<FlMethodCall*> calls;
  calls.swap(waiting_supported_);
  for (FlMethodCall* call : calls) {
    AnswerValue(call, fl_value_new_bool(passed));
    g_object_unref(call);
  }
}

// MARK: Pages

// Loads a fresh page, closing the one before it, with its traffic sent to the bridge at `port`. Answers once the
// page says it is ready. Two page processes would share the page's data store, so a new one starts once the one
// before it, and WebKit's processes with it, have exited.
void Host::Load(int port, bool debug, FlMethodCall* call) {
  ClosePage(Error::Disconnected("a new page replaced it"));
  if (probe_ != Probe::kPassed) {
    AnswerError(call, Error::Unavailable("WebKit's sandbox can't start here"));
    return;
  }
  pending_load_ = PendingLoad{port, debug, static_cast<FlMethodCall*>(g_object_ref(call))};
  StartPendingLoad();
}

void Host::StartPendingLoad() {
  if (!pending_load_.has_value() || load_timer_ != 0 || !processes_.empty()) return;
  const gint64 since_exit = g_get_monotonic_time() - last_exit_;
  if (last_exit_ != 0 && since_exit < kAfterExitUs) {
    load_timer_ = g_timeout_add(static_cast<guint>((kAfterExitUs - since_exit) / 1000) + 1, OnLoadTimer, this);
    return;
  }
  PendingLoad load = *pending_load_;
  pending_load_.reset();
  Spawn(load);
}

gboolean Host::OnLoadTimer(gpointer data) {
  auto* self = static_cast<Host*>(data);
  self->load_timer_ = 0;
  self->StartPendingLoad();
  return G_SOURCE_REMOVE;
}

void Host::Spawn(PendingLoad load) {
  // Never a page without its proxy.
  const std::string data_dir = DataDirectory();
  Error error;
  if (!LoopbackAccepts(load.port)) {
    error = Error::Unavailable("the bridge is not running");
  } else if (!PrepareDataDirectory(data_dir)) {
    error = Error::Unavailable("the page's storage could not be made");
  } else {
    auto page = std::make_shared<Page>(this, load.debug);
    if (page->Start(HelperPath(), load.port, data_dir, BundleDirectory(), &error)) {
      page_ = page;
      page->AwaitReady(load.call);
      g_object_unref(load.call);
      return;
    }
  }
  AnswerError(load.call, error);
  g_object_unref(load.call);
}

void Host::ClosePage(const Error& reason) {
  if (pending_load_.has_value()) {
    FlMethodCall* call = pending_load_->call;
    pending_load_.reset();
    if (load_timer_ != 0) g_source_remove(load_timer_);
    load_timer_ = 0;
    AnswerError(call, Error::Disconnected(reason.message));
    g_object_unref(call);
  }
  std::shared_ptr<Page> closing = std::move(page_);
  page_.reset();
  if (closing != nullptr) closing->Close(reason);
}

void Host::Forget(Page* page) {
  if (page_.get() == page) page_.reset();
}

void Host::Spawned(GSubprocess* process, std::weak_ptr<Page> page) {
  processes_[static_cast<GSubprocess*>(g_object_ref(process))] = std::move(page);
  g_subprocess_wait_async(process, nullptr, OnProcessExited, this);
}

void Host::OnProcessExited(GObject* source, GAsyncResult* result, gpointer data) {
  auto* self = static_cast<Host*>(data);
  GSubprocess* process = G_SUBPROCESS(source);
  g_subprocess_wait_finish(process, result, nullptr);
  self->ProcessExited(process);
}

void Host::ProcessExited(GSubprocess* process) {
  auto found = processes_.find(process);
  if (found == processes_.end()) return;
  std::weak_ptr<Page> weak = found->second;
  processes_.erase(found);
  const bool signalled = !g_subprocess_get_if_exited(process);
  const int status = signalled ? -1 : g_subprocess_get_exit_status(process);
  if (auto page = weak.lock()) page->Exited(status, signalled);
  g_object_unref(process);
  last_exit_ = g_get_monotonic_time();
  RunWipes();
  StartPendingLoad();
}

// Asks the page process to exit, and ends it if it has not after a moment.
void Host::Terminate(GSubprocess* process) {
  if (processes_.find(process) == processes_.end()) return;
  g_subprocess_send_signal(process, SIGTERM);
  g_timeout_add_full(G_PRIORITY_DEFAULT, kQuitGraceMs, OnKill, g_object_ref(process), g_object_unref);
}

gboolean Host::OnKill(gpointer data) {
  GSubprocess* process = G_SUBPROCESS(data);
  if (g_host != nullptr && g_host->processes_.find(process) != g_host->processes_.end()) {
    g_subprocess_force_exit(process);
  }
  return G_SOURCE_REMOVE;
}

// MARK: Events

void Host::SetListening(bool listening) {
  listening_ = listening;
  if (!listening) return;
  std::deque<std::string> waiting;
  waiting.swap(buffered_);
  for (const std::string& raw : waiting) Emit(raw);
}

// Where events go; with nobody listening they wait in a buffer, the oldest going first.
void Host::Emit(const std::string& raw) {
  if (listening_) {
    g_autoptr(FlValue) value = fl_value_new_string(raw.c_str());
    g_autoptr(GError) error = nullptr;
    fl_event_channel_send(events_, value, nullptr, &error);
    return;
  }
  buffered_.push_back(raw);
  while (buffered_.size() > kEventBuffer) buffered_.pop_front();
}

// MARK: The wipe

// Closes the page, then deletes its data store and everything in it, every account's wallet with it. The page
// process and WebKit's own processes let go of it as they exit, so the wipe waits for the page process and tries
// again a few times, as the Mac's does.
void Host::Wipe(FlMethodCall* call) {
  ClosePage(Error::Disconnected("wiped"));
  wipes_.push_back(new WipeJob{static_cast<FlMethodCall*>(g_object_ref(call)), 0});
  RunWipes();
}

void Host::RunWipes() {
  if (!processes_.empty() || wipes_.empty()) return;
  std::vector<WipeJob*> jobs;
  jobs.swap(wipes_);
  for (WipeJob* job : jobs) TryWipe(job);
}

void Host::TryWipe(WipeJob* job) {
  const std::string dir = DataDirectory();
  const bool removed = RemoveTree(dir);
  ++job->attempts;
  if (removed && job->attempts >= 2) {
    AnswerValue(job->call, nullptr);
    g_object_unref(job->call);
    delete job;
    return;
  }
  if (job->attempts >= kWipeAttempts) {
    if (removed) {
      AnswerValue(job->call, nullptr);
    } else {
      AnswerError(job->call, Error::Failed("the page's data could not be removed"));
    }
    g_object_unref(job->call);
    delete job;
    return;
  }
  // Again in a moment, in case one of WebKit's processes still held it, or made it anew as it exited.
  struct Retry {
    Host* host;
    WipeJob* job;
  };
  g_timeout_add_full(
      G_PRIORITY_DEFAULT, kWipeRetryMs,
      [](gpointer data) -> gboolean {
        auto* retry = static_cast<Retry*>(data);
        retry->host->TryWipe(retry->job);
        return G_SOURCE_REMOVE;
      },
      new Retry{this, job}, [](gpointer data) { delete static_cast<Retry*>(data); });
}

// MARK: Memory and visibility

// Memory pressure closes an idle page, as the Mac's does; it reopens on the next use.
void Host::OnLowMemory(GMemoryMonitor*, GMemoryMonitorWarningLevel level, gpointer data) {
  if (level < G_MEMORY_MONITOR_WARNING_LEVEL_MEDIUM) return;
  static_cast<Host*>(data)->MemoryWarning();
}

void Host::MemoryWarning() {
  if (page_ == nullptr || !page_->loaded() || !page_->open() || page_->has_pending_calls()) return;
  ClosePage(Error::Disconnected("closed to free memory"));
}

bool Host::WindowShowing() const {
  if (window_ == nullptr || !gtk_widget_get_mapped(GTK_WIDGET(window_))) return false;
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window_));
  if (gdk_window == nullptr) return false;
  const GdkWindowState state = gdk_window_get_state(gdk_window);
  return (state & (GDK_WINDOW_STATE_WITHDRAWN | GDK_WINDOW_STATE_ICONIFIED)) == 0;
}

void Host::WindowStateChanged() {
  window_showing_ = WindowShowing();
  if (page_ != nullptr) page_->SendVisible(visible());
}

void Host::SetSessionAway(bool away) {
  session_away_ = away;
  WindowStateChanged();
}

gboolean OnWindowState(GtkWidget*, GdkEventWindowState*, gpointer) {
  if (g_host != nullptr) g_host->WindowStateChanged();
  return FALSE;
}

void OnWindowMapped(GtkWidget*, gpointer) {
  if (g_host != nullptr) g_host->WindowStateChanged();
}

}  // namespace

void railgun_host_register(FlView* view, GtkWindow* window) {
  if (g_host != nullptr) return;
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_host = new Host(messenger, window);
  g_signal_connect(window, "window-state-event", G_CALLBACK(OnWindowState), nullptr);
  g_signal_connect(window, "map", G_CALLBACK(OnWindowMapped), nullptr);
  g_signal_connect(window, "unmap", G_CALLBACK(OnWindowMapped), nullptr);
}

void railgun_host_set_session_away(gboolean away) {
  if (g_host != nullptr) g_host->SetSessionAway(away);
}
