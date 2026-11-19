import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_security_provider.dart';

/// What desktop's neon pieces remember from one page to the next.
///
/// Every desktop page builds its own sidebar and Home its own balance sign,
/// so neither keeps state across a navigation. This keeps what the light
/// needs: which sidebar row was lit, so the next page's sidebar crossfades
/// its light from that row, and whether the balance sign has switched on
/// since the wallet was unlocked, so it flickers on once rather than on every
/// return to Home.
///
/// Plain fields, not provider state: nothing rebuilds when they change.
class DesktopNeonSession {
  /// The sidebar destination lit on the last page that drew the sidebar.
  String? sidebarLitDestination;

  /// The balance sign has switched on since the last unlock.
  bool homeSignLit = false;
}

final desktopNeonSessionProvider = Provider<DesktopNeonSession>((ref) {
  final session = DesktopNeonSession();
  // Locking ends the session: the sign switches on again after the unlock.
  ref.listen(appSecurityProvider.select((state) => state.requiresUnlock), (
    _,
    locked,
  ) {
    if (locked) session.homeSignLit = false;
  });
  return session;
});
