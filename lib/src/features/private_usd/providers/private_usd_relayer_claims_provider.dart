import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_secure_store.dart';
import 'private_usd_switch_setting.dart';

/// Where the relayer-claims setting is kept.
class PrivateUsdRelayerClaimsStore extends PrivateUsdSwitchStore {
  const PrivateUsdRelayerClaimsStore(AppSecureStore storage)
    : super(storage, 'vizor_private_usd_relayer_claims_v1');
}

final privateUsdRelayerClaimsStoreProvider =
    Provider<PrivateUsdRelayerClaimsStore>(
      (_) => PrivateUsdRelayerClaimsStore(AppSecureStore.instance),
    );

/// Whether a new bridge to private USD hands its claim to the relayer once
/// its ZEC is out, so the user can leave before it finishes (Settings, on by
/// default). Each bridge keeps the choice it started with.
final privateUsdRelayerClaimsProvider =
    AsyncNotifierProvider<PrivateUsdRelayerClaimsNotifier, bool>(
      PrivateUsdRelayerClaimsNotifier.new,
    );

class PrivateUsdRelayerClaimsNotifier extends PrivateUsdSwitchNotifier {
  @override
  PrivateUsdSwitchStore get store =>
      ref.read(privateUsdRelayerClaimsStoreProvider);
}

/// The relayer-claims setting, once read. One that can't be read fails the
/// bridge rather than fall back to the default, which the user may have
/// turned off; the next try reads it again.
Future<bool> privateUsdRelayerClaimsOf(Ref ref) async {
  try {
    return await ref.read(privateUsdRelayerClaimsProvider.future);
  } catch (_) {
    ref.invalidate(privateUsdRelayerClaimsProvider);
    rethrow;
  }
}
