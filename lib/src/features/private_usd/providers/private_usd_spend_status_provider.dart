import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_pending_payment.dart';
import '../services/private_usd_spend_guard.dart';
import '../services/railgun_engine.dart';
import 'private_usd_balance_provider.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_unfinished_provider.dart';
import 'railgun_engine_provider.dart';

/// [accountUuid]'s spend status: `checking` until its send log is read, then
/// `sending` while a send runs or the log holds one not seen in a block,
/// `converting` while a conversion is under way, `unreadable` when the log
/// does not read, else `available`. Send and Withdraw need `available`.
final privateUsdSpendStatusProvider = NotifierProvider.autoDispose
    .family<PrivateUsdSpendStatusNotifier, PrivateUsdSpendStatus, String>(
      PrivateUsdSpendStatusNotifier.new,
    );

class PrivateUsdSpendStatusNotifier extends Notifier<PrivateUsdSpendStatus> {
  PrivateUsdSpendStatusNotifier(this.accountUuid);

  final String accountUuid;

  @override
  PrivateUsdSpendStatus build() {
    final guard = ref.watch(privateUsdSpendGuardProvider);
    final converting = ref.watch(
      privateUsdUnfinishedProvider.select(
        (keys) => keys.any((key) => key.accountUuid == accountUuid),
      ),
    );
    void update() {
      if (ref.mounted) {
        state = guard.statusFor(accountUuid, converting: converting);
      }
    }

    guard.addListener(update);
    ref.onDispose(() => guard.removeListener(update));
    // Read after build: a read that fails at once must not set state now.
    unawaited(Future.microtask(() => guard.check(accountUuid)));
    return guard.statusFor(accountUuid, converting: converting);
  }
}

/// [accountUuid]'s sends and withdrawals as the guard last read them,
/// newest first (the activity rows on `/private-usd`). Empty in builds
/// without the swap engine.
final privateUsdSendRecordsProvider = NotifierProvider.autoDispose
    .family<PrivateUsdSendRecordsNotifier, List<rust.ApiSendRecord>, String>(
      PrivateUsdSendRecordsNotifier.new,
    );

class PrivateUsdSendRecordsNotifier extends Notifier<List<rust.ApiSendRecord>> {
  PrivateUsdSendRecordsNotifier(this.accountUuid);

  final String accountUuid;

  @override
  List<rust.ApiSendRecord> build() {
    if (!ref.watch(privateUsdEngineEnabledProvider)) return const [];
    final guard = ref.watch(privateUsdSpendGuardProvider);
    void update() {
      if (ref.mounted) state = guard.recordsFor(accountUuid);
    }

    guard.addListener(update);
    ref.onDispose(() => guard.removeListener(update));
    unawaited(Future.microtask(() => guard.check(accountUuid)));
    return guard.recordsFor(accountUuid);
  }
}

/// [accountUuid]'s outgoing payment in flight, as the Private USD screen
/// shows it: the proof's progress while the page proves one (a send, a
/// withdrawal or a conversion's escrow payment), how long a kept send has
/// waited for a block, and that the balance is updating from its block until
/// the balance syncs. Null when none is in flight.
final privateUsdPendingPaymentProvider = Provider.autoDispose
    .family<PrivateUsdPendingPayment?, String>((ref, accountUuid) {
      final proofProgress = ref.watch(
        railgunEngineStateProvider.select(
          (engine) =>
              engine.phase == RailgunEnginePhase.proving &&
                  engine.accountUuid == accountUuid
              ? engine.proof?.progress ?? 0.0
              : null,
        ),
      );
      // The guard notes a landing as it notes the rows, so a new list comes
      // with every landing.
      final sends = ref.watch(privateUsdSendRecordsProvider(accountUuid));
      final balanceUpdatedAt = ref.watch(
        privateUsdBalanceProvider(accountUuid).select((s) => s.updatedAt),
      );
      return privateUsdPendingPayment(
        proofProgress: proofProgress,
        sends: sends,
        landedAt: ref.read(privateUsdSpendGuardProvider).landedAt(accountUuid),
        balanceUpdatedAt: balanceUpdatedAt,
      );
    });
