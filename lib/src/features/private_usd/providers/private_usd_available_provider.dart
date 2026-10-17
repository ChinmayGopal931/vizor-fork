import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_bootstrap.dart';
import '../../../core/config/private_usd_feature_config.dart';
import '../../../core/layout/app_form_factor.dart';
import '../../../providers/account_provider.dart';
import '../../../rust/api/private_usd.dart' as rust_private_usd;
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

/// Asks the platform's Railgun host whether the page runs here; replaced in
/// tests.
final railgunHostSupportQueryProvider = Provider<Future<bool?> Function()>(
  (_) => queryRailgunHostSupported,
);

/// Whether this platform's Railgun host can run the page (iOS plan XI9): the
/// bootstrap's answer, so it is known from the first frame. When the iOS
/// handler had not answered yet, it counts as no until it is asked again after
/// the first frame.
final railgunHostSupportedProvider =
    NotifierProvider<RailgunHostSupportedNotifier, bool>(
      RailgunHostSupportedNotifier.new,
    );

class RailgunHostSupportedNotifier extends Notifier<bool> {
  @override
  bool build() {
    final known = ref.watch(appBootstrapProvider).railgunHostSupported;
    if (known != null) return known;
    WidgetsBinding.instance.addPostFrameCallback((_) => _askAgain());
    return false;
  }

  Future<void> _askAgain() async {
    final supported = await ref.read(railgunHostSupportQueryProvider)();
    if (ref.mounted && supported == true) state = true;
  }
}

/// Whether the active account sees Private USD (plan reference §8.3). The
/// banner and conversion progress of a swap under way do not follow it (D16).
final privateUsdAvailableProvider = Provider<bool>((ref) {
  // Const, so desktop builds and builds without the define drop the rest.
  if (!kVizorPrivateUsdEnabled || kAppFormFactor != AppFormFactor.mobile) {
    return false;
  }
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

/// The availability rule on its own: the build define, a mobile build on a
/// platform that hosts the page, a deployment for the network, the kill
/// switch not off, and a software account with a ZIP-32 index (hardware
/// accounts have no seed on the phone; D6, D8).
bool privateUsdAvailableFor({
  required bool enabled,
  required AppFormFactor formFactor,
  required TargetPlatform platform,
  required bool hostSupported,
  required bool hasDeployment,
  required bool killSwitchAvailable,
  required AccountInfo? activeAccount,
}) {
  return enabled &&
      formFactor == AppFormFactor.mobile &&
      privateUsdPlatformHostsPage(
        platform: platform,
        hostSupported: hostSupported,
      ) &&
      hasDeployment &&
      killSwitchAvailable &&
      activeAccount != null &&
      !activeAccount.isHardware &&
      activeAccount.zip32AccountIndex != null;
}

/// Whether [platform] runs the Railgun page (iOS plan XI9): every Android
/// build, and iOS where its host says so (iOS 17 and later, plan DI2).
bool privateUsdPlatformHostsPage({
  required TargetPlatform platform,
  required bool hostSupported,
}) =>
    platform == TargetPlatform.android ||
    (platform == TargetPlatform.iOS && hostSupported);
