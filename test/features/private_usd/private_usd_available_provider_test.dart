import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/layout/app_form_factor.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/private_usd_engine_host.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_available_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_engine_provider.dart';
import 'package:zcash_wallet/src/providers/account_models.dart';

// Plan reference §8.3: the define, a mobile Android build, a deployment, the
// kill switch not off, and a software account with a ZIP-32 index.
void main() {
  const software = AccountInfo(
    uuid: 'software',
    name: 'Main',
    order: 0,
    zip32AccountIndex: 0,
  );

  bool available({
    bool enabled = true,
    AppFormFactor formFactor = AppFormFactor.mobile,
    TargetPlatform platform = TargetPlatform.android,
    bool hasDeployment = true,
    bool killSwitchAvailable = true,
    AccountInfo? activeAccount = software,
  }) => privateUsdAvailableFor(
    enabled: enabled,
    formFactor: formFactor,
    platform: platform,
    hasDeployment: hasDeployment,
    killSwitchAvailable: killSwitchAvailable,
    activeAccount: activeAccount,
  );

  test('a software account on a mobile Android build with a deployment', () {
    expect(available(), isTrue);
    expect(
      available(
        activeAccount: const AccountInfo(
          uuid: 'second',
          name: 'Second',
          order: 1,
          zip32AccountIndex: 3,
        ),
      ),
      isTrue,
    );
  });

  test('each missing condition hides it', () {
    final cases = <String, bool>{
      'define off': available(enabled: false),
      'desktop': available(formFactor: AppFormFactor.desktop),
      'iOS': available(platform: TargetPlatform.iOS),
      'no deployment (regtest)': available(hasDeployment: false),
      'kill switch off': available(killSwitchAvailable: false),
      'no active account': available(activeAccount: null),
      'Keystone': available(
        activeAccount: const AccountInfo(
          uuid: 'keystone',
          name: 'Keystone',
          order: 1,
          isHardware: true,
          hardwareSignerKind: HardwareSignerKind.keystone,
          zip32AccountIndex: 0,
        ),
      ),
      'Ledger': available(
        activeAccount: const AccountInfo(
          uuid: 'ledger',
          name: 'Ledger',
          order: 1,
          isHardware: true,
          hardwareSignerKind: HardwareSignerKind.ledger,
          zip32AccountIndex: 0,
        ),
      ),
      'no ZIP-32 index': available(
        activeAccount: const AccountInfo(
          uuid: 'imported',
          name: 'Imported',
          order: 1,
        ),
      ),
    };
    for (final entry in cases.entries) {
      expect(entry.value, isFalse, reason: entry.key);
    }
  });

  // The swap engine runs for every account's conversions (D14) whatever the
  // kill switch or the active account, but only in mobile Android builds
  // with the define and a deployment: desktop stays inert.
  test('the swap engine runs only on a mobile Android build with a '
      'deployment', () {
    bool enabled({
      bool define = true,
      AppFormFactor formFactor = AppFormFactor.mobile,
      TargetPlatform platform = TargetPlatform.android,
      bool hasDeployment = true,
    }) => privateUsdEngineEnabledFor(
      enabled: define,
      formFactor: formFactor,
      platform: platform,
      hasDeployment: hasDeployment,
    );

    expect(enabled(), isTrue);
    expect(enabled(define: false), isFalse);
    expect(enabled(formFactor: AppFormFactor.desktop), isFalse);
    expect(enabled(platform: TargetPlatform.iOS), isFalse);
    expect(enabled(platform: TargetPlatform.macOS), isFalse);
    expect(enabled(hasDeployment: false), isFalse);
  });

  // No test lane builds with VIZOR_PRIVATE_USD_ENABLED, so the host is inert
  // in both, as in desktop builds: it builds no engine and reads nothing.
  testWidgets('without the define the engine host builds no engine', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const PrivateUsdEngineHost(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Text('home'),
          ),
        ),
      ),
    );

    expect(find.text('home'), findsOneWidget);
    expect(container.read(privateUsdEngineEnabledProvider), isFalse);
    expect(container.exists(privateUsdEngineProvider), isFalse);
  });
}
