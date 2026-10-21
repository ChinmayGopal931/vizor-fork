import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_record_key.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_engine_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_refunds_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_unfinished_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_engine.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_reverse_use_cases.dart';

import 'support/fake_private_usd_backend.dart';

void main() {
  const account = 'account-1';

  testWidgets('a refund of another deployment says so without a check', (
    tester,
  ) async {
    final record = previewPrivateUsdReverseRecord(
      phase: ApiReversePhase.refunded,
      otherDeployment: true,
    );
    final backend = FakePrivateUsdBackend(records: {});
    backend.reverse[account] = [record];
    final engine = PrivateUsdEngine(
      backend: backend,
      readMnemonic: (_) async => Uint8List(32),
      allowed: () => true,
      now: () => tester.binding.clock.now(),
    );
    final container = ProviderContainer(
      overrides: [privateUsdEngineProvider.overrideWithValue(engine)],
    );
    container.read(privateUsdReverseConversionsProvider.notifier).publish({
      PrivateUsdRecordKey(
        accountUuid: account,
        direction: PrivateUsdDirection.reverse,
        index: record.index,
      ): PrivateUsdReverseStatus(
        record: record,
      ),
    });
    container.listen(privateUsdRefundsProvider(account), (_, _) {});
    await tester.pump();

    final state = container.read(privateUsdRefundsProvider(account));
    expect(state.loaded, isTrue);
    expect(state.refreshing, isFalse);
    final row = state.rows.single;
    expect(row.otherDeployment, isTrue);
    // The fake answers no check: one asked for would have failed.
    expect(row.checkFailed, isFalse);
    expect(row.recoverable, isNull);

    container.dispose();
    await engine.dispose();
  });
}
