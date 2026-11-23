import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/layout/app_form_factor.dart' show kDesktopFormFactor;

/// Whether the app is in the foreground: on screen, whether or not it has
/// focus. A system sheet or the app switcher only makes it inactive; it is
/// background once the platform hides it.
///
/// Work that talks to a server for a screen nobody can see waits on this, so a
/// request is never made on behalf of a hidden app. It reads
/// [AppLifecycleState] the way `AppLifecycleListener.onHide` / `onResume` do;
/// on desktop a window shown again (`onShow`) is the foreground at once,
/// focused or not. Private USD's engine is stricter on the phones: it counts
/// a start only from `resumed`.
class AppForegroundNotifier extends Notifier<bool> {
  @override
  bool build() {
    final listener = AppLifecycleListener(
      onHide: () => state = false,
      onResume: () => state = true,
      onShow: kDesktopFormFactor ? () => state = true : null,
    );
    ref.onDispose(listener.dispose);
    return switch (WidgetsBinding.instance.lifecycleState) {
      null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => false,
    };
  }
}

final appInForegroundProvider = NotifierProvider<AppForegroundNotifier, bool>(
  AppForegroundNotifier.new,
);
