import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_bootstrap.dart';
import '../../../core/config/private_usd_feature_config.dart';
import '../../../core/layout/app_form_factor.dart';
import '../../../providers/account_provider.dart';
import '../../../rust/api/private_usd.dart' as rust_private_usd;

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
    // Only Android has the Railgun host (an OS behaviour, not a layout
    // choice); `defaultTargetPlatform` so widget tests can pick one.
    platform: defaultTargetPlatform,
    hasDeployment: ref.watch(privateUsdCurrentDeploymentProvider) != null,
    killSwitchAvailable: ref.watch(privateUsdKillSwitchProvider),
    activeAccount: ref.watch(
      accountProvider.select((state) => state.value?.activeAccount),
    ),
  );
});

/// The availability rule on its own: the build define, a mobile Android
/// build, a deployment for the network, the kill switch not off, and a
/// software account with a ZIP-32 index (hardware accounts have no seed on
/// the phone; D6, D8).
bool privateUsdAvailableFor({
  required bool enabled,
  required AppFormFactor formFactor,
  required TargetPlatform platform,
  required bool hasDeployment,
  required bool killSwitchAvailable,
  required AccountInfo? activeAccount,
}) {
  return enabled &&
      formFactor == AppFormFactor.mobile &&
      platform == TargetPlatform.android &&
      hasDeployment &&
      killSwitchAvailable &&
      activeAccount != null &&
      !activeAccount.isHardware &&
      activeAccount.zip32AccountIndex != null;
}
