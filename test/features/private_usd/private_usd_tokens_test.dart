import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_messages.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_attestation.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_tokens_service.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';

import 'support/fake_private_usd_backend.dart';

// The makers' Privacy Pass tokens (plan M4): the attestation channel's
// answers, the two-phase issuance with its one repeat, and the copy for each
// way it can fail.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PrivateUsdAttestation.channelName);

  void answer(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => handler(call));
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('the channel asks the platform to sign and reads the chain and '
      'signature', () async {
    MethodCall? asked;
    answer((call) {
      asked = call;
      return {
        'chain': ['leaf', 'batch', 'root'],
        'signature': 'sig',
      };
    });
    final signed = await const PrivateUsdAttestation().sign(
      issuerName: 'zecswap-testnet-issuer',
      message: Uint8List.fromList([1, 2, 3]),
    );
    expect(asked!.method, 'sign');
    expect(asked!.arguments, {
      'issuerName': 'zecswap-testnet-issuer',
      'message': [1, 2, 3],
    });
    expect(signed.chain, ['leaf', 'batch', 'root']);
    expect(signed.signature, 'sig');
  });

  test('the platform\'s refusals keep their kind, and a bad answer is the '
      'keystore\'s', () async {
    Future<PrivateUsdAttestationErrorCode> failing(Object? Function() reply) {
      answer((_) => reply());
      return const PrivateUsdAttestation()
          .sign(issuerName: 'x', message: Uint8List(1))
          .then<PrivateUsdAttestationErrorCode>(
            (_) => fail('signed'),
            onError: (Object error) =>
                (error as PrivateUsdAttestationException).code,
          );
    }

    expect(
      await failing(
        () => throw PlatformException(code: 'unavailable', message: 'iOS'),
      ),
      PrivateUsdAttestationErrorCode.unavailable,
    );
    expect(
      await failing(
        () => throw PlatformException(code: 'failed', message: 'busy'),
      ),
      PrivateUsdAttestationErrorCode.keystore,
    );
    expect(
      await failing(() => {'chain': <String>[], 'signature': 'sig'}),
      PrivateUsdAttestationErrorCode.keystore,
    );
    expect(
      await failing(() => 'not a map'),
      PrivateUsdAttestationErrorCode.keystore,
    );
  });

  test('an issuance signs once, and once more on the first refusal', () async {
    final backend = FakePrivateUsdBackend(records: {});
    final attester = _Attester();
    final service = PrivateUsdTokensService(
      backend: backend,
      attestation: attester,
    );
    // Nothing needed: nothing signed.
    expect(await service.issue(), isFalse);
    expect(attester.messages, isEmpty);

    backend.issuance = ApiIssuanceBegin(
      sessionId: BigInt.two,
      issuerName: 'zecswap-mainnet-issuer',
      message: Uint8List.fromList([4, 5]),
    );
    expect(await service.issue(), isTrue);
    expect(attester.messages, [
      [4, 5],
    ]);
    expect(backend.finishes.single.sessionId, BigInt.two);

    backend.finishes.clear();
    backend.finishKinds = const [
      ApiIssuanceKind.signAgain,
      ApiIssuanceKind.exhausted,
    ];
    expect(await service.issue(), isFalse, reason: 'exhausted holds nothing');
    expect(attester.messages.skip(1), [
      [4, 5],
      [9, 9, 9],
    ]);
    expect(backend.finishes.length, 2);

    // A prefetch keeps every failure to itself.
    backend.issuanceError = const ApiPrivateUsdError(
      code: ApiPrivateUsdErrorCode.tokensUnreachable,
      message: 'down',
    );
    await service.prefetch();
    expect(await service.status(), same(backend.tokensStatusValue));
  });

  test('every way tokens can fail has its own words', () {
    expect(
      privateUsdErrorMessage(ApiPrivateUsdErrorCode.noTokensToday),
      PrivateUsdCopy.tokensNoneToday,
    );
    expect(
      privateUsdErrorMessage(ApiPrivateUsdErrorCode.tokensDeviceRefused),
      PrivateUsdCopy.tokensDeviceRefused,
    );
    expect(
      privateUsdErrorMessage(ApiPrivateUsdErrorCode.tokensUnreachable),
      PrivateUsdCopy.tokensUnreachable,
    );
    expect(
      privateUsdErrorMessage(ApiPrivateUsdErrorCode.keystore),
      PrivateUsdCopy.tokensKeystore,
    );
    expect(
      privateUsdProblemMessage(ApiPrivateUsdErrorCode.tokensNeeded),
      PrivateUsdCopy.convertProblemTokens,
    );
    expect(
      privateUsdAttestationMessage(PrivateUsdAttestationErrorCode.unavailable),
      PrivateUsdCopy.tokensUnavailable,
    );
    expect(
      privateUsdAttestationMessage(PrivateUsdAttestationErrorCode.keystore),
      PrivateUsdCopy.tokensKeystore,
    );
  });
}

class _Attester implements PrivateUsdAttester {
  final messages = <List<int>>[];

  @override
  Future<PrivateUsdAttestationSignature> sign({
    required String issuerName,
    required Uint8List message,
  }) async {
    messages.add(message.toList());
    return const PrivateUsdAttestationSignature(
      chain: ['leaf'],
      signature: 'sig',
    );
  }
}
