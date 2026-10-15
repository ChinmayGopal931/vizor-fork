import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the app is in the foreground: on screen, whether or not it has
/// focus. A system sheet or the app switcher only makes it inactive; it is
/// background once the platform hides it.
///
/// Work that talks to a server for a screen nobody can see waits on this, so a
/// request is never made on behalf of a hidden app. It reads
/// [AppLifecycleState] the way `AppLifecycleListener.onHide` / `onResume` do,
/// which is also how the other foreground-only providers decide.
class AppForegroundNotifier extends Notifier<bool> {
  @override
  bool build() {
    final listener = AppLifecycleListener(
      onHide: () => state = false,
      onResume: () => state = true,
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
