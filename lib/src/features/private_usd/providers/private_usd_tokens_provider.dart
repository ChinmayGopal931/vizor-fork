import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/network_privacy_provider.dart';
import '../../../rust/api/private_usd.dart' as rust;
import '../services/private_usd_attestation.dart';
import '../services/private_usd_tokens_service.dart';
import 'private_usd_engine_provider.dart';

/// The platform's attestation key, over the channel.
final privateUsdAttestationProvider = Provider<PrivateUsdAttester>(
  (_) => const PrivateUsdAttestation(),
);

/// The makers' Privacy Pass tokens (plan M4).
final privateUsdTokensServiceProvider = Provider<PrivateUsdTokensService>(
  (ref) => PrivateUsdTokensService(
    backend: ref.watch(privateUsdSwapBackendProvider),
    attestation: ref.watch(privateUsdAttestationProvider),
  ),
);

/// What the device holds of the makers' tokens, read as a convert flow
/// opens; null when it cannot be read. Nothing is asked of anyone.
final privateUsdTokensStatusProvider =
    FutureProvider.autoDispose<rust.ApiTokenStatus?>(
      (ref) => ref.watch(privateUsdTokensServiceProvider).status(),
    );

/// Whether the review screens disclose the link between fetching tokens and
/// spending them: a maker asks for tokens and Tor is off, so the issuer and
/// the maker see the same address (reference §5.9, D10).
final privateUsdTokensTorOffDisclosureProvider = Provider.autoDispose<bool>((
  ref,
) {
  final status = ref.watch(privateUsdTokensStatusProvider).value;
  final privacy = ref.watch(networkPrivacyProvider);
  return (status?.makerAsks ?? false) && !privacy.torEnabled;
});
