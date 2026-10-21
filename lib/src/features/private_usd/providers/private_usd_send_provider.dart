import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/account_provider.dart';
import '../../../providers/app_security_provider.dart';
import '../../../providers/private_usd_lifecycle_provider.dart';
import '../../../rust/api/private_usd.dart' as rust;
import '../../swap/models/swap_token_amount_formatting.dart';
import '../models/private_usd_balances.dart';
import '../models/private_usd_messages.dart';
import '../models/private_usd_send.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_sender.dart';
import '../services/private_usd_spend_guard.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_balance_provider.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_spend_status_provider.dart';
import 'railgun_engine_provider.dart';

/// The Railgun page's send calls; replaced by a fake in tests.
final privateUsdSendPageProvider = Provider<PrivateUsdSendPage>(
  (ref) => RailgunSendPage(ref.watch(railgunEngineProvider)),
);

/// The sender, kept alive with the engine: a send outlives the screen that
/// started it, and settlement runs for the app's lifetime
/// (`PrivateUsdEngineHost` builds it). Settlement passes run after every
/// Railgun sync any use made, on unlock and on an account switch while the
/// log holds a send not seen in a block, and during a send's landing wait.
/// Account deletions and resets drain it through
/// [privateUsdLifecycleProvider].
final privateUsdSenderProvider = Provider<PrivateUsdSender>((ref) {
  final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
  final guard = ref.watch(privateUsdSpendGuardProvider);
  final sender = PrivateUsdSender(
    engine: ref.watch(privateUsdEngineProvider),
    page: ref.watch(privateUsdSendPageProvider),
    backend: ref.watch(privateUsdSendBackendProvider),
    guard: guard,
    maxRelayerFee: privateUsdRelayerFeeCap(deployment),
  );
  final lifecycle = ref.watch(privateUsdLifecycleProvider);
  lifecycle.register(
    owner: sender,
    quiesceAndDrain: sender.quiesceAndDrain,
    resume: sender.resume,
  );
  String? active() => ref.read(accountProvider).value?.activeAccountUuid;
  ref.listen(railgunEngineStateProvider.select((s) => s.lastSync), (
    previous,
    next,
  ) {
    if (next != null && !identical(previous, next)) {
      unawaited(sender.settle(next.accountUuid));
    }
  });
  ref.listen(appSecurityProvider.select((s) => s.requiresUnlock), (_, locked) {
    final uuid = active();
    if (!locked && uuid != null) unawaited(sender.settleIfUnsettled(uuid));
  });
  ref.listen(
    accountProvider.select(
      (s) => s.value?.accounts.map((account) => account.uuid).toSet(),
    ),
    (previous, next) {
      if (previous == null || next == null) return;
      for (final uuid in previous.difference(next)) {
        guard.forget(uuid);
      }
    },
  );
  ref.listen(accountProvider.select((s) => s.value?.activeAccountUuid), (
    previous,
    next,
  ) {
    if (next != null && next != previous) {
      unawaited(sender.settleIfUnsettled(next));
    }
  });
  ref.onDispose(() => lifecycle.unregister(sender));
  // A send a crash or a kill left unconfirmed goes out again once the app
  // may run (the unlock listener covers a locked start).
  scheduleMicrotask(() {
    final uuid = active();
    if (uuid != null) unawaited(sender.settleIfUnsettled(uuid));
  });
  return sender;
});

/// One send or withdrawal's form, review and outcome, per mode, while its
/// screens show.
final privateUsdSendProvider = NotifierProvider.autoDispose
    .family<PrivateUsdSendNotifier, PrivateUsdSendForm, PrivateUsdSendMode>(
      PrivateUsdSendNotifier.new,
    );

/// The send's actions: edit, review (prices the send), send, back. Anything
/// signed never returns to review, where it could be paid again.
class PrivateUsdSendNotifier extends Notifier<PrivateUsdSendForm> {
  PrivateUsdSendNotifier(this.mode);

  final PrivateUsdSendMode mode;
  String? _account;
  int _pricing = 0;

  @override
  PrivateUsdSendForm build() {
    final account = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    _account = account;
    final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
    final tokens = deployment == null
        ? const <PrivateUsdToken>[]
        : PrivateUsdToken.of(deployment);
    final feeToken = tokens
        .where((token) => token.address == deployment?.token.toLowerCase())
        .firstOrNull;
    var form = PrivateUsdSendForm(
      mode: mode,
      networkFee: feeToken == null
          ? null
          : PrivateUsdNetworkFee(token: feeToken),
    );
    if (account != null) {
      // The first dollar there is to send is the default; once one is
      // pinned, a refresh cannot swap it for another.
      final balances = ref.read(privateUsdBalanceProvider(account)).balances;
      form = form.copyWith(token: form.assets(balances).firstOrNull?.token);
      ref.listen(privateUsdBalanceProvider(account), (_, next) {
        if (state.token != null) return;
        final first = state.assets(next.balances).firstOrNull;
        if (first != null) state = state.copyWith(token: first.token);
      });
      unawaited(Future.microtask(_loadMinimum));
    }
    return form;
  }

  PrivateUsdBalances? _balances() {
    final account = _account;
    return account == null
        ? null
        : ref.read(privateUsdBalanceProvider(account)).balances;
  }

  PrivateUsdSpendStatus _status(String account) =>
      ref.read(privateUsdSpendStatusProvider(account));

  Future<void> _loadMinimum() async {
    if (!ref.read(privateUsdEngineEnabledProvider)) return;
    try {
      final minimum = await ref.read(privateUsdSenderProvider).minNetworkFee();
      if (!ref.mounted) return;
      final fee = state.networkFee;
      if (fee != null) {
        state = state.copyWith(networkFee: fee.copyWith(minimum: minimum));
      }
    } catch (_) {
      // Review prices it, or says why it cannot.
    }
  }

  void setAmount(String text) => _edit((f) => f.copyWith(amountText: text));

  void setRecipient(String text) => _edit((f) => f.copyWith(recipient: text));

  void chooseToken(PrivateUsdToken token) =>
      _edit((f) => f.copyWith(token: token, amountText: ''));

  /// "Use it all": what is available, less what the network fee needs.
  /// Returns the amount's new text.
  String? useAll() {
    final asset = state.asset(_balances());
    if (asset == null) return null;
    final units = state.networkFee?.sendable(asset) ?? asset.available;
    final text = swapBaseUnitsToDecimal('$units', asset.token.decimals);
    _edit((f) => f.copyWith(token: asset.token, amountText: text));
    return text;
  }

  // An edit makes any earlier cost and error stale.
  void _edit(PrivateUsdSendForm Function(PrivateUsdSendForm form) update) {
    if (state.phase != PrivateUsdSendPhase.form || state.isBusy) return;
    state = update(state).copyWith(clearCost: true, clearError: true);
  }

  /// "Review": prices the send. True when the review should open.
  Future<bool> review() async {
    final account = _account;
    final form = state;
    if (account == null ||
        form.isBusy ||
        form.phase != PrivateUsdSendPhase.form ||
        !_status(account).canSend) {
      return false;
    }
    final asset = form.asset(_balances());
    final request = asset == null ? null : form.request(asset);
    if (request == null) return false;
    final pricing = ++_pricing;
    state = form.copyWith(isBusy: true, clearError: true);
    String? error;
    PrivateUsdSendCost? cost;
    try {
      cost = await ref.read(privateUsdSenderProvider).cost(account, request);
    } on PrivateUsdSendFeeCapException {
      error = PrivateUsdCopy.sendErrorFeeCap;
    } on rust.ApiPrivateUsdError catch (failure) {
      error = privateUsdSendErrorMessage(failure.code);
    } catch (_) {
      error = PrivateUsdCopy.sendNotSent;
    }
    if (!ref.mounted || pricing != _pricing) return false;
    state = cost == null
        ? state.notSent(error)
        : _priced(state.copyWith(isBusy: false), request, cost);
    return state.phase == PrivateUsdSendPhase.review;
  }

  /// Back while the cost is looked up: it is dropped.
  void cancelPricing() {
    _pricing++;
    if (state.isBusy && state.phase == PrivateUsdSendPhase.form) {
      state = state.copyWith(isBusy: false);
    }
  }

  /// Back from the review to the form; false while a send runs.
  bool leaveReview() {
    if (state.isBusy) return false;
    if (state.phase == PrivateUsdSendPhase.review) {
      state = state.copyWith(
        phase: PrivateUsdSendPhase.form,
        clearCost: true,
        clearError: true,
      );
    }
    return true;
  }

  /// Whether "Send" or "Withdraw" can go now.
  bool get canConfirm {
    final account = _account;
    final form = state;
    return account != null &&
        form.phase == PrivateUsdSendPhase.review &&
        !form.isBusy &&
        form.cost != null &&
        form.reviewed != null &&
        _status(account).canSend &&
        form.canSend(form.reviewed, _balances());
  }

  /// "Send" or "Withdraw": proves, keeps and posts the reviewed send.
  Future<void> confirm() async {
    if (!canConfirm) return;
    final account = _account!;
    final request = state.reviewed!;
    final cost = state.cost!;
    state = state.copyWith(
      phase: PrivateUsdSendPhase.sending,
      isBusy: true,
      clearError: true,
    );
    PrivateUsdSendOutcome outcome;
    try {
      outcome = await ref
          .read(privateUsdSenderProvider)
          .send(
            account,
            request,
            cost,
            onStep: (step) {
              if (ref.mounted && state.phase == PrivateUsdSendPhase.sending) {
                state = state.copyWith(step: step);
              }
            },
          );
    } catch (_) {
      outcome = const PrivateUsdSendNotSent();
    }
    if (!ref.mounted) return;
    final form = state.copyWith(isBusy: false);
    state = switch (outcome) {
      PrivateUsdSendBusy(:final status) => form.copyWith(
        phase: PrivateUsdSendPhase.review,
        error: privateUsdSpendMessage(status) ?? PrivateUsdCopy.paymentPending,
      ),
      PrivateUsdSendNotSent(:final message) => form.notSent(message),
      PrivateUsdSendRepriced(cost: final repriced) => _priced(
        form,
        request,
        repriced,
        error: PrivateUsdCopy.sendFeeRose(
          formatPrivateUsdExact(
            repriced.networkFee,
            form.networkFee?.token.decimals ?? request.token.decimals,
          ),
        ),
      ),
      PrivateUsdSendSent() || PrivateUsdSendUnconfirmed() => form.copyWith(
        phase: PrivateUsdSendPhase.done,
        outcome: outcome,
      ),
    };
  }

  // Under review at the relayer's fee, or back on the form while what it
  // sends leaves too little for that fee.
  PrivateUsdSendForm _priced(
    PrivateUsdSendForm form,
    PrivateUsdSendRequest request,
    PrivateUsdSendCost cost, {
    String? error,
  }) {
    final fee = form.networkFee;
    final priced = form.copyWith(
      networkFee: fee?.copyWith(quoted: cost.networkFee),
      error: error,
      clearError: error == null,
    );
    if (priced.canSend(request, _balances())) {
      return priced.copyWith(
        phase: PrivateUsdSendPhase.review,
        cost: cost,
        reviewed: request,
      );
    }
    return priced.copyWith(phase: PrivateUsdSendPhase.form, clearCost: true);
  }
}
