import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_bootstrap.dart';
import '../../../core/layout/app_form_factor.dart' show kDesktopFormFactor;
import '../../../core/storage/app_secure_store.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_switch_setting.dart';

/// Where the archive-sync setting is kept.
class PrivateUsdArchiveSyncStore extends PrivateUsdSwitchStore {
  const PrivateUsdArchiveSyncStore(AppSecureStore storage)
    : super(storage, 'vizor_private_usd_archive_sync_v1');
}

final privateUsdArchiveSyncStoreProvider = Provider<PrivateUsdArchiveSyncStore>(
  (_) => PrivateUsdArchiveSyncStore(AppSecureStore.instance),
);

/// Whether the Railgun page can read Railgun's history from Anon's archive
/// here: Ethereum's archive, which Android's host fetches for the page, and
/// the Mac's and Linux's where they host the page; iOS's host starts the page
/// without it. Which host fetches it is an OS difference, not a layout one;
/// the Mac's and Linux's are desktop's alone.
final privateUsdArchiveAvailableProvider = Provider<bool>((ref) {
  final fetched = switch (defaultTargetPlatform) {
    TargetPlatform.android => true,
    TargetPlatform.macOS || TargetPlatform.linux =>
      kDesktopFormFactor && ref.watch(railgunHostSupportedProvider),
    _ => false,
  };
  if (!fetched) return false;
  final network = ref.watch(appBootstrapProvider).network;
  return ref.watch(privateUsdDeploymentProvider(network))?.railgunNetwork ==
      'mainnet';
});

/// Whether the Railgun page reads Railgun's history from Anon's archive
/// before rail-squid where it can (Settings, on by default). Changing it
/// closes the page, and the next one starts with the new choice.
final privateUsdArchiveSyncProvider =
    AsyncNotifierProvider<PrivateUsdArchiveSyncNotifier, bool>(
      PrivateUsdArchiveSyncNotifier.new,
    );

class PrivateUsdArchiveSyncNotifier extends PrivateUsdSwitchNotifier {
  @override
  PrivateUsdSwitchStore get store =>
      ref.read(privateUsdArchiveSyncStoreProvider);
}

/// Whether a page starting now reads the archive. A setting that can't be
/// read leaves it off: rail-squid alone is how the page synced before.
Future<bool> privateUsdArchiveSyncOf(Ref ref) async {
  if (!ref.read(privateUsdArchiveAvailableProvider)) return false;
  try {
    return await ref.read(privateUsdArchiveSyncProvider.future);
  } catch (_) {
    ref.invalidate(privateUsdArchiveSyncProvider);
    return false;
  }
}
