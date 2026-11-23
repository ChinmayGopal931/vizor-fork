import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_bootstrap.dart';
import '../../../core/config/private_usd_feature_config.dart';
import '../../../core/layout/app_form_factor.dart';
import '../../../providers/account_provider.dart';
import '../../../rust/api/private_usd.dart' as rust_private_usd;
import '../models/private_usd_record_key.dart';
import '../services/railgun_host_channel.dart';

/// The pinned deployment for a wallet network (`main`, `test`); null where
/// Private USD has none (regtest). Dart never duplicates these pins.
final privateUsdDeploymentProvider =
    Provider.family<rust_private_usd.ApiDeployment?, String>(
      (ref, network) => rust_private_usd.privateUsdDeployment(network: network),
    );

/// The deployment for this build's wallet network.
final privateUsdCurrentDeploymentProvider =
    Provider<rust_private_usd.ApiDeployment?>((ref) {
      final network = ref.watch(appBootstrapProvider).network;
      return ref.watch(privateUsdDeploymentProvider(network));
    });

/// The most a relayer may charge for one payment, as [deployment] pins it.
/// Null without a deployment or a readable cap: then no fee is within it.
BigInt? privateUsdRelayerFeeCap(rust_private_usd.ApiDeployment? deployment) =>
    BigInt.tryParse(deployment?.maxRelayerFee ?? '');

/// Whether this build's network pins a windows contract, so bridging runs.
/// Off, Bridge is hidden and its screens redirect; the balance, deposits,
/// sends and withdrawals work either way. The phones and the Mac alike.
final privateUsdBridgeAvailableProvider = Provider<bool>((ref) {
  // Const, so builds without the define drop the rest.
  if (!kPrivateUsdBuildEnabled) return false;
  return ref.watch(privateUsdCurrentDeploymentProvider)?.bridgeAvailable ??
      false;
});

/// Where the router sends a Private USD [location], or null to let it show:
/// home while Private USD is unavailable, except a conversion's progress
/// while [underWay] holds it, and the Private USD screen from the bridge's
/// screens while bridging is off. Any other location is left alone, and
/// nothing is read for it.
String? privateUsdRedirect(
  String location, {
  required bool Function() available,
  required bool Function() bridgeAvailable,
  required bool Function(PrivateUsdRoutePath conversion) underWay,
}) {
  if (!_isRouteOrChild(location, '/private-usd')) return null;
  if (!available()) {
    final conversion = PrivateUsdRoutePath.tryParseLocation(location);
    return conversion != null && underWay(conversion) ? null : '/home';
  }
  if (_isRouteOrChild(location, '/private-usd/convert') && !bridgeAvailable()) {
    return '/private-usd';
  }
  return null;
}

bool _isRouteOrChild(String location, String routePath) =>
    location == routePath || location.startsWith('$routePath/');

/// Asks the platform's Railgun host whether the page runs here; replaced in
/// tests.
final railgunHostSupportQueryProvider = Provider<Future<bool?> Function()>(
  (_) => queryRailgunHostSupported,
);

/// Whether this platform's Railgun host can run the page: the bootstrap's
/// answer, so it is known from the first frame. When the iOS handler had not
/// answered yet, it counts as no until it is asked again after the first
/// frame. Linux is asked after the first frame, and again after a check that
/// took too long ([kRailgunHostSupportRetries]).
final railgunHostSupportedProvider =
    NotifierProvider<RailgunHostSupportedNotifier, bool>(
      RailgunHostSupportedNotifier.new,
    );

/// When Linux's host is asked again after a sandbox check that took too long
/// (a desktop still busy starting): a few times, later and later.
const kRailgunHostSupportRetries = <Duration>[
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 2),
  Duration(minutes: 5),
  Duration(minutes: 10),
];

class RailgunHostSupportedNotifier extends Notifier<bool> {
  Timer? _retry;

  @override
  bool build() {
    ref.onDispose(() => _retry?.cancel());
    final known = ref.watch(appBootstrapProvider).railgunHostSupported;
    if (known != null) return known;
    WidgetsBinding.instance.addPostFrameCallback((_) => _askAgain());
    return false;
  }

  Future<void> _askAgain([int attempt = 0]) async {
    final supported = await ref.read(railgunHostSupportQueryProvider)();
    if (!ref.mounted) return;
    if (supported == true) {
      state = true;
      return;
    }
    // Which OS runs is an OS behaviour, not a layout choice.
    if (supported == null &&
        defaultTargetPlatform == TargetPlatform.linux &&
        attempt < kRailgunHostSupportRetries.length) {
      _retry?.cancel();
      _retry = Timer(
        kRailgunHostSupportRetries[attempt],
        () => unawaited(_askAgain(attempt + 1)),
      );
    }
  }
}

/// Whether the active account sees Private USD. The banner and conversion
/// progress of a swap under way do not follow it.
final privateUsdAvailableProvider = Provider<bool>((ref) {
  // Const, so builds without the define drop the rest.
  if (!kPrivateUsdBuildEnabled) return false;
  return privateUsdAvailableFor(
    enabled: true,
    formFactor: kAppFormFactor,
    // Which OS hosts the Railgun page is an OS behaviour, not a layout choice;
    // `defaultTargetPlatform` so widget tests can pick one.
    platform: defaultTargetPlatform,
    hostSupported: ref.watch(railgunHostSupportedProvider),
    hasDeployment: ref.watch(privateUsdCurrentDeploymentProvider) != null,
    killSwitchAvailable: ref.watch(privateUsdKillSwitchProvider),
    activeAccount: ref.watch(
      accountProvider.select((state) => state.value?.activeAccount),
    ),
  );
});

/// The availability rule on its own: where the swap engine runs
/// ([privateUsdEngineEnabledFor]), with the kill switch not off and a
/// software account with a ZIP-32 index (hardware accounts have no seed on
/// the phone).
bool privateUsdAvailableFor({
  required bool enabled,
  required AppFormFactor formFactor,
  required TargetPlatform platform,
  required bool hostSupported,
  required bool hasDeployment,
  required bool killSwitchAvailable,
  required AccountInfo? activeAccount,
}) =>
    privateUsdEngineEnabledFor(
      enabled: enabled,
      formFactor: formFactor,
      platform: platform,
      hostSupported: hostSupported,
      hasDeployment: hasDeployment,
    ) &&
    killSwitchAvailable &&
    activeAccount != null &&
    !activeAccount.isHardware &&
    activeAccount.zip32AccountIndex != null;

/// Whether this build runs the swap engine at all: the define, a build on a
/// platform that hosts the page for its form factor, and a deployment for
/// the network. It does not follow the active account or the kill switch:
/// conversions under way keep being driven for every account.
bool privateUsdEngineEnabledFor({
  required bool enabled,
  required AppFormFactor formFactor,
  required TargetPlatform platform,
  required bool hostSupported,
  required bool hasDeployment,
}) =>
    enabled &&
    privateUsdPlatformHostsPage(
      formFactor: formFactor,
      platform: platform,
      hostSupported: hostSupported,
    ) &&
    hasDeployment;

/// Whether [platform] runs the Railgun page in a [formFactor] build: on the
/// phones every Android build, and iOS where its host says so (iOS 17 and
/// later); on desktop wherever its host says so: the Mac (macOS 14 and
/// later), Linux (WebKitGTK 4.1 installed, and WebKit's sandbox starts) and
/// Windows (the Evergreen WebView2 Runtime installed).
bool privateUsdPlatformHostsPage({
  required AppFormFactor formFactor,
  required TargetPlatform platform,
  required bool hostSupported,
}) => switch (formFactor) {
  AppFormFactor.mobile =>
    platform == TargetPlatform.android ||
        (platform == TargetPlatform.iOS && hostSupported),
  AppFormFactor.desktop =>
    (platform == TargetPlatform.macOS ||
            platform == TargetPlatform.linux ||
            platform == TargetPlatform.windows) &&
        hostSupported,
};
