#include "private_usd/railgun_frames.h"

#include <errno.h>
#include <fcntl.h>
#include <glib-unix.h>
#include <sys/socket.h>
#include <unistd.h>

namespace railgun_frames {

std::string EncodeId(int64_t id) {
  std::string bytes(8, '\0');
  const uint64_t value = static_cast<uint64_t>(id);
  for (int i = 0; i < 8; ++i) bytes[i] = static_cast<char>((value >> (56 - 8 * i)) & 0xFF);
  return bytes;
}

bool DecodeId(const std::string& payload, size_t offset, int64_t* id) {
  if (payload.size() < offset + 8) return false;
  uint64_t value = 0;
  for (int i = 0; i < 8; ++i) value = (value << 8) | static_cast<unsigned char>(payload[offset + i]);
  *id = static_cast<int64_t>(value);
  return true;
}

Channel::Channel(int fd, OnFrame on_frame, OnClosed on_closed)
    : fd_(fd), on_frame_(std::move(on_frame)), on_closed_(std::move(on_closed)) {
  const int flags = fcntl(fd_, F_GETFL);
  fcntl(fd_, F_SETFL, flags | O_NONBLOCK);
  fcntl(fd_, F_SETFD, FD_CLOEXEC);
  read_source_ = g_unix_fd_add(fd_, static_cast<GIOCondition>(G_IO_IN | G_IO_HUP | G_IO_ERR), OnReadable, this);
}

Channel::~Channel() {
  if (alive_ != nullptr) *alive_ = false;
  Close();
}

void Channel::Close() {
  if (read_source_ != 0) g_source_remove(read_source_);
  if (write_source_ != 0) g_source_remove(write_source_);
  read_source_ = 0;
  write_source_ = 0;
  if (fd_ >= 0) close(fd_);
  fd_ = -1;
  outbox_.clear();
  inbox_.clear();
}

bool Channel::Send(char type, const std::string& payload) {
  if (fd_ < 0) return false;
  const uint32_t length = static_cast<uint32_t>(payload.size() + 1);
  if (payload.size() + 1 > kMaxFrame) return false;
  const char header[5] = {
      static_cast<char>((length >> 24) & 0xFF), static_cast<char>((length >> 16) & 0xFF),
      static_cast<char>((length >> 8) & 0xFF), static_cast<char>(length & 0xFF), type,
  };
  outbox_.append(header, sizeof(header));
  outbox_.append(payload);
  return Flush();
}

bool Channel::Flush() {
  while (!outbox_.empty()) {
    const ssize_t written = send(fd_, outbox_.data(), outbox_.size(), MSG_NOSIGNAL);
    if (written > 0) {
      outbox_.erase(0, static_cast<size_t>(written));
      continue;
    }
    if (written < 0 && errno == EINTR) continue;
    if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      if (write_source_ == 0) {
        write_source_ = g_unix_fd_add(fd_, static_cast<GIOCondition>(G_IO_OUT | G_IO_HUP | G_IO_ERR), OnWritable, this);
      }
      return true;
    }
    return false;
  }
  return true;
}

void Channel::Drain() {
  if (fd_ < 0) return;
  const int flags = fcntl(fd_, F_GETFL);
  fcntl(fd_, F_SETFL, flags & ~O_NONBLOCK);
  while (!outbox_.empty()) {
    const ssize_t written = send(fd_, outbox_.data(), outbox_.size(), MSG_NOSIGNAL);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) break;
    outbox_.erase(0, static_cast<size_t>(written));
  }
  fcntl(fd_, F_SETFL, flags);
}

void Channel::Fail() {
  Close();
  // Last: the callback may destroy this channel.
  if (on_closed_) {
    OnClosed closed = on_closed_;
    closed();
  }
}

gboolean Channel::OnWritable(gint, GIOCondition condition, gpointer data) {
  auto* self = static_cast<Channel*>(data);
  if (condition & (G_IO_HUP | G_IO_ERR)) {
    self->write_source_ = 0;
    self->Fail();
    return G_SOURCE_REMOVE;
  }
  if (!self->Flush()) {
    self->write_source_ = 0;
    self->Fail();
    return G_SOURCE_REMOVE;
  }
  if (self->outbox_.empty()) {
    self->write_source_ = 0;
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}

gboolean Channel::OnReadable(gint, GIOCondition condition, gpointer data) {
  auto* self = static_cast<Channel*>(data);
  bool alive = true;
  self->alive_ = &alive;
  bool ended = false;
  char buffer[64 * 1024];
  while (true) {
    const ssize_t got = recv(self->fd_, buffer, sizeof(buffer), 0);
    if (got > 0) {
      self->inbox_.append(buffer, static_cast<size_t>(got));
      continue;
    }
    if (got < 0 && errno == EINTR) continue;
    if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
    ended = true;
    break;
  }
  if (!ended && (condition & G_IO_ERR)) ended = true;

  // Every whole frame first: a peer may send its last words and close.
  while (self->inbox_.size() >= 5) {
    const auto byte = [&](size_t i) { return static_cast<uint32_t>(static_cast<unsigned char>(self->inbox_[i])); };
    const uint32_t length = (byte(0) << 24) | (byte(1) << 16) | (byte(2) << 8) | byte(3);
    if (length == 0 || length > kMaxFrame) {
      ended = true;
      break;
    }
    if (self->inbox_.size() < 4 + static_cast<size_t>(length)) break;
    const char type = self->inbox_[4];
    std::string payload = self->inbox_.substr(5, length - 1);
    self->inbox_.erase(0, 4 + static_cast<size_t>(length));
    self->on_frame_(type, std::move(payload));
    if (!alive) return G_SOURCE_REMOVE;
    if (self->fd_ < 0) {
      self->alive_ = nullptr;
      return G_SOURCE_REMOVE;
    }
  }
  self->alive_ = nullptr;
  if (ended) {
    self->read_source_ = 0;
    self->Fail();
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}

}  // namespace railgun_frames
