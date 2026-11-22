#ifndef RUNNER_PRIVATE_USD_PRIVATE_USD_CHANNELS_H_
#define RUNNER_PRIVATE_USD_PRIVATE_USD_CHANNELS_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Shielded USD's native side on Linux (docs/private-usd.md), on the Mac's channel names: the Railgun page host
// (`com.zcash.wallet/railgun`), the keep-awake flag (`com.zcash.wallet/screen_awake`), the settlement reminder
// (`com.zcash.wallet/haptics`, `settlementDeadline`) and the session lifecycle (`flutter/lifecycle`). Registered before
// Dart's bootstrap can ask anything of them.
void register_private_usd_channels(FlView* view, GtkWindow* window, GtkApplication* application);

#endif  // RUNNER_PRIVATE_USD_PRIVATE_USD_CHANNELS_H_
