@Tags(['mobile'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/formatting/address_display.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/activity/models/activity_row_data.dart';
import 'package:zcash_wallet/src/features/activity/widgets/activity_feed.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_explorer.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_screen.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_activity_details.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_activity_rows.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/rpc_endpoint_provider.dart';
import 'package:zcash_wallet/src/providers/zcash_explorer_provider.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_reverse_use_cases.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// A Private USD activity row unfolds in place into its details: a tap opens
// it and another folds it away, its links open its explorers, and a
// shortened value copies whole.
void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(393, 1600);
    view.devicePixelRatio = 1;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  final opened = <(String, PrivateUsdExplorer)>[];
  setUp(opened.clear);

  Future<void> pumpFeed(WidgetTester tester, {bool reducedMotion = false}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: AppTheme(
                data: AppThemeData.dark,
                child: _Feed(
                  onOpenTransaction: (hash, explorer) =>
                      opened.add((hash, explorer)),
                ),
              ),
            ),
          ),
        ),
      );

  final row = find.byKey(const ValueKey('mobile_private_usd_activity_row_0'));
  final details = find.byType(PrivateUsdActivityDetailsView);

  testWidgets('a tap unfolds a row into its details, and another folds it '
      'away', (tester) async {
    await pumpFeed(tester);
    expect(find.text(PrivateUsdCopy.detailsConfirmed), findsNothing);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text(PrivateUsdCopy.detailsConfirmed), findsOneWidget);
    expect(find.text(PrivateUsdCopy.explorerRailscan), findsOneWidget);
    expect(find.text(PrivateUsdCopy.explorerEtherscan), findsOneWidget);

    // The row itself: its details have a "Sent" line too.
    await tester.tap(
      find.widgetWithText(ActivityFeedRow, PrivateUsdCopy.activitySent),
    );
    await tester.pumpAndSettle();
    expect(find.text(PrivateUsdCopy.detailsConfirmed), findsNothing);
  });

  testWidgets('a transaction opens on the explorer tapped, nothing before', (
    tester,
  ) async {
    await pumpFeed(tester);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);

    await tester.tap(find.text(PrivateUsdCopy.explorerRailscan));
    await tester.tap(find.text(PrivateUsdCopy.explorerEtherscan));
    expect(opened, [
      (previewPrivateUsdTxHash, PrivateUsdExplorer.railscan),
      (previewPrivateUsdTxHash, PrivateUsdExplorer.etherscan),
    ]);
  });

  testWidgets('a shortened value copies whole', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpFeed(tester);
    await tester.tap(row);
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: details,
        matching: find.text(truncatedAddress(previewPrivateUsdRecipient)),
      ),
    );
    await tester.pump();
    expect(copied, previewPrivateUsdRecipient);
    expect(find.text(PrivateUsdCopy.detailsCopied), findsOneWidget);
    // The toast's own timers.
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('with reduced motion it unfolds at once', (tester) async {
    await pumpFeed(tester, reducedMotion: true);
    await tester.tap(row);
    await tester.pump();
    final unfolded = tester.getSize(details).height;
    expect(unfolded, greaterThan(0));

    await tester.pumpAndSettle();
    expect(tester.getSize(details).height, unfolded);
  });

  testWidgets('a bridge under way still opens its progress, and a refunded '
      'reverse one Refunds', (tester) async {
    late ActivityRowData underWay;
    late ActivityRowData refunded;
    var progress = 0;
    var refunds = 0;
    final config = PrivateUsdActivityDetailsConfig(
      open: const {},
      onToggle: (_) {},
      onOpenTransaction: (_, _) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: Builder(
            builder: (context) {
              underWay = buildPrivateUsdActivityRow(
                context: context,
                record: previewPrivateUsdRecord(depositConfirmations: 1),
                zcashConfirmations: 2,
                onOpenConversion: () => progress++,
                details: config,
              )!;
              refunded = buildPrivateUsdReverseActivityRow(
                context: context,
                record: previewPrivateUsdReverseRecord(
                  phase: ApiReversePhase.refunded,
                ),
                onOpenRefunds: () => refunds++,
                details: config,
              )!;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(underWay.details, isNull);
    expect(refunded.details, isNull);
    underWay.onTap!();
    refunded.onTap!();
    expect((progress, refunds), (1, 1));
  });

  testWidgets('each screen keeps its own rows unfolded, and another '
      "account's start folded", (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith(_Accounts.new),
        zcashExplorerProvider.overrideWith(_DefaultExplorer.new),
        rpcEndpointProvider.overrideWith(_TestnetEndpoint.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: AppTheme(
            data: AppThemeData.dark,
            child: const Column(
              children: [
                _Screen(key: ValueKey('first')),
                _Screen(key: ValueKey('second')),
              ],
            ),
          ),
        ),
      ),
    );
    Finder confirmedIn(String screen) => find.descendant(
      of: find.byKey(ValueKey(screen)),
      matching: find.text(PrivateUsdCopy.detailsConfirmed),
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('first')),
        matching: find.text(PrivateUsdCopy.activitySent),
      ),
    );
    await tester.pumpAndSettle();
    expect(confirmedIn('first'), findsOneWidget);
    expect(confirmedIn('second'), findsNothing);

    // The other account's send has the same row id.
    (container.read(accountProvider.notifier) as _Accounts).activate(
      'account-2',
    );
    await tester.pumpAndSettle();
    expect(find.text(PrivateUsdCopy.detailsConfirmed), findsNothing);
  });
}

/// A screen whose feed is one confirmed send, its rows unfolding as the
/// app's screens' do.
class _Screen extends ConsumerStatefulWidget {
  const _Screen({super.key});

  @override
  ConsumerState<_Screen> createState() => _ScreenState();
}

class _ScreenState extends ConsumerState<_Screen>
    with PrivateUsdActivityDetailsState {
  @override
  Widget build(BuildContext context) => ActivityFeedRowGroup(
    row: buildPrivateUsdSendActivityRow(
      context: context,
      record: previewPrivateUsdSendRecord(),
      details: privateUsdActivityDetails(),
    ),
  );
}

class _Accounts extends AccountNotifier {
  @override
  FutureOr<AccountState> build() => _active('account-1');

  void activate(String uuid) => state = AsyncData(_active(uuid));

  static AccountState _active(String uuid) => AccountState(
    accounts: const [
      AccountInfo(
        uuid: 'account-1',
        name: 'Main',
        order: 0,
        zip32AccountIndex: 0,
      ),
      AccountInfo(
        uuid: 'account-2',
        name: 'Other',
        order: 1,
        zip32AccountIndex: 1,
      ),
    ],
    activeAccountUuid: uuid,
  );
}

class _DefaultExplorer extends ZcashExplorerNotifier {
  @override
  String build() => '';
}

class _TestnetEndpoint extends RpcEndpointNotifier {
  @override
  RpcEndpointConfig build() => defaultRpcEndpointConfig('test');
}

/// The Private USD screen's activity with one confirmed send, its rows
/// unfolding as the screens' do.
class _Feed extends StatefulWidget {
  const _Feed({required this.onOpenTransaction});

  final PrivateUsdOpenTransaction onOpenTransaction;

  @override
  State<_Feed> createState() => _FeedState();
}

class _FeedState extends State<_Feed> {
  var _open = <String>{};

  @override
  Widget build(BuildContext context) {
    final details = PrivateUsdActivityDetailsConfig(
      open: _open,
      onToggle: (rowId) => setState(
        () => _open = _open.contains(rowId)
            ? ({..._open}..remove(rowId))
            : {..._open, rowId},
      ),
      onOpenTransaction: widget.onOpenTransaction,
    );
    return MobilePrivateUsdView(
      state: previewPrivateUsdBalance(available: 100),
      zecUsdPrice: 50,
      privacyModeEnabled: false,
      screening: const Duration(hours: 1),
      activityRows: [
        buildPrivateUsdSendActivityRow(
          context: context,
          record: previewPrivateUsdSendRecord(),
          details: details,
        ),
      ],
      onBack: () {},
      onRefresh: () {},
    );
  }
}
