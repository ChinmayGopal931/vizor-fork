import '../../../core/config/private_usd_feature_config.dart';
import '../../../rust/api/private_usd.dart' as rust;
import 'private_usd_attestation.dart';
import 'private_usd_swap_backend.dart';

/// The makers' Privacy Pass tokens, fetched ahead for the day's challenge
/// (X11): Rust begins the issuance (the issuer's key, the blinded batch and
/// an attestation challenge), the phone's keystore signs its message, and
/// Rust finishes it and holds the tokens. The first refusal is signed again
/// once, over a fresh challenge; the second refuses the device. Rust decides
/// whether anything is needed at all: nothing is asked of the issuer unless
/// the maker's info shows it takes tokens.
class PrivateUsdTokensService {
  PrivateUsdTokensService({
    required PrivateUsdSwapBackend backend,
    required PrivateUsdAttester attestation,
  }) : _backend = backend,
       _attestation = attestation;

  final PrivateUsdSwapBackend _backend;
  final PrivateUsdAttester _attestation;

  /// Fetches today's tokens when the maker asks and none are held: whether
  /// tokens are held after. Throws the Rust error (`TokensRefused`,
  /// `TokensUnreachable`, `TokensDeviceRefused`, …) or the attestation's
  /// ([PrivateUsdAttestationException]).
  Future<bool> issue() async {
    final begin = await _backend.tokensIssuanceBegin();
    if (begin == null) return false;
    var signed = await _attestation.sign(
      issuerName: begin.issuerName,
      message: begin.message,
    );
    var finish = await _backend.tokensIssuanceFinish(
      sessionId: begin.sessionId,
      chain: signed.chain,
      signature: signed.signature,
    );
    if (finish.kind == rust.ApiIssuanceKind.signAgain) {
      final next = finish.next;
      if (next == null) {
        throw StateError('a refusal to sign again without its message');
      }
      signed = await _attestation.sign(
        issuerName: begin.issuerName,
        message: next,
      );
      finish = await _backend.tokensIssuanceFinish(
        sessionId: begin.sessionId,
        chain: signed.chain,
        signature: signed.signature,
      );
    }
    return finish.kind == rust.ApiIssuanceKind.issued;
  }

  /// [issue] with every failure kept to a debug line: a fetch ahead is a
  /// convenience, and an accept asks again when it must.
  Future<void> prefetch() async {
    try {
      await issue();
    } on rust.ApiPrivateUsdError catch (error) {
      privateUsdLog('the token prefetch failed (${error.code.name})');
    } on PrivateUsdAttestationException catch (error) {
      privateUsdLog('the token prefetch failed (${error.code.name})');
    } catch (error) {
      privateUsdLog('the token prefetch failed (${error.runtimeType})');
    }
  }

  /// What the device holds; null when it cannot be read.
  Future<rust.ApiTokenStatus?> status() async {
    try {
      return await _backend.tokensStatus();
    } catch (error) {
      privateUsdLog('the token status failed (${error.runtimeType})');
      return null;
    }
  }
}
