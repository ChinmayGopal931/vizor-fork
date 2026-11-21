#ifndef RUNNER_PRIVATE_USD_RAILGUN_HOST_H_
#define RUNNER_PRIVATE_USD_RAILGUN_HOST_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The Railgun page host on Linux, over the same channel contract as Android's, iOS's and the Mac's
// (`com.zcash.wallet/railgun` and `/events`: `supported`, `load`, `call`, `close`, `wipe`, `isOpen`). The page runs in
// a process of its own, `veylor-railgun-page`, started with a clean environment so it loads the system's WebKitGTK and
// libsoup, never the AppImage's libraries, and always in WebKit's sandbox. One page at a time, process-wide.
void railgun_host_register(FlView* view, GtkWindow* window);

// Whether the user is away from the session (the screen locked, the computer asleep, another session in front): the
// page is hidden then, as WebKit hides a page whose Mac window can't be seen.
void railgun_host_set_session_away(gboolean away);

#endif  // RUNNER_PRIVATE_USD_RAILGUN_HOST_H_
