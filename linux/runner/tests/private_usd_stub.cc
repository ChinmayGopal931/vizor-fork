// The runner's own tests substitute Flutter (flutter_stub.cc); Shielded USD's channels need a real engine, so they
// are left out of those builds.
#include "private_usd/private_usd_channels.h"

void register_private_usd_channels(FlView*, GtkWindow*, GtkApplication*) {}
