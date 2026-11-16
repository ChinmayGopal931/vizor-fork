import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_messages.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import '../../support/test_l10n.dart';

// What a reverse step the user took says when Rust refuses it.
void main() {
  test('settlement on an Ethereum head minutes behind says Ethereum', () {
    // Rust signs `ready` only on a fresh head (`chainLagging` otherwise).
    for (final code in [
      ApiPrivateUsdErrorCode.chainLagging,
      ApiPrivateUsdErrorCode.ethereumUnreachable,
    ]) {
      expect(
        privateUsdReverseStepMessage(testL10n, code),
        testL10n.privateUsdConvertErrorEthereum,
        reason: code.name,
      );
    }
  });
}
