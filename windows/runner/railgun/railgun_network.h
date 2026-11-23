#ifndef RUNNER_RAILGUN_RAILGUN_NETWORK_H_
#define RUNNER_RAILGUN_RAILGUN_NETWORK_H_

// What the Railgun host needs of Winsock and the IP helper, apart from the rest so that <winsock2.h> comes before
// <windows.h> here alone.
namespace railgun_windows {

// Whether something accepts TCP connections on loopback `port`: a connection made and dropped at once, which the
// bridge refuses quietly, as the Mac's `loopbackAccepts`. A loopback connect is answered at once.
bool LoopbackAccepts(int port);

// Calls `changed` whenever the network changes (an interface comes, goes or changes), on a thread of Windows's. Watches
// from the first call for the rest of the process; later calls change nothing.
void WatchNetworkChanges(void (*changed)());

}  // namespace railgun_windows

#endif  // RUNNER_RAILGUN_RAILGUN_NETWORK_H_
