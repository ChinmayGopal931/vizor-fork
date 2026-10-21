import 'package:flutter/foundation.dart';

import '../../../rust/api/private_usd.dart' as rust;

/// Where an account's outgoing private payment in flight stands (a send, a
/// withdrawal or a conversion's escrow payment): only what the app observes,
/// never an estimate.
@immutable
sealed class PrivateUsdPendingPayment {
  const PrivateUsdPendingPayment();
}

/// The page proves it; [percent] is the SDK's proof progress.
final class PrivateUsdPaymentProving extends PrivateUsdPendingPayment {
  const PrivateUsdPaymentProving(this.percent);

  final int percent;

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdPaymentProving && other.percent == percent;

  @override
  int get hashCode => percent.hashCode;
}

/// A send kept and posted, not seen in a block yet. [postedAt] is when it
/// was kept, right before its first post: the log keeps only the last
/// post's time, which a repost would move.
final class PrivateUsdPaymentWaitingForBlock extends PrivateUsdPendingPayment {
  const PrivateUsdPaymentWaitingForBlock(this.postedAt);

  final DateTime postedAt;

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdPaymentWaitingForBlock && other.postedAt == postedAt;

  @override
  int get hashCode => postedAt.hashCode;
}

/// Seen in a block, and the balance has not synced since.
final class PrivateUsdPaymentUpdatingBalance extends PrivateUsdPendingPayment {
  const PrivateUsdPaymentUpdatingBalance();

  @override
  bool operator ==(Object other) => other is PrivateUsdPaymentUpdatingBalance;

  @override
  int get hashCode => (PrivateUsdPaymentUpdatingBalance).hashCode;
}

/// The stage an account's payment in flight is at, or null when none is:
/// proving ([proofProgress], 0..1), a send of [sends] not in a block yet, or
/// a send seen landing at [landedAt] until the balance synced after it. A
/// conversion's escrow payment shows only its proof: its later stages are
/// the conversion's own steps.
PrivateUsdPendingPayment? privateUsdPendingPayment({
  double? proofProgress,
  List<rust.ApiSendRecord> sends = const [],
  DateTime? landedAt,
  DateTime? balanceUpdatedAt,
}) {
  if (proofProgress != null) {
    return PrivateUsdPaymentProving(
      (proofProgress * 100).floor().clamp(0, 100),
    );
  }
  for (final send in sends) {
    if (send.state == rust.ApiSendState.unconfirmed) {
      return PrivateUsdPaymentWaitingForBlock(
        DateTime.fromMillisecondsSinceEpoch(send.sentAt * 1000),
      );
    }
  }
  if (landedAt != null &&
      (balanceUpdatedAt == null || !balanceUpdatedAt.isAfter(landedAt))) {
    return const PrivateUsdPaymentUpdatingBalance();
  }
  return null;
}
