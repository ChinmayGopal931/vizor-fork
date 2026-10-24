import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../providers/zec_price_change_provider.dart'
    show zecHomeUsdUnitPriceProvider;
import '../../../../providers/account_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../models/private_usd_record_key.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../providers/private_usd_convert_provider.dart';
import '../../providers/private_usd_engine_provider.dart';
import '../../providers/private_usd_relayer_claims_provider.dart';
import '../../providers/private_usd_reverse_convert_provider.dart';
import '../../widgets/mobile/private_usd_convert_views.dart';

/// What `/private-usd/convert/review` carries. The review reads the convert
/// flow's state; this only proves the route was opened from it.
class PrivateUsdReviewArgs {
  const PrivateUsdReviewArgs({this.direction = PrivateUsdDirection.forward});

  final PrivateUsdDirection direction;
}

/// `/private-usd/convert`: ZEC → private USD, or private USD → ZEC with
/// `?to=zec` or the direction switch. A conversion found under way shows
/// instead.
class MobilePrivateUsdConvertScreen extends ConsumerStatefulWidget {
  const MobilePrivateUsdConvertScreen({
    this.initialDirection = PrivateUsdDirection.forward,
    super.key,
  });

  final PrivateUsdDirection initialDirection;

  @override
  ConsumerState<MobilePrivateUsdConvertScreen> createState() =>
      _MobilePrivateUsdConvertScreenState();
}

class _MobilePrivateUsdConvertScreenState
    extends ConsumerState<MobilePrivateUsdConvertScreen> {
  final _amount = TextEditingController();
  final _focus = FocusNode();
  late var _direction = widget.initialDirection;

  bool get _reverse => _direction == PrivateUsdDirection.reverse;

  @override
  void initState() {
    super.initState();
    // Opened while a conversion is under way, or after the app died
    // mid-accept: its progress shows instead.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final account = ref.read(accountProvider).value?.activeAccountUuid;
      final underWay = account == null
          ? null
          : ref.read(privateUsdUnderWayProvider(account));
      if (underWay != null) {
        _showProgress(underWay.path);
        return;
      }
      unawaited(
        _reverse
            ? ref.read(privateUsdReverseConvertProvider.notifier).findUnderWay()
            : ref.read(privateUsdConvertProvider.notifier).findUnderWay(),
      );
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The other direction starts empty.
  void _switchDirection() {
    setState(() {
      _direction = _reverse
          ? PrivateUsdDirection.forward
          : PrivateUsdDirection.reverse;
      _amount.clear();
    });
  }

  void _syncAmount(String text) {
    if (_amount.text != text) {
      _amount.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  void _showProgress(PrivateUsdRoutePath path) {
    if (!mounted) return;
    context.pushReplacement(path.location);
  }

  /// Opens the review. Once a conversion is accepted, its progress replaces
  /// the convert flow, so back from it lands on `/private-usd`.
  Future<void> _review<S extends PrivateUsdConvertFlowState<S>>(
    PrivateUsdConvertFlowNotifier<S> notifier,
  ) async {
    if (!notifier.openReview()) return;
    final shown = await context.push<PrivateUsdRoutePath>(
      '/private-usd/convert/review',
      extra: PrivateUsdReviewArgs(direction: _direction),
    );
    if (!mounted) return;
    if (shown != null) {
      _showProgress(shown);
      return;
    }
    notifier.leaveReview();
  }

  VoidCallback? _directionSwitch<S extends PrivateUsdConvertFlowState<S>>(
    S state,
  ) => state.step == PrivateUsdConvertStep.amount && !state.quoting
      ? _switchDirection
      : null;

  @override
  Widget build(BuildContext context) {
    final uuid = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    final privacyModeEnabled = ref.watch(privacyModeProvider);
    if (_reverse) {
      ref.listen(privateUsdReverseConvertProvider.select((s) => s.underWay), (
        _,
        path,
      ) {
        if (path != null) _showProgress(path);
      });
      // Max rewrites the amount.
      ref.listen(
        privateUsdReverseConvertProvider.select((s) => s.amountText),
        (_, text) => _syncAmount(text),
      );
      final state = ref.watch(privateUsdReverseConvertProvider);
      // The balance the amount is checked against stays fresh meanwhile.
      if (uuid != null) {
        ref.watch(
          privateUsdBalanceKeepFreshProvider((
            accountUuid: uuid,
            ifUsed: false,
          )),
        );
      }
      final notifier = ref.read(privateUsdReverseConvertProvider.notifier);
      return MobilePrivateUsdReverseConvertView(
        state: state,
        controller: _amount,
        focusNode: _focus,
        privacyModeEnabled: privacyModeEnabled,
        zecUsdPrice: ref.watch(zecHomeUsdUnitPriceProvider),
        onAmountChanged: notifier.onAmountChanged,
        onMax: notifier.onMax,
        onReview: () => _review(notifier),
        onBack: () => context.pop(),
        onSwitchDirection: _directionSwitch(state),
        onViewRefunds: () => context.push('/private-usd/refunds'),
      );
    }
    ref.listen(privateUsdConvertProvider.select((s) => s.underWay), (_, path) {
      if (path != null) _showProgress(path);
    });
    // A quote can rewrite the amount: Max, then what that pays for.
    ref.listen(
      privateUsdConvertProvider.select((s) => s.amountText),
      (_, text) => _syncAmount(text),
    );
    final state = ref.watch(privateUsdConvertProvider);
    final balance = uuid == null
        ? null
        : ref.watch(privateUsdBalanceProvider(uuid)).balances;
    final notifier = ref.read(privateUsdConvertProvider.notifier);
    return MobilePrivateUsdConvertView(
      state: state,
      controller: _amount,
      focusNode: _focus,
      privacyModeEnabled: privacyModeEnabled,
      relayerClaims: ref.watch(privateUsdRelayerClaimsProvider).value ?? true,
      privateUsdAvailable: balance?.spendable,
      zecUsdPrice: ref.watch(zecHomeUsdUnitPriceProvider),
      onAmountChanged: notifier.onAmountChanged,
      onMax: notifier.onMax,
      onReview: () => _review(notifier),
      onBack: () => context.pop(),
      onSwitchDirection: _directionSwitch(state),
    );
  }
}
