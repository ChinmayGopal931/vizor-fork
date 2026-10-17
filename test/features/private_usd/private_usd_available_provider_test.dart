import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/layout/app_form_factor.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/private_usd_engine_host.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_available_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_engine_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_host_channel.dart';
import 'package:zcash_wallet/src/providers/account_models.dart';

// Plan reference §8.3: the define, a mobile build on a platform that hosts the
// page (Android, or iOS 17 and later: iOS plan XI9), a deployment, the kill
// switch not off, and a software account with a ZIP-32 index.
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
    bool hostSupported = true,
    bool hasDeployment = true,
    bool killSwitchAvailable = true,
    AccountInfo? activeAccount = software,
  }) => privateUsdAvailableFor(
    enabled: enabled,
    formFactor: formFactor,
    platform: platform,
    hostSupported: hostSupported,
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
      'iOS below 17': available(
        platform: TargetPlatform.iOS,
        hostSupported: false,
      ),
      'macOS': available(platform: TargetPlatform.macOS),
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

  // iOS plan XI9: iOS 16 hidden, iOS 17 shown, Android unchanged.
  test('the availability matrix by platform and host support', () {
    expect(
      available(platform: TargetPlatform.iOS, hostSupported: false),
      isFalse,
      reason: 'iOS 16',
    );
    expect(
      available(platform: TargetPlatform.iOS, hostSupported: true),
      isTrue,
      reason: 'iOS 17',
    );
    for (final hostSupported in [true, false]) {
      expect(
        available(hostSupported: hostSupported),
        isTrue,
        reason: 'Android does not ask its host ($hostSupported)',
      );
    }
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      expect(available(platform: platform), isFalse, reason: platform.name);
    }
    // Every other condition still applies on iOS.
    expect(
      available(
        platform: TargetPlatform.iOS,
        hostSupported: true,
        killSwitchAvailable: false,
      ),
      isFalse,
    );
    expect(
      available(
        platform: TargetPlatform.iOS,
        hostSupported: true,
        activeAccount: const AccountInfo(
          uuid: 'ledger',
          name: 'Ledger',
          order: 1,
          isHardware: true,
          hardwareSignerKind: HardwareSignerKind.ledger,
          zip32AccountIndex: 0,
        ),
      ),
      isFalse,
    );
  });

  // The swap engine runs for every account's conversions (D14) whatever the
  // kill switch or the active account, but only in mobile builds with the
  // define and a deployment, on a platform that hosts the page: desktop stays
  // inert.
  test('the swap engine runs only on a mobile build that hosts the page, '
      'with a deployment', () {
    bool enabled({
      bool define = true,
      AppFormFactor formFactor = AppFormFactor.mobile,
      TargetPlatform platform = TargetPlatform.android,
      bool hostSupported = true,
      bool hasDeployment = true,
    }) => privateUsdEngineEnabledFor(
      enabled: define,
      formFactor: formFactor,
      platform: platform,
      hostSupported: hostSupported,
      hasDeployment: hasDeployment,
    );

    expect(enabled(), isTrue);
    expect(enabled(hostSupported: false), isTrue, reason: 'Android');
    expect(enabled(define: false), isFalse);
    expect(enabled(formFactor: AppFormFactor.desktop), isFalse);
    expect(
      enabled(platform: TargetPlatform.iOS, hostSupported: false),
      isFalse,
      reason: 'iOS 16',
    );
    expect(enabled(platform: TargetPlatform.iOS), isTrue, reason: 'iOS 17');
    expect(enabled(platform: TargetPlatform.macOS), isFalse);
    expect(enabled(hasDeployment: false), isFalse);
  });

  group('the host support known from the bootstrap', () {
    ProviderContainer container({
      required bool? fromBootstrap,
      Future<bool?> Function()? query,
    }) {
      final container = ProviderContainer(
        overrides: [
          appBootstrapProvider.overrideWithValue(
            AppBootstrapState(
              initialLocation: '/home',
              initialAccountState: const AccountState(),
              initialSyncSnapshot: AppSyncSnapshot.empty,
              network: 'test',
              rpcEndpointConfig: defaultRpcEndpointConfig('test'),
              themeMode: ThemeMode.dark,
              privacyModeEnabled: false,
              isPasswordConfigured: true,
              isUnlocked: true,
              passwordRotationRecoveryFailed: false,
              railgunHostSupported: fromBootstrap,
            ),
          ),
          if (query != null)
            railgunHostSupportQueryProvider.overrideWithValue(query),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('is the bootstrap answer from the first read', () {
      expect(
        container(fromBootstrap: true).read(railgunHostSupportedProvider),
        isTrue,
      );
      expect(
        container(fromBootstrap: false).read(railgunHostSupportedProvider),
        isFalse,
      );
    });

    testWidgets('an unknown answer is no until it is asked again after the '
        'first frame', (tester) async {
      var asked = 0;
      final providers = container(
        fromBootstrap: null,
        query: () async {
          asked++;
          return true;
        },
      );

      expect(providers.read(railgunHostSupportedProvider), isFalse);
      expect(asked, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(asked, 1);
      expect(providers.read(railgunHostSupportedProvider), isTrue);
    });

    testWidgets('an answer that stays unknown keeps it hidden', (tester) async {
      final providers = container(fromBootstrap: null, query: () async => null);

      providers.read(railgunHostSupportedProvider);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(providers.read(railgunHostSupportedProvider), isFalse);
    });
  });

  group('asking the host', () {
    const channel = MethodChannel('com.zcash.wallet/railgun');

    Future<bool?> ask(
      Future<Object?>? Function(MethodCall call)? handler, {
      TargetPlatform platform = TargetPlatform.iOS,
    }) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      return queryRailgunHostSupported(channel: channel, platform: platform);
    }

    setUp(TestWidgetsFlutterBinding.ensureInitialized);

    test('takes its answer', () async {
      expect(await ask((call) async => call.method == 'supported'), isTrue);
      expect(await ask((call) async => false), isFalse);
    });

    test('no handler is unknown on iOS and no elsewhere', () async {
      expect(await ask(null), isNull);
      expect(await ask(null, platform: TargetPlatform.android), isFalse);
      expect(await ask(null, platform: TargetPlatform.macOS), isFalse);
    });

    test('a failure is no', () async {
      expect(
        await ask((call) async => throw PlatformException(code: 'FAILED')),
        isFalse,
      );
    });
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
