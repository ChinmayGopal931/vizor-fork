import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/providers/app_foreground_provider.dart';

void main() {
  testWidgets('is foreground while the app is on screen, background once it '
      'is hidden', (tester) async {
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final subscription = container.listen(appInForegroundProvider, (_, _) {});
    addTearDown(subscription.close);

    expect(container.read(appInForegroundProvider), isTrue);

    // A system sheet or the app switcher: still on screen.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(container.read(appInForegroundProvider), isTrue);

    // Hidden and paused are background.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(container.read(appInForegroundProvider), isFalse);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(container.read(appInForegroundProvider), isFalse);

    // Coming back is foreground only once the app is resumed, not while it is
    // merely becoming visible again.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(container.read(appInForegroundProvider), isFalse);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(container.read(appInForegroundProvider), isTrue);
  });

  testWidgets('starts in the state the app is in', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(appInForegroundProvider), isFalse);
  });
}
