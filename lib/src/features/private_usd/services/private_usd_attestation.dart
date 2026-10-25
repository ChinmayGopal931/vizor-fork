import 'package:flutter/services.dart';

/// Why the phone could not attest an issuance (plan M4, reference §5.9).
enum PrivateUsdAttestationErrorCode {
  /// The phone makes no attested key: no secure hardware for one, or iOS,
  /// where the issuer has no mode yet. Conversions then need an Android
  /// device while a market maker asks for tokens.
  unavailable,

  /// The keystore failed to make or use the key: try again.
  keystore,
}

class PrivateUsdAttestationException implements Exception {
  const PrivateUsdAttestationException(this.code);

  final PrivateUsdAttestationErrorCode code;

  @override
  String toString() => 'PrivateUsdAttestationException(${code.name})';
}

/// The platform's attestation of an issuance (plan M4, reference §5.9):
/// [PrivateUsdAttestation] over the channel, or a stand-in in tests.
abstract interface class PrivateUsdAttester {
  Future<PrivateUsdAttestationSignature> sign({
    required String issuerName,
    required Uint8List message,
  });
}

/// The install's key's certificate chain (leaf first, DER, base64url without
/// padding) and its `SHA256withECDSA` signature over an issuance's message.
class PrivateUsdAttestationSignature {
  const PrivateUsdAttestationSignature({
    required this.chain,
    required this.signature,
  });

  final List<String> chain;
  final String signature;
}

/// The platform's attestation key for a Privacy Pass issuer, over the
/// `com.zcash.wallet/private_usd_attestation` channel: Android's Keystore
/// signs with a key attested up to Google's root; iOS answers `unavailable`.
/// The key is the platform's to make and keep (one per issuer, remade only
/// once its chain expired); nothing here deletes or names it.
class PrivateUsdAttestation implements PrivateUsdAttester {
  const PrivateUsdAttestation({
    MethodChannel channel = const MethodChannel(channelName),
  }) : _channel = channel;

  static const channelName = 'com.zcash.wallet/private_usd_attestation';

  final MethodChannel _channel;

  /// Signs [message] with the key for [issuerName], making the key first if
  /// there is none. Never log the message or the chain.
  @override
  Future<PrivateUsdAttestationSignature> sign({
    required String issuerName,
    required Uint8List message,
  }) async {
    final Object? answer;
    try {
      answer = await _channel.invokeMethod<Object?>('sign', {
        'issuerName': issuerName,
        'message': message,
      });
    } on PlatformException catch (error) {
      throw PrivateUsdAttestationException(switch (error.code) {
        'unavailable' => PrivateUsdAttestationErrorCode.unavailable,
        _ => PrivateUsdAttestationErrorCode.keystore,
      });
    } on MissingPluginException {
      // No host for the channel: a desktop build.
      throw const PrivateUsdAttestationException(
        PrivateUsdAttestationErrorCode.unavailable,
      );
    }
    if (answer is! Map) {
      throw const PrivateUsdAttestationException(
        PrivateUsdAttestationErrorCode.keystore,
      );
    }
    final chain = answer['chain'];
    final signature = answer['signature'];
    if (chain is! List ||
        chain.isEmpty ||
        chain.any((certificate) => certificate is! String) ||
        signature is! String ||
        signature.isEmpty) {
      throw const PrivateUsdAttestationException(
        PrivateUsdAttestationErrorCode.keystore,
      );
    }
    return PrivateUsdAttestationSignature(
      chain: List.unmodifiable(chain.cast<String>()),
      signature: signature,
    );
  }
}
