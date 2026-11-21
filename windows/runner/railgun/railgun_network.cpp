// Winsock's headers must come before <windows.h>, which would otherwise bring the old <winsock.h>.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <netioapi.h>

#include "railgun/railgun_network.h"

#include <atomic>

namespace railgun_windows {
namespace {

bool WinsockReady() {
  static const bool ready = []() {
    WSADATA data;
    return ::WSAStartup(MAKEWORD(2, 2), &data) == 0;
  }();
  return ready;
}

std::atomic<void (*)()> g_changed{nullptr};

void CALLBACK OnInterfaceChange(PVOID, PMIB_IPINTERFACE_ROW, MIB_NOTIFICATION_TYPE) {
  if (auto changed = g_changed.load()) changed();
}

}  // namespace

bool LoopbackAccepts(int port) {
  if (port <= 0 || port > 65535 || !WinsockReady()) return false;
  SOCKET fd = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (fd == INVALID_SOCKET) return false;
  sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_port = ::htons(static_cast<u_short>(port));
  address.sin_addr.s_addr = ::htonl(INADDR_LOOPBACK);
  const bool connected =
      ::connect(fd, reinterpret_cast<const sockaddr*>(&address), static_cast<int>(sizeof(address))) == 0;
  ::closesocket(fd);
  return connected;
}

void WatchNetworkChanges(void (*changed)()) {
  void (*expected)() = nullptr;
  if (!g_changed.compare_exchange_strong(expected, changed)) return;
  HANDLE handle = nullptr;
  // Kept for the process: Windows calls back on a thread of its own.
  ::NotifyIpInterfaceChange(AF_UNSPEC, &OnInterfaceChange, nullptr, FALSE, &handle);
}

}  // namespace railgun_windows
