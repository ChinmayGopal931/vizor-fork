#ifndef RUNNER_PRIVATE_USD_RAILGUN_FRAMES_H_
#define RUNNER_PRIVATE_USD_RAILGUN_FRAMES_H_

#include <glib.h>

#include <cstdint>
#include <functional>
#include <string>

// The link between Veylor and its Railgun page process (`veylor-railgun-page`): one end of a socket pair each, carrying
// frames of a 4-byte big-endian length, a type byte and the payload. Both ends are this build's, started together, so
// the format has no version. Neither end logs a payload: requests carry mnemonics and keyed RPC URLs.
namespace railgun_frames {

// Veylor to the page process.
// Deliver one request to the page: an 8-byte big-endian call id, a flags byte, then the request's JSON text.
inline constexpr char kDeliver = 'D';
// Flag: run the archive prelude before this request (a `start` that reads Anon's archive).
inline constexpr uint8_t kDeliverPrepareArchive = 0x01;
// Whether Veylor's window shows: one byte, 1 shown, 0 hidden.
inline constexpr char kVisible = 'V';
// Close the page and exit.
inline constexpr char kQuit = 'Q';

// The page process to Veylor.
// A message the page posted to its host, as it sent it.
inline constexpr char kMessage = 'M';
// The page never took a request: its 8-byte big-endian call id.
inline constexpr char kUndelivered = 'X';
// The page closed, a kind byte (`kClosedDisconnected` or `kClosedUnavailable`) and a fixed reason; the process exits.
inline constexpr char kClosed = 'C';
inline constexpr char kClosedDisconnected = 'd';
inline constexpr char kClosedUnavailable = 'u';

// The largest frame either end takes; a longer one closes the link.
inline constexpr uint32_t kMaxFrame = 64u * 1024u * 1024u;

std::string EncodeId(int64_t id);
bool DecodeId(const std::string& payload, size_t offset, int64_t* id);

// One end of the link, on the GLib main loop. Callbacks may destroy the channel.
class Channel {
 public:
  using OnFrame = std::function<void(char type, std::string payload)>;
  using OnClosed = std::function<void()>;

  // Takes `fd`, which it makes non-blocking and closes when it is destroyed.
  Channel(int fd, OnFrame on_frame, OnClosed on_closed);
  ~Channel();
  Channel(const Channel&) = delete;
  Channel& operator=(const Channel&) = delete;

  // Queues a frame; false once the link is closed.
  bool Send(char type, const std::string& payload);
  bool IsOpen() const { return fd_ >= 0; }
  // Writes out whatever is still queued, waiting if it must: for the last words before a process exits.
  void Drain();
  // Closes the link without telling `on_closed`.
  void Close();

 private:
  static gboolean OnReadable(gint fd, GIOCondition condition, gpointer data);
  static gboolean OnWritable(gint fd, GIOCondition condition, gpointer data);
  bool Flush();
  void Fail();

  int fd_;
  guint read_source_ = 0;
  guint write_source_ = 0;
  std::string inbox_;
  std::string outbox_;
  OnFrame on_frame_;
  OnClosed on_closed_;
  // Set while this object exists; a callback that destroys it clears the flag through the destructor.
  bool* alive_ = nullptr;
};

}  // namespace railgun_frames

#endif  // RUNNER_PRIVATE_USD_RAILGUN_FRAMES_H_
