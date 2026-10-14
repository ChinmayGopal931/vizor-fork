import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/account_provider.dart';
import '../../../providers/private_usd_lifecycle_provider.dart';
import '../models/private_usd_record_key.dart';
import '../services/private_usd_engine.dart';

/// Every conversion the swap engine has seen, by key, as it last published
/// them. Empty until an engine runs (desktop and builds without Private USD
/// never start one).
final privateUsdConversionsProvider =
    NotifierProvider<
      PrivateUsdConversionsNotifier,
      Map<PrivateUsdRecordKey, PrivateUsdConversionStatus>
    >(PrivateUsdConversionsNotifier.new);

class PrivateUsdConversionsNotifier
    extends Notifier<Map<PrivateUsdRecordKey, PrivateUsdConversionStatus>> {
  @override
  Map<PrivateUsdRecordKey, PrivateUsdConversionStatus> build() => const {};

  /// The engine's latest snapshot.
  void publish(Map<PrivateUsdRecordKey, PrivateUsdConversionStatus> next) =>
      state = next;
}

/// The conversions under way, for every account: the router's synchronous
/// guard keeps a conversion's progress route reachable while its record is
/// here, even when Private USD is otherwise unavailable (D16). It changes
/// only when a conversion starts or ends, so the router refreshes rarely.
final privateUsdUnfinishedProvider =
    NotifierProvider<PrivateUsdUnfinishedNotifier, Set<PrivateUsdRecordKey>>(
      PrivateUsdUnfinishedNotifier.new,
    );

class PrivateUsdUnfinishedNotifier extends Notifier<Set<PrivateUsdRecordKey>> {
  @override
  Set<PrivateUsdRecordKey> build() => const {};

  void publish(Set<PrivateUsdRecordKey> next) {
    if (setEquals(next, state)) return;
    state = Set.unmodifiable(next);
  }

  @override
  bool updateShouldNotify(
    Set<PrivateUsdRecordKey> previous,
    Set<PrivateUsdRecordKey> next,
  ) => !setEquals(previous, next);
}

/// The conversion under way for [accountUuid], if any: only one runs at a
/// time per account (plan §3.5, invariant 16).
PrivateUsdRecordKey? privateUsdUnderWayFor(
  Set<PrivateUsdRecordKey> unfinished,
  String? accountUuid,
) {
  if (accountUuid == null) return null;
  for (final key in unfinished) {
    if (key.accountUuid == accountUuid) return key;
  }
  return null;
}

/// [accountUuid]'s conversions under way, for the account deletion warning
/// (plan §3.5, invariant 15). 0 for a build or a wallet without any.
final privateUsdUnfinishedCountProvider = FutureProvider.autoDispose
    .family<int, String>(
      (ref, accountUuid) =>
          ref.read(privateUsdLifecycleProvider).unfinishedCount([accountUuid]),
    );

/// Every account's conversions under way, for the reset warning.
final privateUsdUnfinishedTotalProvider = FutureProvider.autoDispose<int>((
  ref,
) {
  final accounts = ref.watch(
    accountProvider.select(
      (state) => [
        for (final account in state.value?.accounts ?? const <AccountInfo>[])
          account.uuid,
      ].join(','),
    ),
  );
  return ref
      .read(privateUsdLifecycleProvider)
      .unfinishedCount(accounts.isEmpty ? const [] : accounts.split(','));
});
