import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/account_provider.dart';
import '../../../providers/private_usd_lifecycle_provider.dart';
import '../models/private_usd_record_key.dart';
import '../services/private_usd_engine.dart';

// What the swap engine last published, for the widget tree and the router:
// empty until an engine runs (desktop and builds without Private USD never
// start one). Then the conversions under way as Rust's store counts them,
// for the deletion and reset warnings.

/// Every forward conversion the swap engine has seen, by key.
final privateUsdConversionsProvider =
    NotifierProvider<
      PrivateUsdConversionsNotifier,
      Map<PrivateUsdRecordKey, PrivateUsdConversionStatus>
    >(PrivateUsdConversionsNotifier.new);

class PrivateUsdConversionsNotifier
    extends Notifier<Map<PrivateUsdRecordKey, PrivateUsdConversionStatus>> {
  @override
  Map<PrivateUsdRecordKey, PrivateUsdConversionStatus> build() => const {};

  void publish(Map<PrivateUsdRecordKey, PrivateUsdConversionStatus> next) =>
      state = next;
}

/// Every reverse conversion the swap engine has seen, drafts too, by key.
final privateUsdReverseConversionsProvider =
    NotifierProvider<
      PrivateUsdReverseConversionsNotifier,
      Map<PrivateUsdRecordKey, PrivateUsdReverseStatus>
    >(PrivateUsdReverseConversionsNotifier.new);

class PrivateUsdReverseConversionsNotifier
    extends Notifier<Map<PrivateUsdRecordKey, PrivateUsdReverseStatus>> {
  @override
  Map<PrivateUsdRecordKey, PrivateUsdReverseStatus> build() => const {};

  void publish(Map<PrivateUsdRecordKey, PrivateUsdReverseStatus> next) =>
      state = next;
}

/// The active account's deposits: the last pass, or why it failed. Null
/// until a pass ran, after a lock, and for an account that cannot have
/// deposits.
final privateUsdDepositsProvider =
    NotifierProvider<PrivateUsdDepositsNotifier, PrivateUsdDepositsStatus?>(
      PrivateUsdDepositsNotifier.new,
    );

class PrivateUsdDepositsNotifier extends Notifier<PrivateUsdDepositsStatus?> {
  @override
  PrivateUsdDepositsStatus? build() => null;

  void publish(PrivateUsdDepositsStatus? next) => state = next;
}

/// The conversions under way in either direction, for every account: the
/// router's synchronous guard keeps a conversion's progress route reachable
/// while its record is here, even when Private USD is otherwise unavailable.
final privateUsdUnfinishedProvider =
    NotifierProvider<PrivateUsdUnfinishedNotifier, Set<PrivateUsdRecordKey>>(
      PrivateUsdUnfinishedNotifier.new,
    );

class PrivateUsdUnfinishedNotifier extends Notifier<Set<PrivateUsdRecordKey>> {
  @override
  Set<PrivateUsdRecordKey> build() => const {};

  void publish(Set<PrivateUsdRecordKey> next) => state = Set.unmodifiable(next);

  // Only a conversion starting or ending notifies, so the router refreshes
  // rarely.
  @override
  bool updateShouldNotify(
    Set<PrivateUsdRecordKey> previous,
    Set<PrivateUsdRecordKey> next,
  ) => !setEquals(previous, next);
}

/// The conversion under way for [accountUuid], if any: only one runs at a
/// time per account.
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

/// [accountUuid]'s conversions under way, for the account deletion warning.
/// 0 for a build or a wallet without any.
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
      (state) => state.value?.accounts ?? const <AccountInfo>[],
    ),
  );
  return ref.read(privateUsdLifecycleProvider).unfinishedCount([
    for (final account in accounts) account.uuid,
  ]);
});
