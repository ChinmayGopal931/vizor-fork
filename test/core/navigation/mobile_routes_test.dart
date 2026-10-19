@Tags(['mobile'])
library;

import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoRouteTransitionMixin;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/config/swap_feature_config.dart';
import 'package:zcash_wallet/src/core/layout/mobile/app_mobile_shell.dart';
import 'package:zcash_wallet/src/core/layout/mobile/app_mobile_tab_bar.dart';
import 'package:zcash_wallet/src/core/navigation/mobile_routes.dart';
import 'package:zcash_wallet/src/core/profile_pictures.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/activity/screens/mobile/mobile_activity_screen.dart';
import 'package:zcash_wallet/src/features/home/screens/mobile/mobile_home_screen.dart';
import 'package:zcash_wallet/src/features/pay/screens/mobile/mobile_pay_screen.dart';
import 'package:zcash_wallet/src/features/pay/screens/mobile/mobile_pay_submitted_screen.dart';
import 'package:zcash_wallet/src/features/receive/screens/mobile/mobile_receive_screen.dart';
import 'package:zcash_wallet/src/features/send/models/send_prefill_args.dart';
import 'package:zcash_wallet/src/features/send/screens/mobile/mobile_send_screen.dart';
import 'package:zcash_wallet/src/features/swap/models/swap_activity_navigation.dart';
import 'package:zcash_wallet/src/features/swap/models/swap_models.dart';
import 'package:zcash_wallet/src/features/swap/providers/swap_hardware_signing_service.dart';
import 'package:zcash_wallet/src/features/swap/screens/mobile/mobile_swap_keystone_sign_screen.dart';
import 'package:zcash_wallet/src/features/swap/screens/mobile/mobile_swap_screen.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/providers/sync_failure.dart';
import 'package:zcash_wallet/src/providers/zec_price_change_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;

import '../../fakes/fake_sync_notifier.dart';

const _accountState = AccountState(
  accounts: [
    AccountInfo(
      uuid: 'account-1',
      name: 'Account1',
      order: 0,
      profilePictureId: kDefaultProfilePictureId,
    ),
  ],
  activeAccountUuid: 'account-1',
  activeAddress: 'u1routeraddress',
);

AppBootstrapState _bootstrap() => AppBootstrapState(
  initialLocation: '/home',
  initialAccountState: _accountState,
  initialSyncSnapshot: AppSyncSnapshot.empty,
  network: 'main',
  rpcEndpointConfig: defaultRpcEndpointConfig('main'),
  themeMode: ThemeMode.dark,
  privacyModeEnabled: false,
  isPasswordConfigured: true,
  isUnlocked: true,
  passwordRotationRecoveryFailed: false,
);

GoRouter _router() => GoRouter(
  initialLocation: '/home',
  routes: buildMobileRoutes(entryRoutes: const []),
);

Widget _app(
  GoRouter router, {
  bool swapFeatureEnabled = true,
  SyncState? initialSyncState,
  List<Override> overrides = const [],
}) => ProviderScope(
  overrides: [
    appBootstrapProvider.overrideWithValue(_bootstrap()),
    swapFeatureEnabledProvider.overrideWithValue(swapFeatureEnabled),
    // The coin bob loops forever, which would break pumpAndSettle here;
    // Funded so the home tab shows the Send action used by the push
    // test.
    syncProvider.overrideWith(
      () => FakeSyncNotifier(
        initialSyncState ??
            SyncState(
              accountUuid: 'account-1',
              hasAccountScopedData: true,
              orchardBalance: BigInt.from(100000000),
            ),
      ),
    ),
    ...overrides,
  ],
  child: MaterialApp.router(
    routerConfig: router,
    builder: (_, child) => AppTheme(data: AppThemeData.dark, child: child!),
  ),
);

LocalKey? _sendPageKey(WidgetTester tester) =>
    (ModalRoute.of(tester.element(find.byType(MobileSendScreen)))!.settings
            as Page<dynamic>)
        .key;

void main() {
  test('registers the mobile payment-link intake route', () {
    final paths = buildMobileRoutes(
      entryRoutes: const [],
    ).whereType<GoRoute>().map((route) => route.path);

    expect(paths, contains('/payment-links'));
  });

  test('does not register the removed private review route', () {
    final paths = buildMobileRoutes(
      entryRoutes: const [],
    ).whereType<GoRoute>().map((route) => route.path);

    expect(paths, isNot(contains('/migration/private/review')));
  });

  test('registers the complete mobile coinholder voting route tree', () {
    final paths = buildMobileRoutes(
      entryRoutes: const [],
    ).whereType<GoRoute>().map((route) => route.path).toSet();

    expect(
      paths,
      containsAll({
        '/voting',
        '/voting/poll/:roundId',
        '/voting/poll/:roundId/review',
        '/voting/poll/:roundId/status',
        '/voting/poll/:roundId/submitted',
        '/voting/poll/:roundId/results',
      }),
    );
  });

  test('shows migration options while guarding private-only routes', () {
    final routes = buildMobileRoutes(
      entryRoutes: const [],
    ).whereType<GoRoute>();
    final options = routes.singleWhere(
      (route) => route.path == '/migration/options',
    );
    final notifications = routes.singleWhere(
      (route) => route.path == '/migration/private/notifications',
    );

    expect(options.redirect, isNull);
    expect(notifications.redirect, isNotNull);
  });

  testWidgets('tab shell renders three tabs and Home opens Swap over them', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_router()));
    await tester.pumpAndSettle();

    expect(find.byType(MobileHomeScreen), findsOneWidget);
    final shellRoute = ModalRoute.of(
      tester.element(find.byType(AppMobileShell)),
    );
    expect(shellRoute, isA<CupertinoRouteTransitionMixin<dynamic>>());
    expect(
      tester
          .widget<AppMobileTabBar>(find.byType(AppMobileTabBar))
          .items
          .map((item) => item.label),
      ['Home', 'Activity', 'Settings'],
    );

    // Swap is pushed over the tabs from Home's button, and back returns.
    await tester.tap(find.byKey(const ValueKey('mobile_home_swap')));
    await tester.pumpAndSettle();
    expect(find.byType(MobileSwapScreen), findsOneWidget);
    expect(find.byType(AppMobileShell), findsNothing);
    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();
    expect(find.byType(MobileHomeScreen), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Activity').last);
    await tester.pumpAndSettle();
    expect(find.byType(MobileActivityScreen), findsOneWidget);
    expect(find.byType(MobileHomeScreen), findsNothing);
    expect(find.bySemanticsLabel('Back'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Settings').last);
    await tester.pumpAndSettle();
    // The page title is drawn as an uppercase caption.
    expect(find.text('SETTINGS'), findsOneWidget);
    expect(find.bySemanticsLabel('Back'), findsNothing);
    expect(find.byType(AppMobileShell), findsOneWidget);
  });

  testWidgets('home hides Swap when the swap feature is disabled', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_router(), swapFeatureEnabled: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mobile_home_swap')), findsNothing);
    for (final label in ['Home', 'Activity', 'Settings']) {
      expect(find.bySemanticsLabel(label), findsWidgets);
    }
  });

  testWidgets('home error shortcut switches to the settings tab', (
    tester,
  ) async {
    final router = _router();
    await tester.pumpWidget(
      _app(
        router,
        initialSyncState: SyncState(
          accountUuid: 'account-1',
          hasAccountScopedData: true,
          orchardBalance: BigInt.from(100000000),
          failure: classifySyncFailure('private status coverage incomplete'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('mobile_private_status_coverage_settings')),
    );
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path, '/settings');
    expect(router.canPop(), isFalse);
    expect(find.byType(AppMobileShell), findsOneWidget);
    expect(find.bySemanticsLabel('Back'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Home').last);
    await tester.pumpAndSettle();
    expect(find.byType(MobileHomeScreen), findsOneWidget);
  });

  for (final path in ['/swap/keystone-sign', '/swap/ledger-sign']) {
    for (final extra in [null, 'invalid signing arguments']) {
      testWidgets('$path with invalid arguments returns to the swap tab '
          '($extra)', (tester) async {
        final router = GoRouter(
          initialLocation: path,
          initialExtra: extra,
          routes: buildMobileRoutes(entryRoutes: const []),
        );
        await tester.pumpWidget(_app(router));
        await tester.pumpAndSettle();

        expect(router.routeInformationProvider.value.uri.path, '/swap');
        expect(find.byType(MobileSwapScreen), findsOneWidget);
        expect(find.byType(AppMobileShell), findsOneWidget);
        expect(find.bySemanticsLabel('Back'), findsNothing);
        expect(router.canPop(), isFalse);
        await tester.tap(find.bySemanticsLabel('Home').last);
        await tester.pumpAndSettle();
        expect(find.byType(MobileHomeScreen), findsOneWidget);
      });
    }
  }

  testWidgets('send pushes over the shell with a swipe-back capable page', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_router()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(find.byType(MobileSendScreen), findsOneWidget);
    final route = ModalRoute.of(tester.element(find.byType(MobileSendScreen)));
    expect(route, isA<CupertinoRouteTransitionMixin<dynamic>>());

    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(MobileSendScreen), findsNothing);
    expect(find.byType(MobileHomeScreen), findsOneWidget);
  });

  testWidgets(
    'a ZIP-321 SendPrefillArgs on /send populates the mobile send screen',
    (tester) async {
      final router = _router();
      await tester.pumpWidget(
        _app(
          router,
          // The amount step's price placeholder shimmers forever while the
          // live ZEC/USD price is null, which would hang pumpAndSettle.
          overrides: [zecLiveUsdUnitPriceProvider.overrideWithValue(210)],
        ),
      );
      await tester.pumpAndSettle();

      unawaited(
        router.push<void>(
          '/send',
          extra: const SendPrefillArgs(
            id: 'payment-uri-1',
            source: 'zcash-uri',
            address: 'u1routeraddress',
            amountText: '0.25',
            memoText: '  coffee  ',
            preserveMemoText: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The mobile /send route must unpack SendPrefillArgs (a ZIP-321 payment
      // URI) into the recipient + amount + memo, not drop it like a bare
      // recipient string would.
      final sendScreen = tester.widget<MobileSendScreen>(
        find.byType(MobileSendScreen),
      );
      expect(sendScreen.initialRecipient, 'u1routeraddress');
      expect(sendScreen.initialAmount, '0.25');
      expect(sendScreen.initialMemo, '  coffee  ');
      expect(sendScreen.preserveInitialMemoWhitespace, isTrue);
    },
  );

  testWidgets(
    'a second payment request answered onto /send re-seeds the composer',
    (tester) async {
      final router = _router();
      await tester.pumpWidget(
        _app(
          router,
          overrides: [zecLiveUsdUnitPriceProvider.overrideWithValue(210)],
        ),
      );
      await tester.pumpAndSettle();

      router.go(
        '/send',
        extra: const SendPrefillArgs(
          id: 'payment-uri-1',
          source: kPaymentUriPrefillSource,
          address: 'u1firstrequestaddress',
        ),
      );
      await tester.pumpAndSettle();

      final firstPageKey = _sendPageKey(tester);
      expect(find.text('u1firstrequestaddress'), findsOneWidget);

      // What the payment-request card's Edit does when the user is already
      // standing on /send. A shared page key would update the page in place,
      // and `_MobileSendScreenState` only reads the prefill in `initState`.
      router.go(
        '/send',
        extra: const SendPrefillArgs(
          id: 'payment-uri-2',
          source: kPaymentUriPrefillSource,
          address: 'u1secondrequestaddress',
        ),
      );
      await tester.pumpAndSettle();

      expect(_sendPageKey(tester), isNot(firstPageKey));
      expect(find.text('u1secondrequestaddress'), findsOneWidget);
      expect(find.text('u1firstrequestaddress'), findsNothing);
    },
  );
  testWidgets('send amount and review routes push Cupertino pages', (
    tester,
  ) async {
    final router = _router();
    await tester.pumpWidget(_app(router));
    await tester.pumpAndSettle();

    unawaited(
      router.push<void>(
        '/send/amount',
        extra: const MobileSendAmountArgs(
          sendFlowId: 'flow-1',
          recipient: 'u1routeraddress',
          addressType: 'unified',
          amountText: '0.25',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(MobileSendAmountScreen), findsOneWidget);
    var route = ModalRoute.of(
      tester.element(find.byType(MobileSendAmountScreen)),
    );
    expect(route, isA<CupertinoRouteTransitionMixin<dynamic>>());
    // An amount already composed on the recipient step (a ZIP-321 deep link
    // that stepped back in place) has to reach the pushed amount page.
    final amountScreen = tester.widget<MobileSendScreen>(
      find.descendant(
        of: find.byType(MobileSendAmountScreen),
        matching: find.byType(MobileSendScreen),
      ),
    );
    expect(amountScreen.initialAmount, '0.25');

    unawaited(
      router.push<void>(
        '/send/review',
        extra: MobileSendReviewDraftArgs(
          sendFlowId: 'flow-1',
          recipient: 'u1routeraddress',
          addressType: 'unified',
          amountText: '0.25',
          feeZatoshi: BigInt.from(10000),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(MobileSendReviewScreen), findsOneWidget);
    route = ModalRoute.of(tester.element(find.byType(MobileSendReviewScreen)));
    expect(route, isA<CupertinoRouteTransitionMixin<dynamic>>());
  });

  testWidgets('swap Keystone signing route pushes a Cupertino page', (
    tester,
  ) async {
    final router = _router();
    await tester.pumpWidget(
      _app(
        router,
        overrides: [
          swapHardwareSigningServiceProvider.overrideWithValue(
            const _FakeSwapHardwareSigningService(),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    unawaited(
      router.push<void>(
        '/swap/keystone-sign',
        extra: MobileSwapKeystoneSignArgs(intent: _hardwareSwapIntent),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MobileSwapKeystoneSignScreen), findsOneWidget);
    final route = ModalRoute.of(
      tester.element(find.byType(MobileSwapKeystoneSignScreen)),
    );
    expect(route, isA<CupertinoRouteTransitionMixin<dynamic>>());
    expect(route?.opaque, isTrue);
  });

  testWidgets('receive pushes over a Cupertino shell page', (tester) async {
    await tester.pumpWidget(_app(_router()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Receive'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(MobileReceiveScreen), findsOneWidget);
    final route = ModalRoute.of(
      tester.element(find.byType(MobileReceiveScreen)),
    );
    expect(route, isA<CupertinoRouteTransitionMixin<dynamic>>());

    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(MobileReceiveScreen), findsNothing);
    expect(find.byType(MobileHomeScreen), findsOneWidget);
  });

  testWidgets('payment submitted route pushes a Cupertino page', (
    tester,
  ) async {
    final router = _router();
    await tester.pumpWidget(_app(router));
    await tester.pumpAndSettle();

    unawaited(router.push<void>('/pay/submitted/intent-123'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(MobilePaySubmittedScreen), findsOneWidget);
    final screen = tester.widget<MobilePaySubmittedScreen>(
      find.byType(MobilePaySubmittedScreen),
    );
    expect(screen.intentId, 'intent-123');
    final route = ModalRoute.of(
      tester.element(find.byType(MobilePaySubmittedScreen)),
    );
    expect(route, isA<CupertinoRouteTransitionMixin<dynamic>>());
  });

  testWidgets('pay route forwards prepared-composer navigation state', (
    tester,
  ) async {
    final router = _router();
    await tester.pumpWidget(_app(router));
    await tester.pumpAndSettle();

    unawaited(
      router.push<void>(
        '/pay',
        extra: const PayComposerNavigationArgs(preservePreparedComposer: true),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final screen = tester.widget<MobilePayScreen>(find.byType(MobilePayScreen));
    expect(screen.preservePreparedComposer, isTrue);
  });
}

final _hardwareSwapIntent = SwapIntent(
  id: 'swap-route-hardware',
  pair: 'ZEC -> USDC',
  sellAmount: '0.003 ZEC',
  receiveEstimate: '0.21 USDC',
  provider: 'NEAR Intents',
  status: SwapIntentStatus.awaitingDeposit,
  nextAction: 'Deposit ZEC',
  sellAmountBaseUnits: BigInt.from(300000),
  direction: SwapDirection.zecToExternal,
  externalAsset: SwapAsset.usdc,
  depositAddress: 't1route-deposit',
  accountUuid: 'account-1',
);

class _FakeSwapHardwareSigningService implements SwapHardwareSigningService {
  const _FakeSwapHardwareSigningService();

  @override
  Future<SwapHardwarePcztDraft> createZecDepositPczt({
    required String accountUuid,
    required SwapIntent intent,
  }) async {
    return SwapHardwarePcztDraft(
      accountUuid: accountUuid,
      pcztBytes: const [1, 2, 3],
      needsSaplingParams: false,
      feeZatoshi: BigInt.zero,
      proposalId: BigInt.one,
      sendFlowId: 'test-swap-hardware',
    );
  }

  @override
  Future<List<String>> encodeSigningUrParts({
    required SwapHardwarePcztDraft draft,
  }) async {
    return const ['ur:zcash-sign-batch/route-test'];
  }

  @override
  Future<List<int>> decodeSigningResponse({
    required SwapHardwarePcztDraft draft,
    required List<int> responseCbor,
  }) async {
    return const [7, 8, 9];
  }

  @override
  Future<List<int>> addProofsForSigning({
    required SwapHardwarePcztDraft draft,
    String? spendParamsPath,
    String? outputParamsPath,
  }) async {
    return const [4, 5, 6];
  }

  @override
  Future<void> discardPcztDraft({required SwapHardwarePcztDraft draft}) async {}

  @override
  Future<void> settlePcztDraftAfterLedgerBroadcast({
    required SwapHardwarePcztDraft draft,
    required String? status,
  }) async {}

  @override
  Future<rust_sync.ExtractAndBroadcastPcztResult> broadcastSignedPczt({
    required SwapHardwarePcztDraft draft,
    required List<int> pcztWithProofsBytes,
    required List<int> pcztWithSignaturesBytes,
    String? spendParamsPath,
    String? outputParamsPath,
  }) {
    throw UnimplementedError();
  }
}
