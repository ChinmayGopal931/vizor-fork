import '../../features/home/providers/home_initialization_provider.dart';
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart' show Colors;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../main.dart' show log;
import '../../providers/account_provider.dart';
import '../../providers/app_security_provider.dart';
import '../../providers/network_privacy_provider.dart';
import '../../providers/privacy_mode_provider.dart';
import '../../providers/receive_address_provider.dart';
import '../../providers/sync_display_progress_provider.dart';
import '../../providers/sync_provider.dart';
import '../../providers/voting/voting_rounds_provider.dart';
import '../../providers/voting/voting_submission_guard_provider.dart';
import '../../rust/api/sync.dart' as rust_sync;
import '../../features/migration/providers/ironwood_migration_announcement_provider.dart';
import '../../features/migration/providers/ironwood_migration_coordinator_provider.dart';
import '../../features/private_usd/providers/private_usd_available_provider.dart';
import '../../features/private_usd/providers/private_usd_balance_provider.dart';
import '../../features/private_usd/providers/railgun_engine_provider.dart';
import '../../features/private_usd/widgets/mobile/private_usd_sync_line.dart';
import '../../features/swap/models/swap_activity_navigation.dart';
import '../../features/swap/providers/swap_state_provider.dart';
import '../navigation/external_action_guard_provider.dart';
import '../navigation/external_action_guard_hold.dart';
import '../config/network_config.dart';
import '../config/swap_feature_config.dart';
import '../formatting/zec_amount.dart';
import '../l10n/l10n.dart';
import '../privacy/privacy_mask.dart';
import '../profile_pictures.dart';
import '../storage/linux_keyring_coordinator.dart';
import '../theme/app_theme.dart';
import '../widgets/app_copy_feedback.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_profile_picture.dart';
import '../widgets/app_tappable.dart';
import '../widgets/app_toast.dart';
import '../widgets/neon_glass_panel.dart';
import 'app_desktop_shell.dart';
import 'app_form_factor.dart';
import 'desktop_neon_session.dart';
import 'desktop_sidebar_spacing.dart';
import 'mobile/neon_sidebar.dart';
import 'mobile/neon_sync_backdrop.dart';

/// Desktop draws the sidebar's account header, its accounts popover and the
/// migration rail in the neon look; the phones keep them as they were.
const _neonDesktop = kAppFormFactor == AppFormFactor.desktop;

final _sidebarThousandZatoshi = zatoshiPerZec * BigInt.from(1000);
final _sidebarMillionZatoshi = zatoshiPerZec * BigInt.from(1000000);

String _formatSidebarBalance(BigInt zatoshi) {
  final absolute = zatoshi.abs();
  if (absolute >= _sidebarMillionZatoshi) {
    return _formatSidebarCompactBalance(
      zatoshi,
      unitZatoshi: _sidebarMillionZatoshi,
      suffix: 'M',
    );
  }
  if (absolute >= _sidebarThousandZatoshi) {
    return _formatSidebarCompactBalance(
      zatoshi,
      unitZatoshi: _sidebarThousandZatoshi,
      suffix: 'K',
    );
  }

  final minimumVisibleZatoshi = BigInt.from(10000);
  if (absolute > BigInt.zero && absolute < minimumVisibleZatoshi) {
    return '${zatoshi.isNegative ? '-' : ''}<0.0001';
  }
  return ZecAmount.fromZatoshi(
    zatoshi,
  ).pretty(maxFractionDigits: 4, hideZeroFraction: true).amountText;
}

String _formatSidebarCompactBalance(
  BigInt zatoshi, {
  required BigInt unitZatoshi,
  required String suffix,
}) {
  final scaledThousandths = (zatoshi.abs() * BigInt.from(1000)) ~/ unitZatoshi;
  final whole = scaledThousandths ~/ BigInt.from(1000);
  var fraction = (scaledThousandths % BigInt.from(1000))
      .toString()
      .padLeft(3, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  if (fraction.isNotEmpty) fraction = '.$fraction';
  return '${zatoshi.isNegative ? '-' : ''}$whole$fraction$suffix';
}

class AppMainSidebar extends ConsumerStatefulWidget {
  const AppMainSidebar({
    this.disabledRoutePaths = const {},
    this.suppressActiveSelection = false,
    super.key,
  });

  final Set<String> disabledRoutePaths;

  /// Keeps navigation interactive while rendering every section inactive.
  final bool suppressActiveSelection;

  @override
  ConsumerState<AppMainSidebar> createState() => _AppMainSidebarState();
}

class _AppMainSidebarState extends ConsumerState<AppMainSidebar> {
  final LayerLink _accountMenuLink = LayerLink();

  bool _isSigningOut = false;
  bool _isCopyingAddress = false;
  OverlayEntry? _accountMenuEntry;

  String get _matchedLocation => GoRouterState.of(context).matchedLocation;

  bool _matches(String routePath) =>
      _matchedLocation == routePath ||
      _matchedLocation.startsWith('$routePath/');

  bool get _isHomeRoute => _matches('/home');

  bool _routeShouldBeActive(String routePath) =>
      !widget.suppressActiveSelection && _matches(routePath);

  bool get _homeShouldBeActive =>
      !widget.suppressActiveSelection &&
      (_isHomeRoute ||
          _matches('/send') ||
          _matches('/receive') ||
          _matches('/migration') ||
          _matches('/portfolio-chart') ||
          // Shielded USD opens from Home's balance, as the chart does.
          _matches('/private-usd'));

  bool get _settingsShouldBeActive =>
      !widget.suppressActiveSelection &&
      (_matches('/settings') || _matches('/payment-links'));

  bool get _isAccountMenuOpen => _accountMenuEntry != null;

  /// The row the last page's sidebar lit, read as this one appears: this
  /// page's sidebar is new, so its light crossfades from that row to this
  /// page's. Null (the first sidebar since launch) lights this page's row at
  /// once.
  late final String? _previousLit;

  @override
  void initState() {
    super.initState();
    _previousLit = ref.read(desktopNeonSessionProvider).sidebarLitDestination;
  }

  /// Which destination this page lights.
  String? get _litDestination {
    if (_homeShouldBeActive) return _SidebarDestination.home;
    if (_routeShouldBeActive('/swap')) return _SidebarDestination.swap;
    if (_routeShouldBeActive('/pay')) return _SidebarDestination.pay;
    if (_routeShouldBeActive('/voting')) return _SidebarDestination.vote;
    if (_routeShouldBeActive('/activity')) return _SidebarDestination.activity;
    if (_settingsShouldBeActive) return _SidebarDestination.settings;
    return null;
  }

  /// Whether [destination] was lit on the last page; null when no sidebar
  /// has been drawn yet.
  bool? _wasLit(String destination) =>
      _previousLit == null ? null : _previousLit == destination;

  @override
  void dispose() {
    _closeAccountMenu(rebuild: false);
    super.dispose();
  }

  bool _blockIfVotingSubmissionInProgress() {
    final guards = ref.read(votingSubmissionGuardProvider);
    if (guards.isEmpty) return false;
    showAppToast(context, guards.first.message.text(context.l10n));
    return true;
  }

  void _navigateTo(String routePath) {
    if (ref
        .read(externalActionGuardProvider)
        .blocks(ExternalAction.navigation)) {
      return;
    }
    if (widget.disabledRoutePaths.contains(routePath)) return;
    if (_matches(routePath)) {
      if (routePath == '/voting') {
        ref.read(votingPollListRefreshRequestProvider.notifier).request();
      }
      return;
    }
    context.go(routePath);
  }

  void _openAccounts() {
    _closeAccountMenu();
    _navigateTo('/accounts');
  }

  void _openAddAccount() {
    if (ref
        .read(externalActionGuardProvider)
        .blocks(ExternalAction.navigation)) {
      return;
    }
    _closeAccountMenu();
    context.go('/add-account');
  }

  void _openActivity() {
    if (ref
        .read(externalActionGuardProvider)
        .blocks(ExternalAction.navigation)) {
      return;
    }
    if (_matchedLocation == '/activity') return;
    context.go('/activity');
  }

  void _openSettings() {
    if (ref
        .read(externalActionGuardProvider)
        .blocks(ExternalAction.navigation)) {
      return;
    }
    if (_matchedLocation == '/settings') return;
    context.go('/settings');
  }

  Future<void> _openPay() async {
    if (_matches('/pay')) return;

    final accountUuid = ref
        .read(accountProvider)
        .value
        ?.activeAccountUuid
        ?.trim();
    if (accountUuid == null || accountUuid.isEmpty) return;

    final router = GoRouter.of(context);
    final entryPath = router.routerDelegate.currentConfiguration.uri.path;
    final swapNotifier = ref.read(swapStateProvider.notifier);
    await _trackPendingNavigation(() async {
      final selectedAsset = await swapNotifier.resolvePaySelectedAssetForEntry(
        accountUuid: accountUuid,
      );
      if (!mounted ||
          selectedAsset == null ||
          router.routerDelegate.currentConfiguration.uri.path != entryPath) {
        return;
      }
      final prepared = swapNotifier.preparePayFromShieldedZec(
        preferredAsset: selectedAsset,
        expectedAccountUuid: accountUuid,
      );
      if (!prepared) return;
      router.go(
        '/pay',
        extra: const PayComposerNavigationArgs(preservePreparedComposer: true),
      );
    });
  }

  Future<void> _trackPendingNavigation(Future<void> Function() action) =>
      ref.read(externalActionGuardProvider.notifier).runNavigation(action);

  void _toggleAccountMenu({
    required List<AccountInfo> accounts,
    required String? activeAccountUuid,
  }) {
    if (_isAccountMenuOpen) {
      _closeAccountMenu();
    } else {
      _openAccountMenu(
        accounts: accounts,
        activeAccountUuid: activeAccountUuid,
      );
    }
  }

  void _openAccountMenu({
    required List<AccountInfo> accounts,
    required String? activeAccountUuid,
  }) {
    final overlay = Overlay.of(context);
    final appTheme = AppTheme.of(context);
    _accountMenuEntry = OverlayEntry(
      builder: (_) => AppTheme(
        data: appTheme,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('sidebar_accounts_popover_backdrop'),
                behavior: HitTestBehavior.translucent,
                onTap: _closeAccountMenu,
              ),
            ),
            CompositedTransformFollower(
              link: _accountMenuLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topLeft,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(0, 48),
              child: _SidebarAccountsPopover(
                accounts: accounts,
                activeAccountUuid: activeAccountUuid,
                onSelectAccount: (uuid) => unawaited(_switchAccount(uuid)),
                onCopyAccountAddress: (account) =>
                    unawaited(_copyShieldedAddressForAccount(account)),
                onManageAccounts: _openAccounts,
                onAddAccount: _openAddAccount,
              ),
            ),
          ],
        ),
      ),
    );
    overlay.insert(_accountMenuEntry!);
    setState(() {});
  }

  void _closeAccountMenu({bool rebuild = true}) {
    final entry = _accountMenuEntry;
    if (entry == null) return;
    _accountMenuEntry = null;
    entry.remove();
    if (rebuild && mounted) setState(() {});
  }

  Future<void> _switchAccount(String uuid) async {
    final activeAccountUuid = ref
        .read(accountProvider)
        .value
        ?.activeAccountUuid;
    _closeAccountMenu();
    if (uuid == activeAccountUuid) return;

    final accountNotifier = ref.read(accountProvider.notifier);
    final syncNotifier = ref.read(syncProvider.notifier);
    await _trackPendingNavigation(() async {
      try {
        await accountNotifier.switchAccount(uuid);
      } on WalletMutationBusyException {
        // Another wallet mutation, such as the private queries toggle, holds
        // the wallet: stay on this screen and say why nothing happened.
        if (mounted) showAppToast(context, context.l10n.walletMutationBusy);
        return;
      }
      if (mounted) {
        context.go('/home');
      }
      unawaited(_refreshAfterAccountSwitch(syncNotifier));
    });
  }

  Future<void> _refreshAfterAccountSwitch(SyncNotifier syncNotifier) async {
    try {
      await syncNotifier.refreshAfterAccountSwitch();
    } catch (e) {
      log('AppMainSidebar: refresh after account switch failed: $e');
    }
  }

  Future<void> _copyShieldedAddress() async {
    if (_isCopyingAddress) return;

    final accountState = ref.read(accountProvider).value;
    final accountUuid = accountState?.activeAccountUuid;
    if (accountUuid == null) {
      showAppToast(context, context.l10n.sidebarAddressCopyFailed);
      return;
    }

    setState(() {
      _isCopyingAddress = true;
    });

    try {
      final address = await ref
          .read(receiveAddressServiceProvider)
          .loadShieldedAddress(
            accountUuid: accountUuid,
            currentShieldedAddress: accountState?.activeAddress,
          );
      if (!mounted) return;
      if (ref.read(accountProvider).value?.activeAccountUuid != accountUuid) {
        return;
      }
      if (address.trim().isEmpty) {
        showAppToast(context, context.l10n.sidebarAddressCopyFailed);
        return;
      }

      if (!mounted) return;
      copyTextWithToast(
        context,
        text: address,
        toastMessage: context.l10n.commonAddressCopied,
      );
    } catch (e) {
      log('AppMainSidebar: ERROR copying shielded address: $e');
      if (!mounted) return;
      showAppToast(context, context.l10n.sidebarAddressCopyFailed);
    } finally {
      if (mounted) {
        setState(() {
          _isCopyingAddress = false;
        });
      }
    }
  }

  Future<void> _copyShieldedAddressForAccount(AccountInfo account) async {
    if (_isCopyingAddress) return;
    setState(() => _isCopyingAddress = true);

    try {
      final accountState = ref.read(accountProvider).value;
      final currentShieldedAddress =
          accountState?.activeAccountUuid == account.uuid
          ? accountState?.activeAddress
          : null;
      final address = await ref
          .read(receiveAddressServiceProvider)
          .loadShieldedAddress(
            accountUuid: account.uuid,
            currentShieldedAddress: currentShieldedAddress,
          );
      if (!mounted) return;
      if (address.trim().isEmpty) {
        showAppToast(context, context.l10n.sidebarAddressCopyFailed);
        return;
      }

      if (!mounted) return;
      copyTextWithToast(
        context,
        text: address,
        toastMessage: context.l10n.sidebarShieldedAddressCopied,
      );
    } catch (e) {
      log('AppMainSidebar: ERROR copying account shielded address: $e');
      if (!mounted) return;
      showAppToast(context, context.l10n.sidebarAddressCopyFailed);
    } finally {
      if (mounted) {
        setState(() => _isCopyingAddress = false);
      }
    }
  }

  Future<void> _handleSignOut() async {
    if (_isSigningOut) return;
    if (_blockIfVotingSubmissionInProgress()) return;
    final syncNotifier = ref.read(syncProvider.notifier);
    final accountNotifier = ref.read(accountProvider.notifier);
    final securityNotifier = ref.read(appSecurityProvider.notifier);

    setState(() {
      _isSigningOut = true;
    });

    try {
      securityNotifier.lock();
      accountNotifier.clearSensitiveStateForLock();
      if (mounted) {
        context.go('/unlock');
      }
      await syncNotifier.clearSensitiveStateForLock();
    } finally {
      if (mounted) {
        setState(() {
          _isSigningOut = false;
        });
      }
    }
  }

  /// Puts a sync readout's line under the glyphs' column.
  static const _syncReadoutPadding = EdgeInsetsDirectional.only(
    start:
        AppSidebarItem.glyphInset +
        (AppSidebarItem.glyphSize - NeonSidebarGlyph.size) / 2,
  );

  /// The wallet's sync line, as Home's reads; the sidebar needs only its
  /// whole percentage, never the per-frame one.
  NeonSyncLine _syncLine(SyncState sync, NetworkPrivacyState networkPrivacy) {
    final whole = ref.watch(syncDisplayWholePercentageProvider);
    return NeonSyncLine.wallet(
      context.l10n,
      sync,
      whole: whole,
      networkPrivacy: networkPrivacy,
      climbProgress: () => whole / 100,
    );
  }

  /// Railgun's sync, a separate one, as the Shielded USD page's line reads it
  /// ([privateUsdSyncLine]): it follows the balance's syncs and starts none.
  /// Null on the phones, while Shielded USD is not available to the account,
  /// and while a wallet Railgun never synced has nothing to report: no
  /// balance, and no sync running or failed. Only the page starts a first
  /// sync, so its line would stand at 0% until then. A balance from an
  /// earlier session reads as synced, as on the page, until a sync this
  /// session climbs or fails.
  NeonSyncLine? _railgunSyncLine(
    String? accountUuid,
    NetworkPrivacyState networkPrivacy,
  ) {
    if (!kDesktopFormFactor ||
        accountUuid == null ||
        !ref.watch(privateUsdAvailableProvider)) {
      return null;
    }
    final state = ref.watch(privateUsdBalanceProvider(accountUuid));
    if (state.balances == null &&
        !state.isRefreshing &&
        !state.refreshFailed &&
        state.firstSyncPercent == null) {
      return null;
    }
    return privateUsdSyncLine(
      context.l10n,
      state,
      networkPrivacy: networkPrivacy,
      txidCatchUp: ref.watch(
        railgunEngineStateProvider.select(
          (engine) => engine.accountUuid == accountUuid
              ? engine.screening?.txids
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accountAsync = ref.watch(accountProvider);
    final accounts = [
      ...(accountAsync.value?.accounts ?? const <AccountInfo>[]),
    ];
    accounts.sort((a, b) => a.order.compareTo(b.order));
    final activeAccountUuid = accountAsync.value?.activeAccountUuid;
    AccountInfo? activeAccount;
    if (activeAccountUuid != null) {
      for (final account in accounts) {
        if (account.uuid == activeAccountUuid) {
          activeAccount = account;
          break;
        }
      }
    }
    final accountName =
        activeAccount?.name ?? context.l10n.sidebarAccountNameFallback;
    // Only the page on top says which row is lit now: a page below it that
    // repaints never overwrites it.
    if (ModalRoute.isCurrentOf(context) ?? true) {
      ref.read(desktopNeonSessionProvider).sidebarLitDestination =
          _litDestination;
    }
    final sync = ref.watch(syncProvider).value ?? SyncState();
    final networkPrivacy = ref.watch(networkPrivacyProvider);
    final railgunSyncLine = _railgunSyncLine(activeAccountUuid, networkPrivacy);
    final accountSync = sync.scopedToAccount(activeAccountUuid);
    final showImporting = ref
        .watch(homeInitializationPresentationProvider)
        .showImporting;
    final isImporting =
        showImporting ||
        (activeAccountUuid != null && accountSync.isImportingAccount);
    final balanceText =
        '${accountSync.hasDisplayBalance ? _formatSidebarBalance(accountSync.displayTotalBalance) : '—'} ' // l10n-ignore: amount format
        '$kZcashDefaultCurrencyTicker';
    final privacyModeEnabled = ref.watch(privacyModeProvider);
    final balanceLabel = hideAmountIfPrivacyMode(
      balanceText,
      privacyModeEnabled: privacyModeEnabled,
    );
    final swapFeatureEnabled = ref.watch(swapFeatureEnabledProvider);
    final ironwoodHomeMigrationPresentation = ref.watch(
      ironwoodHomeMigrationPresentationProvider,
    );
    final payNavigationLocked =
        ironwoodHomeMigrationPresentation.mode ==
            IronwoodHomeMigrationCtaMode.resume &&
        accountSync.ironwoodBalance <= BigInt.zero;
    final migrationCoordinator = ref.watch(
      ironwoodMigrationCoordinatorProvider,
    );
    // A run the upgrade stopped has no active run id, so the coordinator
    // status alone would drop the section; the home CTA still carries it.
    final migrationStatus =
        ironwoodHomeMigrationPresentation.mode ==
            IronwoodHomeMigrationCtaMode.stopped
        ? ironwoodHomeMigrationPresentation.status
        : activeAccountUuid == null
        ? null
        : migrationCoordinator.statuses[activeAccountUuid];

    final sidebar = AppDesktopSidebarSurface(
      glass: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 640;
          final topPadding = mainSidebarTopPadding(compact: compact);
          final headerNavGap = compact ? AppSpacing.xs : AppSpacing.md;
          final bottomPadding = compact ? AppSpacing.xs : AppSpacing.md;
          final bottomSyncGap = compact ? AppSpacing.xs : AppSpacing.md;

          return Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: EdgeInsets.only(
                  top: topPadding,
                  left: AppSpacing.sm,
                  right: AppSpacing.sm,
                  bottom: bottomPadding,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CompositedTransformTarget(
                      link: _accountMenuLink,
                      child: _SidebarAccountHeader(
                        key: const ValueKey('sidebar_accounts_button'),
                        accountName: accountName,
                        profilePictureId:
                            activeAccount?.profilePictureId ??
                            kDefaultProfilePictureId,
                        balanceLabel: balanceLabel,
                        hardwareSignerKind: activeAccount?.hardwareSignerKind,
                        privacyModeEnabled: privacyModeEnabled,
                        onTogglePrivacyMode: () =>
                            ref.read(privacyModeProvider.notifier).toggle(),
                        onCopyAddress:
                            activeAccountUuid == null || _isCopyingAddress
                            ? null
                            : () => unawaited(_copyShieldedAddress()),
                        onTap: accounts.isEmpty
                            ? null
                            : () => _toggleAccountMenu(
                                accounts: accounts,
                                activeAccountUuid: activeAccountUuid,
                              ),
                      ),
                    ),
                    SizedBox(height: headerNavGap),
                    if ((migrationStatus?.activeRunId != null ||
                            migrationStatus?.phase ==
                                kIronwoodMigrationStoppedByUpgradePhase) &&
                        migrationStatus?.phase !=
                            kIronwoodMigrationWaitingDenomConfirmationsPhase)
                      _SidebarMigrationHomeSection(
                        status: migrationStatus!,
                        isKeystone: activeAccount?.isKeystone ?? false,
                        balanceIsAvailable: accountSync.hasDisplayBalance,
                        orchardBalance:
                            accountSync.displayOrchardHoldingsBalance,
                        ironwoodBalance:
                            accountSync.displayIronwoodBalance +
                            accountSync.displayIronwoodPendingBalance,
                        privacyModeEnabled: privacyModeEnabled,
                        active: _homeShouldBeActive,
                        wasActive: _wasLit(_SidebarDestination.home),
                        onHome: () => _navigateTo('/home'),
                        onMigration: () =>
                            _navigateTo('/migration/private/status'),
                      )
                    else
                      AppSidebarItem(
                        key: const ValueKey('sidebar_home_button'),
                        label: showImporting
                            ? context.l10n.commonImporting
                            : context.l10n.navHome,
                        iconName: showImporting
                            ? AppIcons.loader
                            : AppIcons.home,
                        iconAnimated: !showImporting,
                        active: _homeShouldBeActive,
                        wasActive: _wasLit(_SidebarDestination.home),
                        onTap: () => _navigateTo('/home'),
                      ),
                    if (swapFeatureEnabled) ...[
                      const SizedBox(height: AppSpacing.xs),
                      AppSidebarItem(
                        key: const ValueKey('sidebar_swap_button'),
                        label: context.l10n.navSwap,
                        iconName: AppIcons.swapArrows,
                        active: _routeShouldBeActive('/swap'),
                        wasActive: _wasLit(_SidebarDestination.swap),
                        onTap:
                            isImporting ||
                                widget.disabledRoutePaths.contains('/swap')
                            ? null
                            : () => _navigateTo('/swap'),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      AppSidebarItem(
                        key: const ValueKey('sidebar_pay_button'),
                        label: context.l10n.navPay,
                        iconName: AppIcons.paid,
                        active: _routeShouldBeActive('/pay'),
                        wasActive: _wasLit(_SidebarDestination.pay),
                        onTap:
                            isImporting ||
                                widget.disabledRoutePaths.contains('/pay') ||
                                payNavigationLocked
                            ? null
                            : () => unawaited(_openPay()),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.xs),
                    AppSidebarItem(
                      key: const ValueKey('sidebar_voting_button'),
                      label: context.l10n.navVote,
                      iconName: AppIcons.vote,
                      active: _routeShouldBeActive('/voting'),
                      wasActive: _wasLit(_SidebarDestination.vote),
                      // Stays tappable while active: _navigateTo requests a
                      // poll-list refresh when re-tapped on /voting.
                      // The round's snapshot notes determine eligibility;
                      // remaining Orchard funds do not block voting entry.
                      onTap:
                          isImporting ||
                              widget.disabledRoutePaths.contains('/voting')
                          ? null
                          : () => _navigateTo('/voting'),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    AppSidebarItem(
                      key: const ValueKey('sidebar_activity_button'),
                      label: context.l10n.navActivity,
                      iconName: AppIcons.history,
                      active: _routeShouldBeActive('/activity'),
                      wasActive: _wasLit(_SidebarDestination.activity),
                      // Stays tappable on detail subroutes (tx/swap status)
                      // as a way back to the main activity feed.
                      onTap: isImporting ? null : _openActivity,
                    ),
                    const Spacer(),
                    AppSidebarItem(
                      key: const ValueKey('sidebar_settings_button'),
                      label: context.l10n.navSettings,
                      iconName: AppIcons.cog,
                      active: _settingsShouldBeActive,
                      wasActive: _wasLit(_SidebarDestination.settings),
                      onTap: _openSettings,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    AppSidebarItem(
                      key: const ValueKey('sidebar_sign_out_button'),
                      label: context.l10n.navSignOut,
                      iconName: AppIcons.logOut,
                      onTap: _isSigningOut ? null : _handleSignOut,
                    ),
                    SizedBox(height: bottomSyncGap),
                    // The phone sidebar's sync readout: a short line that
                    // rises with the scan under the glyphs' column, and its
                    // readout as a red HUD caption, read from the same
                    // [NeonSyncLine.wallet] as Home's line.
                    Padding(
                      padding: _syncReadoutPadding,
                      child: NeonSidebarSyncReadout(
                        key: const ValueKey('sidebar_sync_status'),
                        textKey: const ValueKey('sidebar_sync_text'),
                        line: _syncLine(sync, networkPrivacy),
                      ),
                    ),
                    // Railgun's sync under it in the same style, with the
                    // Shielded USD page's readouts.
                    if (railgunSyncLine != null) ...[
                      SizedBox(
                        height: compact ? AppSpacing.xxs : AppSpacing.xs,
                      ),
                      Padding(
                        padding: _syncReadoutPadding,
                        child: NeonSidebarSyncReadout(
                          key: const ValueKey('sidebar_railgun_sync_status'),
                          textKey: const ValueKey('sidebar_railgun_sync_text'),
                          line: railgunSyncLine,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
    return ExternalActionNavigationGuard(child: sidebar);
  }
}

/// The sidebar's destinations, as [DesktopNeonSession] remembers the lit one.
abstract final class _SidebarDestination {
  static const home = 'home';
  static const swap = 'swap';
  static const pay = 'pay';
  static const vote = 'vote';
  static const activity = 'activity';
  static const settings = 'settings';
}

class _SidebarMigrationHomeSection extends StatelessWidget {
  const _SidebarMigrationHomeSection({
    required this.status,
    required this.isKeystone,
    required this.balanceIsAvailable,
    required this.orchardBalance,
    required this.ironwoodBalance,
    required this.privacyModeEnabled,
    required this.active,
    required this.wasActive,
    required this.onHome,
    required this.onMigration,
  });

  final rust_sync.MigrationStatus status;
  final bool isKeystone;
  final bool balanceIsAvailable;
  final BigInt orchardBalance;
  final BigInt ironwoodBalance;
  final bool privacyModeEnabled;
  final bool active;
  final bool? wasActive;
  final VoidCallback onHome;
  final VoidCallback onMigration;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final signingPartIndices = status.currentSigningPartIndices;
    final needsInput =
        isKeystone &&
        status.phase == kIronwoodMigrationReadyToMigratePhase &&
        (signingPartIndices == null || signingPartIndices.isNotEmpty);
    final stopped = status.phase == kIronwoodMigrationStoppedByUpgradePhase;
    final attention = needsInput || stopped;
    final orchardLabel = hideAmountIfPrivacyMode(
      '${balanceIsAvailable ? _formatSidebarBalance(orchardBalance) : '—'} ZEC', // l10n-ignore: amount format
      privacyModeEnabled: privacyModeEnabled,
    );
    final ironwoodLabel = hideAmountIfPrivacyMode(
      '${balanceIsAvailable ? _formatSidebarBalance(ironwoodBalance) : '—'} ZEC', // l10n-ignore: amount format
      privacyModeEnabled: privacyModeEnabled,
    );

    return SizedBox(
      height: 120,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: AppSidebarItem(
              key: ValueKey('sidebar_orchard_home_row'),
              label: context.l10n.navHome,
              iconName: AppIcons.home,
              onTap: onHome,
              // A stopped run released its notes, so Orchard is no longer held.
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    orchardLabel,
                    key: ValueKey('sidebar_orchard_balance'),
                    style: AppTypography.labelLarge.copyWith(
                      color: stopped
                          ? colors.text.secondary
                          : colors.text.secondary.withValues(alpha: 0.5),
                    ),
                  ),
                  if (!stopped) ...[
                    SizedBox(width: AppSpacing.xxs),
                    AppIcon(
                      AppIcons.lock,
                      size: 16,
                      color: colors.icon.regular.withValues(alpha: 0.5),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (!stopped)
            Positioned(
              left: _SidebarMigrationGlow.left,
              top: _SidebarMigrationGlow.top,
              child: _SidebarMigrationGlow(),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: 40,
            child: AppSidebarItem(
              key: ValueKey('sidebar_migration_progress_button'),
              label: stopped
                  ? context.l10n.commonMigrationStopped
                  : needsInput
                  ? context.l10n.sidebarMigrationNeedsInput
                  : context.l10n.commonMigrating,
              leading: SizedBox(
                width: _SidebarMigrationGlow.visualWidth,
                height: _SidebarMigrationGlow.visualHeight,
              ),
              leadingGap: AppSpacing.sm,
              inactiveOpacity: 0.64,
              onTap: onMigration,
              trailing: AppIcon(
                attention ? AppIcons.warning : AppIcons.loader,
                size: 20,
                color: attention ? colors.icon.warning : colors.icon.regular,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 80,
            child: AppSidebarItem(
              key: ValueKey('sidebar_home_button'),
              label: 'Ironwood', // l10n-ignore: pool name
              iconName: AppIcons.home,
              active: active,
              wasActive: wasActive,
              onTap: onHome,
              trailing: Text(
                ironwoodLabel,
                key: ValueKey('sidebar_ironwood_balance'),
                style: AppTypography.labelLarge.copyWith(
                  color: active
                      ? colors.navPanel.activeLabel.withValues(alpha: 0.8)
                      : colors.text.secondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarMigrationGlow extends StatefulWidget {
  const _SidebarMigrationGlow();

  static const visualWidth = 20.0;
  static const visualHeight = 32.0;
  static const left = 14.0;
  static const top = 6.0;
  static const _outerWidth = 24.0;
  static const _outerHeight = 108.0;
  static const _innerWidth = 14.0;
  static const _innerHeight = 92.0;
  static const _radius = 13.0;
  static const _midAlpha = 0.15;
  static const _glowColor = Color(0xFF00A460);

  /// Desktop's rail is a near-square slab of the tube's red light; the phones
  /// keep the green pill.
  static const _railRadius = _neonDesktop ? AppRadii.small : _radius;
  static Color glowColor(BuildContext context) =>
      _neonDesktop ? context.colors.neon.glow : _glowColor;
  static const _flowBandHeight = 34.0;
  static const _flowPeriod = Duration(milliseconds: 1800);

  @override
  State<_SidebarMigrationGlow> createState() => _SidebarMigrationGlowState();
}

class _SidebarMigrationGlowState extends State<_SidebarMigrationGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _SidebarMigrationGlow._flowPeriod,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animate = !(MediaQuery.maybeOf(context)?.disableAnimations ?? false);
    if (animate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!animate && _controller.isAnimating) {
      _controller.stop();
    }

    return SizedBox(
      width: _SidebarMigrationGlow._outerWidth,
      height: _SidebarMigrationGlow._outerHeight,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          const _SidebarMigrationGlowPill(
            width: _SidebarMigrationGlow._outerWidth,
            height: _SidebarMigrationGlow._outerHeight,
          ),
          const _SidebarMigrationGlowPill(
            width: _SidebarMigrationGlow._innerWidth,
            height: _SidebarMigrationGlow._innerHeight,
          ),
          if (animate)
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return _SidebarMigrationFlowHighlight(t: _controller.value);
              },
            ),
        ],
      ),
    );
  }
}

class _SidebarMigrationFlowHighlight extends StatelessWidget {
  const _SidebarMigrationFlowHighlight({required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    final bandHeight = _SidebarMigrationGlow._flowBandHeight;
    final travel = _SidebarMigrationGlow._outerHeight + (bandHeight * 2);
    final y = -bandHeight + (travel * t);

    return ClipRRect(
      borderRadius: BorderRadius.circular(_SidebarMigrationGlow._railRadius),
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x00FFFFFF),
            Color(0xFFFFFFFF),
            Color(0xFFFFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: [0, 0.22, 0.78, 1],
        ).createShader(bounds),
        child: SizedBox(
          width: _SidebarMigrationGlow._outerWidth,
          height: _SidebarMigrationGlow._outerHeight,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.topCenter,
            children: [
              Positioned(
                top: y,
                child: const _SidebarMigrationFlowBand(
                  width: _SidebarMigrationGlow._outerWidth,
                  height: _SidebarMigrationGlow._flowBandHeight,
                  alpha: 0.13,
                ),
              ),
              Positioned(
                top: y + 5,
                child: const _SidebarMigrationFlowBand(
                  width: _SidebarMigrationGlow._innerWidth,
                  height: _SidebarMigrationGlow._flowBandHeight,
                  alpha: 0.26,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarMigrationFlowBand extends StatelessWidget {
  const _SidebarMigrationFlowBand({
    required this.width,
    required this.height,
    required this.alpha,
  });

  final double width;
  final double height;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    final glow = _neonDesktop
        ? _SidebarMigrationGlow.glowColor(context)
        : _SidebarMigrationGlow._glowColor;
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(
            _SidebarMigrationGlow._railRadius,
          ),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              glow.withValues(alpha: 0),
              glow.withValues(alpha: alpha),
              glow.withValues(alpha: alpha * 0.72),
              glow.withValues(alpha: 0),
            ],
            stops: const [0, 0.42, 0.62, 1],
          ),
        ),
      ),
    );
  }
}

class _SidebarMigrationGlowPill extends StatelessWidget {
  const _SidebarMigrationGlowPill({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final glow = _neonDesktop
        ? _SidebarMigrationGlow.glowColor(context)
        : _SidebarMigrationGlow._glowColor;
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(
            _SidebarMigrationGlow._railRadius,
          ),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              glow.withValues(alpha: 0),
              glow.withValues(alpha: _SidebarMigrationGlow._midAlpha),
              glow.withValues(alpha: 0),
            ],
            stops: const [0, 0.5, 1],
          ),
        ),
      ),
    );
  }
}

class _SidebarAccountHeader extends StatelessWidget {
  const _SidebarAccountHeader({
    required this.accountName,
    required this.profilePictureId,
    required this.balanceLabel,
    required this.hardwareSignerKind,
    required this.privacyModeEnabled,
    required this.onTogglePrivacyMode,
    this.onCopyAddress,
    this.onTap,
    super.key,
  });

  final String accountName;
  final String profilePictureId;
  final String balanceLabel;
  final HardwareSignerKind? hardwareSignerKind;
  final bool privacyModeEnabled;
  final VoidCallback onTogglePrivacyMode;
  final VoidCallback? onCopyAddress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final row = SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxs),
        child: Row(
          children: [
            _SidebarAccountAvatar(
              profilePictureId: profilePictureId,
              hardwareSignerKind: hardwareSignerKind,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          accountName,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.labelLarge.copyWith(
                            color: colors.text.accent,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xxs),
                      _SidebarCopyAddressButton(onTap: onCopyAddress),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  Row(
                    children: [
                      Flexible(
                        fit: FlexFit.loose,
                        child: Text(
                          balanceLabel,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.labelLarge.copyWith(
                            color: colors.text.secondary,
                            fontWeight: _neonDesktop
                                ? AppFontWeight.regular
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xxs),
                      _SidebarHideBalanceButton(
                        enabled: true,
                        privacyModeEnabled: privacyModeEnabled,
                        onTap: onTogglePrivacyMode,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return onTap == null
        ? row
        : MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: row,
            ),
          );
  }
}

class _SidebarAccountAvatar extends StatelessWidget {
  const _SidebarAccountAvatar({
    required this.profilePictureId,
    required this.hardwareSignerKind,
  });

  final String profilePictureId;
  final HardwareSignerKind? hardwareSignerKind;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: 32,
      height: 32,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AppProfilePicture(
            profilePictureId: profilePictureId,
            size: AppProfilePictureSize.large,
          ),
          if (hardwareSignerKind case final signerKind?)
            Positioned(
              right: -5,
              bottom: 0,
              child: Container(
                width: 16,
                height: 16,
                decoration: _neonDesktop
                    // A cut-corner plate, its ring outside it in the
                    // window's black.
                    ? ShapeDecoration(
                        color: colors.background.inverse,
                        shape: Neon.chamferBorder(
                          cut: AppChamfer.small,
                          side: BorderSide(
                            color: colors.background.window,
                            width: 2,
                            strokeAlign: BorderSide.strokeAlignOutside,
                          ),
                        ),
                      )
                    : BoxDecoration(
                        color: colors.background.inverse,
                        borderRadius: BorderRadius.circular(4),
                        // The ring sits OUTSIDE the 16px badge like the Figma
                        // stroke, leaving the full box to the 14px logo.
                        border: Border.all(
                          color: colors.background.ground,
                          width: 2,
                          strokeAlign: BorderSide.strokeAlignOutside,
                        ),
                      ),
                child: Center(
                  child: AppIcon(
                    signerKind == HardwareSignerKind.keystone
                        ? AppIcons.keystone
                        : AppIcons.ledger,
                    key: ValueKey('hardware_signer_badge_${signerKind.name}'),
                    size: signerKind == HardwareSignerKind.ledger ? 16 : 14,
                    color: colors.text.inverse,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SidebarHideBalanceButton extends StatelessWidget {
  const _SidebarHideBalanceButton({
    required this.enabled,
    required this.privacyModeEnabled,
    required this.onTap,
  });

  final bool enabled;
  final bool privacyModeEnabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      enabled: enabled,
      label: privacyModeEnabled
          ? context.l10n.sidebarShowBalance
          : context.l10n.sidebarHideBalance,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 16,
            height: 16,
            child: Center(
              child: AppIcon(
                privacyModeEnabled ? AppIcons.eyeClosed : AppIcons.eye,
                size: 16,
                color: colors.icon.regular.withValues(
                  alpha: enabled ? 0.72 : 0.38,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarCopyAddressButton extends StatelessWidget {
  const _SidebarCopyAddressButton({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = onTap != null;
    final iconColor = colors.icon.regular.withValues(
      alpha: enabled ? 0.72 : 0.38,
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: context.l10n.commonCopyShieldedAddress,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: 16,
            height: 16,
            child: Center(
              child: AppIcon(AppIcons.copy, size: 16, color: iconColor),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarAccountsPopover extends StatefulWidget {
  const _SidebarAccountsPopover({
    required this.accounts,
    required this.activeAccountUuid,
    required this.onSelectAccount,
    required this.onCopyAccountAddress,
    required this.onManageAccounts,
    required this.onAddAccount,
  });

  final List<AccountInfo> accounts;
  final String? activeAccountUuid;
  final ValueChanged<String> onSelectAccount;
  final ValueChanged<AccountInfo> onCopyAccountAddress;
  final VoidCallback onManageAccounts;
  final VoidCallback onAddAccount;

  @override
  State<_SidebarAccountsPopover> createState() =>
      _SidebarAccountsPopoverState();
}

class _SidebarAccountsPopoverState extends State<_SidebarAccountsPopover> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final showScrollbar = widget.accounts.length > 3;
    if (_neonDesktop) return _buildNeon(context, showScrollbar: showScrollbar);
    return DefaultTextStyle.merge(
      style: const TextStyle(decoration: TextDecoration.none),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 17.5, sigmaY: 17.5),
          child: Container(
            key: const ValueKey('sidebar_accounts_popover'),
            width: 221,
            height: 254,
            padding: const EdgeInsets.all(AppSpacing.xs),
            decoration: BoxDecoration(
              color: colors.surface.nav,
              borderRadius: BorderRadius.circular(20),
              // Figma's dropdown shadow stack (no stroke): 0/14/28 @ 8%,
              // 0/-6/12 @ 3%, 0/2/8 @ 6%.
              boxShadow: const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 28,
                  offset: Offset(0, 14),
                ),
                BoxShadow(
                  color: Color(0x08000000),
                  blurRadius: 12,
                  offset: Offset(0, -6),
                ),
                BoxShadow(
                  color: Color(0x0F000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.xxs),
                  child: Text(
                    context.l10n.sidebarMyAccounts,
                    style: AppTypography.labelLarge.copyWith(
                      color: colors.text.muted,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                SizedBox(
                  key: const ValueKey('sidebar_accounts_list'),
                  height: 153,
                  child: RawScrollbar(
                    key: const ValueKey('sidebar_accounts_scrollbar'),
                    controller: _scrollController,
                    thumbVisibility: showScrollbar,
                    radius: const Radius.circular(AppRadii.full),
                    thickness: 6,
                    mainAxisMargin: 6,
                    crossAxisMargin: 6,
                    thumbColor: colors.surface.scrollbarThumb,
                    child: Padding(
                      key: const ValueKey('sidebar_accounts_list_gutter'),
                      padding: const EdgeInsets.only(right: 18),
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(scrollbars: false),
                        child: ListView.separated(
                          controller: _scrollController,
                          physics: const ClampingScrollPhysics(),
                          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                          itemCount: widget.accounts.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: AppSpacing.xxs),
                          itemBuilder: (context, index) {
                            final account = widget.accounts[index];
                            return _SidebarAccountPopoverRow(
                              key: ValueKey(
                                'sidebar_account_popover_row_${account.uuid}',
                              ),
                              account: account,
                              selected:
                                  account.uuid == widget.activeAccountUuid,
                              onTap: () => widget.onSelectAccount(account.uuid),
                              onCopyAddress:
                                  account.uuid == widget.activeAccountUuid
                                  ? null
                                  : () => widget.onCopyAccountAddress(account),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                const _SidebarAccountsActionsDivider(),
                const SizedBox(height: AppSpacing.xs),
                SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      _SidebarPopoverHoverTarget(
                        onTap: widget.onManageAccounts,
                        builder: (context, hovered) => Container(
                          key: const ValueKey('sidebar_accounts_manage'),
                          width: 153,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: hovered
                                ? colors.button.secondary.bgHover
                                : colors.button.secondary.bg,
                            borderRadius: BorderRadius.circular(AppRadii.full),
                          ),
                          child: Text(
                            context.l10n.commonManage,
                            style: AppTypography.labelLarge.copyWith(
                              color: colors.button.secondary.label,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xxs),
                      _SidebarPopoverHoverTarget(
                        onTap: widget.onAddAccount,
                        builder: (context, hovered) => Container(
                          key: const ValueKey('sidebar_accounts_add'),
                          width: 48,
                          height: 32,
                          decoration: BoxDecoration(
                            color: hovered
                                ? colors.button.primary.bgHover
                                : colors.button.primary.bg,
                            borderRadius: BorderRadius.circular(AppRadii.full),
                            border: Border.all(
                              color: colors.border.subtleOpacity,
                              strokeAlign: BorderSide.strokeAlignInside,
                            ),
                          ),
                          child: Center(
                            child: AppIcon(
                              AppIcons.addNew,
                              size: 16,
                              color: colors.button.primary.label,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

extension on _SidebarAccountsPopoverState {
  /// Desktop's popover: an opaque neon glass panel floating over the sidebar,
  /// its two cut corners lit, headed by a red HUD caption, with the cut-corner
  /// slabs of `AppButton` for its two actions.
  Widget _buildNeon(BuildContext context, {required bool showScrollbar}) {
    final colors = context.colors;
    const cut = AppChamfer.large;
    return DefaultTextStyle.merge(
      style: const TextStyle(decoration: TextDecoration.none),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: Neon.wedgeBorder(cut: cut)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 17.5, sigmaY: 17.5),
          child: SizedBox(
            key: const ValueKey('sidebar_accounts_popover'),
            width: 221,
            height: 254,
            child: NeonGlassPanel(
              cut: cut,
              fill: colors.surface.nav,
              padding: const EdgeInsets.all(AppSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.xxs),
                    child: Text(
                      context.l10n.sidebarMyAccounts.toUpperCase(),
                      semanticsLabel: context.l10n.sidebarMyAccounts,
                      style: kNeonHudCaptionStyle.copyWith(
                        color: colors.neon.glow,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  SizedBox(
                    key: const ValueKey('sidebar_accounts_list'),
                    height: 153,
                    child: RawScrollbar(
                      key: const ValueKey('sidebar_accounts_scrollbar'),
                      controller: _scrollController,
                      thumbVisibility: showScrollbar,
                      radius: const Radius.circular(AppRadii.full),
                      thickness: 6,
                      mainAxisMargin: 6,
                      crossAxisMargin: 6,
                      thumbColor: colors.surface.scrollbarThumb,
                      child: Padding(
                        key: const ValueKey('sidebar_accounts_list_gutter'),
                        padding: const EdgeInsets.only(right: 18),
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(
                            context,
                          ).copyWith(scrollbars: false),
                          child: ListView.separated(
                            controller: _scrollController,
                            physics: const ClampingScrollPhysics(),
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.xs,
                            ),
                            itemCount: widget.accounts.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: AppSpacing.xxs),
                            itemBuilder: (context, index) {
                              final account = widget.accounts[index];
                              return _SidebarAccountPopoverRow(
                                key: ValueKey(
                                  'sidebar_account_popover_row_${account.uuid}',
                                ),
                                account: account,
                                selected:
                                    account.uuid == widget.activeAccountUuid,
                                onTap: () =>
                                    widget.onSelectAccount(account.uuid),
                                onCopyAddress:
                                    account.uuid == widget.activeAccountUuid
                                    ? null
                                    : () =>
                                          widget.onCopyAccountAddress(account),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  const _SidebarAccountsActionsDivider(),
                  const SizedBox(height: AppSpacing.xs),
                  SizedBox(
                    height: 36,
                    child: Row(
                      children: [
                        _SidebarPopoverHoverTarget(
                          onTap: widget.onManageAccounts,
                          builder: (context, hovered) => Container(
                            key: const ValueKey('sidebar_accounts_manage'),
                            width: 153,
                            height: 36,
                            alignment: Alignment.center,
                            // A glass slab with a hairline edge.
                            decoration: ShapeDecoration(
                              color: hovered
                                  ? colors.button.secondary.bgHover
                                  : colors.button.secondary.bg,
                              shape: Neon.chamferBorder(
                                cut: 6,
                                side: BorderSide(
                                  color: colors.border.subtleOpacity,
                                ),
                              ),
                            ),
                            child: Text(
                              context.l10n.commonManage,
                              style: AppTypography.labelLarge.copyWith(
                                color: colors.button.secondary.label,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xxs),
                        _SidebarPopoverHoverTarget(
                          onTap: widget.onAddAccount,
                          builder: (context, hovered) {
                            final fill = hovered
                                ? colors.button.primary.bgHover
                                : colors.button.primary.bg;
                            // The primary slab, lit with its red glow.
                            return Container(
                              key: const ValueKey('sidebar_accounts_add'),
                              width: 48,
                              height: 32,
                              decoration: ShapeDecoration(
                                color: fill,
                                shape: Neon.chamferBorder(cut: 6),
                                shadows: Neon.boxGlow(fill, intensity: 0.5),
                              ),
                              child: Center(
                                child: AppIcon(
                                  AppIcons.addNew,
                                  size: 16,
                                  color: colors.button.primary.label,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarAccountsActionsDivider extends StatelessWidget {
  const _SidebarAccountsActionsDivider();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('sidebar_accounts_actions_divider'),
      height: 1,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(color: context.colors.border.subtle),
      ),
    );
  }
}

class _SidebarAccountPopoverRow extends StatelessWidget {
  const _SidebarAccountPopoverRow({
    super.key,
    required this.account,
    required this.selected,
    required this.onTap,
    this.onCopyAddress,
  });

  final AccountInfo account;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onCopyAddress;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AppTappable(
      onTap: onTap,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: selected ? colors.state.hover : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadii.small),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxs),
          child: Row(
            children: [
              _SidebarAccountAvatar(
                profilePictureId: account.profilePictureId,
                hardwareSignerKind: account.hardwareSignerKind,
              ),
              const SizedBox(width: AppSpacing.s),
              Expanded(
                child: Text(
                  account.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.labelLarge.copyWith(
                    color: colors.text.accent,
                  ),
                ),
              ),
              if (onCopyAddress != null)
                _SidebarCopyAddressButton(onTap: onCopyAddress)
              else if (selected)
                AppIcon(AppIcons.check, size: 16, color: colors.icon.regular),
            ],
          ),
        ),
      ),
    );
  }
}

/// Click target that also tracks hover, for the popover's pill buttons.
class _SidebarPopoverHoverTarget extends StatefulWidget {
  const _SidebarPopoverHoverTarget({
    required this.onTap,
    required this.builder,
  });

  final VoidCallback onTap;
  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<_SidebarPopoverHoverTarget> createState() =>
      _SidebarPopoverHoverTargetState();
}

class _SidebarPopoverHoverTargetState
    extends State<_SidebarPopoverHoverTarget> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: widget.builder(context, _hovered),
        ),
      ),
    );
  }
}
