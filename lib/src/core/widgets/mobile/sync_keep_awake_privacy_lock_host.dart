import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/onboarding/mobile/mobile_passcode_screen.dart';
import '../../../features/onboarding/mobile/passcode_widgets.dart';
import '../../../features/onboarding/mobile/adaptive_passcode_layout.dart';
import '../../../features/onboarding/shared/onboarding_welcome_art.dart';
import '../../../features/private_usd/private_usd_copy.dart';
import '../../../features/private_usd/providers/private_usd_keep_awake_provider.dart';
import '../../../features/private_usd/providers/private_usd_sync_lock_provider.dart';
import '../../../providers/app_security_provider.dart';
import '../../../providers/biometric_unlock_provider.dart';
import '../../../providers/sync_display_progress_provider.dart';
import '../../../providers/sync_keep_awake_provider.dart';
import '../../../providers/sync_provider.dart';
import '../../../services/biometric_unlock.dart';
import '../../feedback/app_haptics.dart';
import '../../formatting/sync_status_label.dart';
import '../../layout/app_form_factor.dart';
import '../../layout/mobile/mobile_top_nav.dart';
import '../../theme/app_theme.dart';
import '../app_button.dart';
import '../app_icon.dart';
import '../biometric_icon.dart';
import 'neon_done_sign.dart';
import 'neon_glyph_badge.dart';
import 'neon_motion.dart';
import 'neon_scramble_text.dart';
import 'tron_glyph.dart';

class SyncKeepAwakePrivacyLockHost extends ConsumerStatefulWidget {
  const SyncKeepAwakePrivacyLockHost({
    required this.child,
    this.idleTimeout = kSyncKeepAwakePrivacyIdleTimeout,
    super.key,
  });

  final Widget child;
  final Duration idleTimeout;

  @override
  ConsumerState<SyncKeepAwakePrivacyLockHost> createState() =>
      _SyncKeepAwakePrivacyLockHostState();
}

class _SyncKeepAwakePrivacyLockHostState
    extends ConsumerState<SyncKeepAwakePrivacyLockHost>
    with SingleTickerProviderStateMixin {
  Timer? _idleTimer;

  /// The last mode shown, kept on screen while it switches off.
  SyncKeepAwakePrivacyLockMode? _shownMode;
  late final AnimationController _crtOff =
      AnimationController(vsync: this, duration: NeonMotion.crtOff)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() => _shownMode = null);
          }
        });
  AppLifecycleListener? _lifecycleListener;
  bool _isInForeground = true;
  bool _clearScheduled = false;

  @override
  void initState() {
    super.initState();
    if (kAppFormFactor != AppFormFactor.mobile) return;

    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _isInForeground =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    _lifecycleListener = AppLifecycleListener(
      onResume: _handleLifecycleResume,
      onInactive: _handleLifecycleBackground,
      onHide: _handleLifecycleBackground,
      onPause: _handleLifecycleBackground,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (kAppFormFactor != AppFormFactor.mobile) return widget.child;

    // A Private USD bridge that needs the user's approval, now or next, is
    // not covered. Once it no longer does, the user gets a full idle window
    // again rather than a lock on the next frame.
    ref.listen<bool>(privateUsdBridgeAwaitsUserProvider, (waited, waits) {
      if (waited == true && !waits) {
        ref.read(syncKeepAwakeInteractionProvider.notifier).markInteraction();
      }
    });
    // Railgun's sync starting under the lock joins it.
    ref.listen(privateUsdSyncStatusProvider, (_, status) {
      if (status == PrivateUsdSyncStatus.syncing) {
        ref.read(syncKeepAwakePrivacyLockProvider.notifier).includeRailgun();
      }
    });
    final active =
        ref.watch(syncKeepAwakePrivacyLockActiveProvider) &&
        !ref.watch(privateUsdBridgeAwaitsUserProvider);
    final interaction = ref.watch(syncKeepAwakeInteractionProvider);
    final mode = ref.watch(syncKeepAwakePrivacyLockModeProvider);
    final visible = mode != SyncKeepAwakePrivacyLockMode.hidden;
    _syncIdleTimer(active: active, interaction: interaction, visible: visible);

    if (visible) {
      _shownMode = mode;
      if (_crtOff.value > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _crtOff.value = 0;
        });
      }
    } else if (_shownMode != null && !_crtOff.isAnimating) {
      if (NeonMotion.reduced(context) ||
          ref.read(appSecurityProvider).requiresUnlock) {
        _shownMode = null;
      } else {
        // Switch off as a CRT, then drop the screen (see [_crtOff]).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _shownMode != null && !_crtOff.isAnimating) {
            unawaited(_crtOff.forward(from: 0));
          }
        });
      }
    }
    final shown = _shownMode;

    // The lock covers the app without replacing its route, so the app stays
    // mounted underneath. While the lock shows, screen readers, keyboard
    // focus and pointers must not reach it: a screen reader would otherwise
    // keep its focus on the covered screen and read or activate it. A lock
    // switching off is already gone for them.
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          excluding: visible,
          child: ExcludeFocus(
            excluding: visible,
            child: IgnorePointer(ignoring: visible, child: widget.child),
          ),
        ),
        if (shown != null)
          Positioned.fill(
            child: ExcludeSemantics(
              excluding: !visible,
              child: IgnorePointer(
                ignoring: !visible,
                child: _CrtSwitchOff(
                  animation: _crtOff,
                  child: SyncKeepAwakePrivacyLockScreen(mode: shown),
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    _idleTimer?.cancel();
    _crtOff.dispose();
    super.dispose();
  }

  void _handleLifecycleBackground() {
    if (!_isInForeground) return;
    _isInForeground = false;
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _handleLifecycleResume() {
    if (_isInForeground) return;
    _isInForeground = true;
    // Returning to the app is an explicit user interaction. Reset the idle
    // window before the provider rebuild rearms the timer so time spent while
    // the app was not visible never causes an immediate privacy lock.
    ref.read(syncKeepAwakeInteractionProvider.notifier).markInteraction();
  }

  void _syncIdleTimer({
    required bool active,
    required SyncKeepAwakeInteractionState interaction,
    required bool visible,
  }) {
    if (!_isInForeground || !active) {
      _idleTimer?.cancel();
      _idleTimer = null;
      if (visible) return;
      _clearAfterFrameIfInactive();
      return;
    }

    if (visible) {
      _idleTimer?.cancel();
      _idleTimer = null;
      return;
    }

    final remaining =
        widget.idleTimeout - interaction.idleDuration(DateTime.now());
    _idleTimer?.cancel();
    _idleTimer = Timer(
      remaining <= Duration.zero ? Duration.zero : remaining,
      () => _lockIfStillIdle(interaction.revision),
    );
  }

  void _lockIfStillIdle(int expectedRevision) {
    if (!mounted) return;
    if (!_isInForeground) return;
    if (!ref.read(syncKeepAwakePrivacyLockActiveProvider)) return;
    if (ref.read(privateUsdBridgeAwaitsUserProvider)) return;
    if (ref.read(syncKeepAwakePrivacyLockProvider).isLocked) return;

    final interaction = ref.read(syncKeepAwakeInteractionProvider);
    if (interaction.revision != expectedRevision) {
      _syncIdleTimer(active: true, interaction: interaction, visible: false);
      return;
    }

    // The privacy overlay does not replace the underlying route. Dismiss its
    // input connection and native keyboard controls before covering the content.
    FocusManager.instance.primaryFocus?.unfocus();
    ref
        .read(syncKeepAwakePrivacyLockProvider.notifier)
        .lock(
          railgun:
              ref.read(privateUsdSyncStatusProvider) ==
              PrivateUsdSyncStatus.syncing,
        );
  }

  void _clearAfterFrameIfInactive() {
    if (_clearScheduled ||
        !ref.read(syncKeepAwakePrivacyLockProvider).isLocked) {
      return;
    }
    _clearScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _clearScheduled = false;
      if (!mounted || ref.read(syncKeepAwakePrivacyLockActiveProvider)) return;
      ref.read(syncKeepAwakePrivacyLockProvider.notifier).clear();
    });
  }
}

class SyncKeepAwakePrivacyLockScreen extends ConsumerStatefulWidget {
  const SyncKeepAwakePrivacyLockScreen({
    this.mode = SyncKeepAwakePrivacyLockMode.syncing,
    super.key,
  });

  final SyncKeepAwakePrivacyLockMode mode;

  static const _figmaReferenceHeight = 852.0;
  static const _shortScreenOuterMargin = 32.0;
  static const _logoTopGap = 110.0;
  static const _logoWidth = 106.0;
  static const _logoHeight = 40.0;
  static const _logoToRingGap = 81.0;
  static const _minimumLogoToRingGap = 48.0;
  static const _ringSize = 303.0;
  static const _ringToButtonGap = 129.0;
  static const _minimumRingToButtonGap = 48.0;
  static const _logoToDoneStatusGap = 156.0;
  static const _minimumLogoToDoneStatusGap = 48.0;
  static const _doneStatusHeight = 200.0;
  static const _doneStatusToButtonGap = 147.0;
  static const _minimumDoneStatusToButtonGap = 48.0;

  /// Railgun's ring, with a line under it: the gaps give the line its room.
  static const _logoToRingsGap = 64.0;
  static const _minimumLogoToRingsGap = 40.0;
  static const _ringsLineGap = 20.0;
  static const _ringsToButtonGap = 76.0;
  static const _minimumRingsToButtonGap = 32.0;

  static TextStyle _ringsLineStyle(BuildContext context) =>
      AppTypography.bodyMedium.copyWith(color: context.colors.text.secondary);

  /// [line]'s height as drawn under the rings, at the reader's text size.
  static double _ringsLineHeightOf(BuildContext context, String line) {
    final defaults = DefaultTextStyle.of(context);
    final painter = TextPainter(
      text: TextSpan(
        text: line,
        style: defaults.style.merge(_ringsLineStyle(context)),
      ),
      textAlign: TextAlign.center,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      textHeightBehavior: defaults.textHeightBehavior,
    )..layout(maxWidth: _doneBodyWidth);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  static const _syncingBody = 'Veylor is syncing';

  /// Wide enough to keep each body line whole.
  static const _bodyWidth = 200.0;
  static const _doneBodyWidth = 280.0;

  @override
  ConsumerState<SyncKeepAwakePrivacyLockScreen> createState() =>
      _SyncKeepAwakePrivacyLockScreenState();
}

class _SyncKeepAwakePrivacyLockScreenState
    extends ConsumerState<SyncKeepAwakePrivacyLockScreen> {
  var _showPasscode = false;
  var _passcodeEntry = '';
  var _submittingPasscode = false;
  var _unlockAttemptInFlight = false;
  String? _passcodeError;
  late final VoidCallback _detachBackHandler;

  @override
  void initState() {
    super.initState();
    _detachBackHandler = ref
        .read(syncKeepAwakePrivacyLockBackProvider)
        .attach(_handleSystemBack);
  }

  void _handleSystemBack() {
    if (_submittingPasscode || _unlockAttemptInFlight || !_showPasscode) return;
    _returnToStatusScreen();
  }

  @override
  void dispose() {
    _detachBackHandler();
    super.dispose();
  }

  @override
  void didUpdateWidget(SyncKeepAwakePrivacyLockScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.mode == SyncKeepAwakePrivacyLockMode.hidden && _showPasscode) {
      _resetPasscodePrompt();
    }
  }

  void _openPasscodePrompt({String? error}) {
    setState(() {
      _showPasscode = true;
      _passcodeEntry = '';
      _passcodeError = error;
      _submittingPasscode = false;
      _unlockAttemptInFlight = false;
    });
  }

  void _returnToStatusScreen() {
    if (_submittingPasscode) return;
    setState(_resetPasscodePrompt);
  }

  void _resetPasscodePrompt() {
    _showPasscode = false;
    _passcodeEntry = '';
    _passcodeError = null;
    _submittingPasscode = false;
    _unlockAttemptInFlight = false;
  }

  void _onPasscodeDigit(int digit) {
    if (_submittingPasscode || _passcodeEntry.length >= kMobilePasscodeLength) {
      return;
    }
    setState(() {
      _passcodeEntry += '$digit';
      _passcodeError = null;
    });
    if (_passcodeEntry.length == kMobilePasscodeLength) {
      unawaited(_submitPasscode());
    }
  }

  void _onPasscodeBackspace() {
    if (_submittingPasscode || _passcodeEntry.isEmpty) return;
    setState(() {
      _passcodeEntry = _passcodeEntry.substring(0, _passcodeEntry.length - 1);
      _passcodeError = null;
    });
  }

  Future<void> _submitPasscode() async {
    if (_submittingPasscode) return;
    await _confirmPasscode(_passcodeEntry);
  }

  Future<void> _unlockOrPromptPasscode() async {
    if (_submittingPasscode || _unlockAttemptInFlight) return;

    setState(() {
      _unlockAttemptInFlight = true;
      _passcodeError = null;
    });

    final BiometricUnlockState biometric;
    try {
      biometric = await ref.read(biometricUnlockProvider.future);
    } catch (_) {
      if (mounted) _openPasscodePrompt();
      return;
    }
    if (!mounted) return;

    if (!biometric.usable) {
      _openPasscodePrompt();
      return;
    }

    final wasEnabled = biometric.enabled;
    final passcode = await ref
        .read(biometricUnlockProvider.notifier)
        .readPasscode(reason: 'Unlock Veylor');
    if (!mounted) return;

    if (passcode == null) {
      final now = ref.read(biometricUnlockProvider).value;
      final error = wasEnabled && now != null && !now.enabled
          ? biometric.availability.kind.changedMessage
          : null;
      _openPasscodePrompt(error: error);
      return;
    }

    await _confirmPasscode(passcode);
  }

  Future<void> _confirmPasscode(String passcode) async {
    setState(() {
      _submittingPasscode = true;
      _passcodeError = null;
    });

    var confirmed = false;
    try {
      confirmed = await ref
          .read(appSecurityProvider.notifier)
          .confirmPassword(passcode);
    } catch (_) {
      confirmed = false;
    }
    if (!mounted) return;

    if (confirmed) {
      ref.read(syncKeepAwakePrivacyLockProvider.notifier).unlock();
      unawaited(AppHaptics.accessGranted());
      return;
    }

    unawaited(AppHaptics.error());
    setState(() {
      _submittingPasscode = false;
      _unlockAttemptInFlight = false;
      _showPasscode = true;
      _passcodeEntry = '';
      _passcodeError = 'Incorrect Passcode';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_showPasscode) {
      return _SyncKeepAwakePasscodeConfirmScreen(
        mode: widget.mode,
        entryLength: _passcodeEntry.length,
        error: _passcodeError,
        submitting: _submittingPasscode,
        onBack: _returnToStatusScreen,
        onDigit: _onPasscodeDigit,
        onBackspace: _onPasscodeBackspace,
      );
    }

    return _SyncKeepAwakeStatusScreen(
      mode: widget.mode,
      onUnlockPressed: _unlockAttemptInFlight || _submittingPasscode
          ? null
          : () => unawaited(_unlockOrPromptPasscode()),
    );
  }
}

class _SyncKeepAwakeStatusScreen extends ConsumerWidget {
  const _SyncKeepAwakeStatusScreen({
    required this.mode,
    required this.onUnlockPressed,
  });

  final SyncKeepAwakePrivacyLockMode mode;
  final VoidCallback? onUnlockPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final biometric =
        ref.watch(biometricUnlockProvider).value ??
        BiometricUnlockState.initial;
    // Railgun's ring while its sync runs; once it is done, the wallet's own
    // ring, as without it.
    final syncing =
        mode == SyncKeepAwakePrivacyLockMode.syncing ||
        mode == SyncKeepAwakePrivacyLockMode.hidden;
    final railgunStage =
        syncing &&
            ref.watch(
              syncKeepAwakePrivacyLockProvider.select((lock) => lock.railgun),
            ) &&
            ref.watch(
              _syncKeepAwakeRingsProvider.select((rings) => rings.railgunRing),
            )
        ? ref.watch(
            _syncKeepAwakeRingsProvider.select((rings) => rings.railgun.stage),
          )
        : null;
    final railgunLine = railgunStage == null
        ? null
        : _railgunLine(railgunStage);
    final main = switch (mode) {
      SyncKeepAwakePrivacyLockMode.done => const _SyncKeepAwakeStatusLockup(
        glyph: TronGlyphKind.check,
        glyphKey: ValueKey('sync_keep_awake_privacy_done_check'),
        title: 'Sync complete',
        body: 'Unlock Veylor to continue',
        animate: true,
      ),
      SyncKeepAwakePrivacyLockMode.interrupted =>
        const _SyncKeepAwakeStatusLockup(
          glyph: TronGlyphKind.warning,
          glyphKey: ValueKey('sync_keep_awake_privacy_interrupted_warning'),
          title: 'Sync paused',
          body: 'Unlock Veylor to continue.',
        ),
      SyncKeepAwakePrivacyLockMode.hidden ||
      SyncKeepAwakePrivacyLockMode.syncing =>
        railgunLine != null
            ? _SyncKeepAwakeRingsLockup(line: railgunLine)
            : const _SyncKeepAwakeDisplayProgressLockup(),
    };
    final semanticsLabel = switch (mode) {
      SyncKeepAwakePrivacyLockMode.done => 'Veylor is synced',
      SyncKeepAwakePrivacyLockMode.interrupted => 'Veylor sync is paused',
      SyncKeepAwakePrivacyLockMode.hidden ||
      SyncKeepAwakePrivacyLockMode.syncing =>
        SyncKeepAwakePrivacyLockScreen._syncingBody,
    };

    return Material(
      color: colors.background.window,
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: semanticsLabel,
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final layout = _resolveVerticalLayout(
                availableHeight: constraints.maxHeight,
                screenHeight: MediaQuery.sizeOf(context).height,
                mode: mode,
                ringsLineHeight: railgunLine == null
                    ? null
                    : SyncKeepAwakePrivacyLockScreen._ringsLineHeightOf(
                        context,
                        railgunLine,
                      ),
              );
              return Column(
                children: [
                  SizedBox(height: layout.topGap),
                  const VizorWordmark(
                    key: ValueKey('sync_keep_awake_privacy_logo'),
                    width: SyncKeepAwakePrivacyLockScreen._logoWidth,
                    height: SyncKeepAwakePrivacyLockScreen._logoHeight,
                  ),
                  SizedBox(height: layout.logoToMainGap),
                  main,
                  SizedBox(height: layout.mainToButtonGap),
                  NeonIgnition(
                    key: ValueKey(mode == SyncKeepAwakePrivacyLockMode.done),
                    delay: mode == SyncKeepAwakePrivacyLockMode.done
                        ? const Duration(milliseconds: 1500)
                        : Duration.zero,
                    // Dark until it switches on, and not to be tapped then.
                    builder: (context, light) => IgnorePointer(
                      ignoring: light == 0,
                      child: Opacity(
                        opacity: light,
                        child: AppButton(
                          key: const ValueKey(
                            'sync_keep_awake_privacy_unlock_button',
                          ),
                          onPressed: onUnlockPressed,
                          leading: _SyncKeepAwakeUnlockIcon(
                            biometric: biometric,
                          ),
                          minWidth: 165,
                          child: const Text('Unlock Veylor'),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  _SyncKeepAwakeVerticalLayout _resolveVerticalLayout({
    required double availableHeight,
    required double screenHeight,
    required SyncKeepAwakePrivacyLockMode mode,
    double? ringsLineHeight,
  }) {
    final spec = _SyncKeepAwakeLayoutSpec.forMode(
      mode,
      ringsLineHeight: ringsLineHeight,
    );
    // The reference positions, where they fit: a line under Railgun's ring
    // grows with the reader's text size.
    if (screenHeight >= SyncKeepAwakePrivacyLockScreen._figmaReferenceHeight &&
        SyncKeepAwakePrivacyLockScreen._logoTopGap + spec.stackHeight <=
            availableHeight) {
      return _SyncKeepAwakeVerticalLayout(
        topGap: SyncKeepAwakePrivacyLockScreen._logoTopGap,
        logoToMainGap: spec.logoToMainGap,
        mainToButtonGap: spec.mainToButtonGap,
      );
    }

    var logoToMainGap = spec.logoToMainGap;
    var mainToButtonGap = spec.mainToButtonGap;
    final targetStackHeight = math.max(
      spec.minimumStackHeight,
      availableHeight -
          (SyncKeepAwakePrivacyLockScreen._shortScreenOuterMargin * 2),
    );
    final reduction = math.min(
      spec.stackHeight - targetStackHeight,
      (spec.logoToMainGap - spec.minimumLogoToMainGap) +
          (spec.mainToButtonGap - spec.minimumMainToButtonGap),
    );

    if (reduction > 0) {
      final logoReducible = spec.logoToMainGap - spec.minimumLogoToMainGap;
      final buttonReducible =
          spec.mainToButtonGap - spec.minimumMainToButtonGap;
      final totalReducible = logoReducible + buttonReducible;
      logoToMainGap -= reduction * logoReducible / totalReducible;
      mainToButtonGap -= reduction * buttonReducible / totalReducible;
    }

    final stackHeight =
        SyncKeepAwakePrivacyLockScreen._logoHeight +
        logoToMainGap +
        spec.mainHeight +
        mainToButtonGap +
        AppButtonSizingMobile.largeHeight;

    return _SyncKeepAwakeVerticalLayout(
      topGap: math.max(0, (availableHeight - stackHeight) / 2),
      logoToMainGap: logoToMainGap,
      mainToButtonGap: mainToButtonGap,
    );
  }
}

class _SyncKeepAwakeDisplayProgressLockup extends ConsumerWidget {
  const _SyncKeepAwakeDisplayProgressLockup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _SyncKeepAwakeProgressLockup(
      progress: ref.watch(syncDisplayPercentageProvider),
    );
  }
}

class _SyncKeepAwakeLayoutSpec {
  const _SyncKeepAwakeLayoutSpec({
    required this.logoToMainGap,
    required this.minimumLogoToMainGap,
    required this.mainHeight,
    required this.mainToButtonGap,
    required this.minimumMainToButtonGap,
  });

  final double logoToMainGap;
  final double minimumLogoToMainGap;
  final double mainHeight;
  final double mainToButtonGap;
  final double minimumMainToButtonGap;

  double get stackHeight =>
      SyncKeepAwakePrivacyLockScreen._logoHeight +
      logoToMainGap +
      mainHeight +
      mainToButtonGap +
      AppButtonSizingMobile.largeHeight;

  double get minimumStackHeight =>
      SyncKeepAwakePrivacyLockScreen._logoHeight +
      minimumLogoToMainGap +
      mainHeight +
      minimumMainToButtonGap +
      AppButtonSizingMobile.largeHeight;

  /// [ringsLineHeight]: two rings show, with a line this tall under them.
  factory _SyncKeepAwakeLayoutSpec.forMode(
    SyncKeepAwakePrivacyLockMode mode, {
    double? ringsLineHeight,
  }) {
    if (mode == SyncKeepAwakePrivacyLockMode.done ||
        mode == SyncKeepAwakePrivacyLockMode.interrupted) {
      return const _SyncKeepAwakeLayoutSpec(
        logoToMainGap: SyncKeepAwakePrivacyLockScreen._logoToDoneStatusGap,
        minimumLogoToMainGap:
            SyncKeepAwakePrivacyLockScreen._minimumLogoToDoneStatusGap,
        mainHeight: SyncKeepAwakePrivacyLockScreen._doneStatusHeight,
        mainToButtonGap: SyncKeepAwakePrivacyLockScreen._doneStatusToButtonGap,
        minimumMainToButtonGap:
            SyncKeepAwakePrivacyLockScreen._minimumDoneStatusToButtonGap,
      );
    }
    if (ringsLineHeight != null) {
      return _SyncKeepAwakeLayoutSpec(
        logoToMainGap: SyncKeepAwakePrivacyLockScreen._logoToRingsGap,
        minimumLogoToMainGap:
            SyncKeepAwakePrivacyLockScreen._minimumLogoToRingsGap,
        mainHeight:
            SyncKeepAwakePrivacyLockScreen._ringSize +
            SyncKeepAwakePrivacyLockScreen._ringsLineGap +
            ringsLineHeight,
        mainToButtonGap: SyncKeepAwakePrivacyLockScreen._ringsToButtonGap,
        minimumMainToButtonGap:
            SyncKeepAwakePrivacyLockScreen._minimumRingsToButtonGap,
      );
    }
    return const _SyncKeepAwakeLayoutSpec(
      logoToMainGap: SyncKeepAwakePrivacyLockScreen._logoToRingGap,
      minimumLogoToMainGap:
          SyncKeepAwakePrivacyLockScreen._minimumLogoToRingGap,
      mainHeight: SyncKeepAwakePrivacyLockScreen._ringSize,
      mainToButtonGap: SyncKeepAwakePrivacyLockScreen._ringToButtonGap,
      minimumMainToButtonGap:
          SyncKeepAwakePrivacyLockScreen._minimumRingToButtonGap,
    );
  }
}

class _SyncKeepAwakeUnlockIcon extends StatelessWidget {
  const _SyncKeepAwakeUnlockIcon({required this.biometric});

  final BiometricUnlockState biometric;

  @override
  Widget build(BuildContext context) {
    if (!biometric.usable) return const AppIcon(AppIcons.unlock);

    return BiometricIcon(kind: biometric.availability.kind);
  }
}

class _SyncKeepAwakeVerticalLayout {
  const _SyncKeepAwakeVerticalLayout({
    required this.topGap,
    required this.logoToMainGap,
    required this.mainToButtonGap,
  });

  final double topGap;
  final double logoToMainGap;
  final double mainToButtonGap;
}

class _SyncKeepAwakePasscodeConfirmScreen extends StatelessWidget {
  const _SyncKeepAwakePasscodeConfirmScreen({
    required this.mode,
    required this.entryLength,
    required this.submitting,
    required this.onBack,
    required this.onDigit,
    required this.onBackspace,
    this.error,
  });

  final SyncKeepAwakePrivacyLockMode mode;
  final int entryLength;
  final bool submitting;
  final VoidCallback onBack;
  final ValueChanged<int> onDigit;
  final VoidCallback onBackspace;
  final String? error;

  static const _topNavHeight = 74.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      key: const ValueKey('sync_keep_awake_privacy_passcode_screen'),
      color: colors.background.window,
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: 'Confirm passcode to unlock Veylor',
        child: SafeArea(
          child: Column(
            children: [
              Consumer(
                builder: (context, ref, _) => MobileTopNav.back(
                  title: _titleForMode(_syncingWhole(ref)),
                  height: _topNavHeight,
                  onBack: submitting ? null : onBack,
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxHeight < 640;
                    final verticalPadding = compact
                        ? AppSpacing.s
                        : AppSpacing.md;
                    final topGap = compact ? 0.0 : AppSpacing.md;
                    final sectionGap = compact ? AppSpacing.xs : AppSpacing.md;

                    return AdaptivePasscodeLayout(
                      title: 'Welcome back',
                      subtitle: _bodyForMode(),
                      prompt: PasscodePromptField(
                        length: kMobilePasscodeLength,
                        filled: entryLength,
                        error: error,
                        minGap: 0,
                      ),
                      keypad: PasscodeNumpad(
                        onDigit: onDigit,
                        onBackspace: onBackspace,
                        canDelete: entryLength > 0,
                        enabled: !submitting,
                      ),
                      legacyPadding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: verticalPadding,
                      ),
                      titleStyle: kNeonPageTitleStyle.copyWith(
                        color: colors.text.accent,
                      ),
                      uppercaseTitle: true,
                      subtitleStyle: AppTypography.bodyMedium.copyWith(
                        color: colors.text.secondary,
                      ),
                      legacySpacing: topGap + AppSpacing.s + sectionGap * 2,
                      legacyCentersPrompt: false,
                      legacyKeypadGap: sectionGap,
                      legacy: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: verticalPadding,
                        ),
                        child: Column(
                          children: [
                            SizedBox(height: topGap),
                            const _SyncKeepAwakeTitle('Welcome back'),
                            const SizedBox(height: AppSpacing.s),
                            Text(
                              _bodyForMode(),
                              textAlign: TextAlign.center,
                              style: AppTypography.bodyMedium.copyWith(
                                color: colors.text.secondary,
                              ),
                            ),
                            SizedBox(height: sectionGap),
                            SizedBox(
                              height: kPasscodePromptDigitsHeight,
                              child: PasscodePromptField(
                                length: kMobilePasscodeLength,
                                filled: entryLength,
                                error: error,
                                minGap: 0,
                              ),
                            ),
                            SizedBox(height: sectionGap),
                            PasscodeNumpad(
                              onDigit: onDigit,
                              onBackspace: onBackspace,
                              canDelete: entryLength > 0,
                              enabled: !submitting,
                            ),
                            const Spacer(),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The figure of the one ring the lock shows; none while it shows two.
  int? _syncingWhole(WidgetRef ref) {
    if (mode != SyncKeepAwakePrivacyLockMode.syncing &&
        mode != SyncKeepAwakePrivacyLockMode.hidden) {
      return null;
    }
    if (ref.watch(
      syncKeepAwakePrivacyLockProvider.select((lock) => lock.railgun),
    )) {
      final rings = ref.watch(_syncKeepAwakeRingsProvider);
      if (rings.railgunRing) {
        if (rings.zecRing) return null;
        return (rings.railgun.progress * 100).floor().clamp(0, 99);
      }
    }
    return ref.watch(syncDisplayWholePercentageProvider);
  }

  String _titleForMode(int? displayWholePercentage) {
    return switch (mode) {
      SyncKeepAwakePrivacyLockMode.done => 'Synced',
      SyncKeepAwakePrivacyLockMode.interrupted => 'Sync paused',
      SyncKeepAwakePrivacyLockMode.hidden ||
      SyncKeepAwakePrivacyLockMode.syncing =>
        displayWholePercentage == null
            ? 'Syncing...'
            : '$displayWholePercentage% Syncing...',
    };
  }

  String _bodyForMode() {
    if (submitting) return 'Checking passcode...';
    return switch (mode) {
      SyncKeepAwakePrivacyLockMode.done =>
        'Synced successfully. Unlock Veylor to continue.',
      SyncKeepAwakePrivacyLockMode.interrupted =>
        'Sync paused. Unlock Veylor to continue.',
      SyncKeepAwakePrivacyLockMode.hidden ||
      SyncKeepAwakePrivacyLockMode.syncing => 'Unlock to continue',
    };
  }
}

/// A title on the privacy screen, drawn as a page title
/// ([kNeonPageTitleStyle]). The string stays sentence case: it is upper-cased
/// where drawn, and screen readers get it as written.
class _SyncKeepAwakeTitle extends StatelessWidget {
  const _SyncKeepAwakeTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      semanticsLabel: text,
      textAlign: TextAlign.center,
      style: kNeonPageTitleStyle.copyWith(color: context.colors.text.accent),
    );
  }
}

/// Done and paused: a lit glyph on a cut-corner plate over the state's
/// title and a line of Light body text.
class _SyncKeepAwakeStatusLockup extends StatelessWidget {
  const _SyncKeepAwakeStatusLockup({
    required this.glyph,
    required this.glyphKey,
    required this.title,
    required this.body,
    this.animate = false,
  });

  final TronGlyphKind glyph;
  final Key glyphKey;
  final String title;
  final String body;

  /// Switch on as a sign: a scanline, a light cycle drawing the badge, then
  /// the title decrypting in.
  final bool animate;

  static const _badgeSize = 72.0;
  static const _titleTop = 100.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: SyncKeepAwakePrivacyLockScreen._doneStatusHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Center(
              child: animate
                  ? NeonDoneSign(key: glyphKey, glyph: glyph, size: _badgeSize)
                  : NeonGlyphBadge(
                      key: glyphKey,
                      glyph: glyph,
                      size: _badgeSize,
                    ),
            ),
          ),
          Positioned(
            top: _titleTop,
            left: AppSpacing.md,
            right: AppSpacing.md,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (animate)
                  NeonIgnition(
                    delay: const Duration(milliseconds: 1000),
                    builder: (context, light) => light == 0
                        ? Opacity(opacity: 0, child: _SyncKeepAwakeTitle(title))
                        : NeonScrambleText(
                            text: title.toUpperCase(),
                            semanticsLabel: title,
                            style: kNeonPageTitleStyle.copyWith(
                              color: colors.text.accent,
                            ),
                            cipherStyle: kNeonPageTitleStyle.copyWith(
                              color: colors.neon.glow,
                            ),
                            decryptOnAppear: true,
                          ),
                  )
                else
                  _SyncKeepAwakeTitle(title),
                const SizedBox(height: AppSpacing.s),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: SyncKeepAwakePrivacyLockScreen._doneBodyWidth,
                  ),
                  child: Text(
                    body,
                    textAlign: TextAlign.center,
                    style: AppTypography.bodyMedium.copyWith(
                      color: colors.text.secondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Syncing: the progress as a lit ring around Thin numerals lit like the
/// balance sign's. The ring and its numerals switch on as a sign does.
class _SyncKeepAwakeProgressLockup extends StatelessWidget {
  const _SyncKeepAwakeProgressLockup({required this.progress});

  static const _progressAnimationDuration = Duration(milliseconds: 420);

  /// Neon numerals: Gotham Thin, whose hairline strokes read as tubes.
  static const _numeralStyle = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w100,
    fontSize: 56,
    height: 1,
    letterSpacing: -0.5,
  );

  /// The percent sign, set beside them as the sign's ticker is.
  static const _percentSignStyle = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w300,
    fontSize: 22,
    height: 1,
    letterSpacing: 1.2,
  );

  final double progress;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final neon = colors.neon;
    final targetProgress = progress.clamp(0.0, 1.0).toDouble();
    return SizedBox.square(
      dimension: SyncKeepAwakePrivacyLockScreen._ringSize,
      child: NeonIgnition(
        builder: (context, light) => TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: targetProgress, end: targetProgress),
          duration: _progressAnimationDuration,
          curve: Curves.easeOutCubic,
          builder: (context, animatedProgress, _) {
            return Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SyncKeepAwakeRingPainter(
                      progress: animatedProgress,
                      light: light,
                      glow: neon.glow,
                      core: neon.core,
                    ),
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: formatSyncStatusPercentage(
                                animatedProgress,
                              ),
                              style: _numeralStyle.copyWith(
                                color: neon.core,
                                shadows: Neon.textGlow(
                                  neon.glow,
                                  intensity: light,
                                ),
                              ),
                            ),
                            TextSpan(
                              text: '%',
                              style: _percentSignStyle.copyWith(
                                color: neon.glow,
                                shadows: Neon.textGlow(
                                  neon.glow,
                                  intensity: 0.6 * light,
                                ),
                              ),
                            ),
                          ],
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      SizedBox(
                        width: SyncKeepAwakePrivacyLockScreen._bodyWidth,
                        child: Text(
                          SyncKeepAwakePrivacyLockScreen._syncingBody,
                          textAlign: TextAlign.center,
                          style: AppTypography.bodyMedium.copyWith(
                            color: colors.text.secondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Both syncs while Railgun's is part of the lock: the wallet's progress as
/// its ring shows it, and Railgun's ring. Only a sync still running has a
/// ring: one that is done drops out, as there is nothing left to show.
@immutable
class _SyncKeepAwakeRings {
  const _SyncKeepAwakeRings({
    required this.zec,
    required this.zecStatus,
    required this.railgun,
  });

  final double zec;
  final SyncKeepAwakeWalletStatus zecStatus;
  final PrivateUsdSyncLockTrack railgun;

  bool get zecRing => zecStatus != SyncKeepAwakeWalletStatus.synced;
  bool get railgunRing => railgun.stage != PrivateUsdSyncLockStage.synced;

  @override
  bool operator ==(Object other) =>
      other is _SyncKeepAwakeRings &&
      other.zec == zec &&
      other.zecStatus == zecStatus &&
      other.railgun == railgun;

  @override
  int get hashCode => Object.hash(zec, zecStatus, railgun);
}

final _syncKeepAwakeRingsProvider = Provider.autoDispose<_SyncKeepAwakeRings>((
  ref,
) {
  final sync = ref.watch(syncProvider).asData?.value;
  final zecStatus = syncKeepAwakeWalletStatus(sync);
  return _SyncKeepAwakeRings(
    zec: switch (zecStatus) {
      SyncKeepAwakeWalletStatus.synced => 1.0,
      SyncKeepAwakeWalletStatus.syncing => ref.watch(
        syncDisplayPercentageProvider,
      ),
      SyncKeepAwakeWalletStatus.paused =>
        (sync?.percentage ?? 0).clamp(0.0, 1.0).toDouble(),
    },
    zecStatus: zecStatus,
    railgun: ref.watch(privateUsdSyncLockTrackProvider),
  );
});

/// What Railgun is doing, for the line under its ring.
String _railgunLine(PrivateUsdSyncLockStage stage) => switch (stage) {
  PrivateUsdSyncLockStage.balance => PrivateUsdCopy.syncLockLoadingBalance,
  PrivateUsdSyncLockStage.transactions => PrivateUsdCopy.syncLockBalanceReady,
  PrivateUsdSyncLockStage.paused => PrivateUsdCopy.syncLockPaused,
  PrivateUsdSyncLockStage.synced => SyncKeepAwakePrivacyLockScreen._syncingBody,
};

/// Railgun's sync while it runs: its ring in white light, named over its
/// percentage, and the wallet's lit red around it while that runs too. Under
/// them, [line] says what Railgun is doing: its balance loading, or its
/// transaction list, which the change from the wallet's sends waits on.
class _SyncKeepAwakeRingsLockup extends ConsumerWidget {
  const _SyncKeepAwakeRingsLockup({required this.line});

  final String line;

  /// How far inside the wallet's ring Railgun's runs beside it.
  static const _ringGap = 26.0;

  /// How lit a paused sync's ring and figures stay.
  static const _pausedLight = 0.35;

  /// The squares inside the innermost ring, clear of its ticks, that hold
  /// the figures: large text scales down to stay inside.
  static const _twoFiguresSize = 150.0;
  static const _oneFigureSize = 180.0;

  static const _zecName = 'ZEC';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final neon = colors.neon;
    final rings = ref.watch(_syncKeepAwakeRingsProvider);
    final railgun = rings.railgun;
    final both = rings.zecRing;
    final zecPaused = rings.zecStatus == SyncKeepAwakeWalletStatus.paused;
    final railgunPaused = railgun.stage == PrivateUsdSyncLockStage.paused;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: SyncKeepAwakePrivacyLockScreen._ringSize,
          child: NeonIgnition(
            builder: (context, light) => _AnimatedSyncProgress(
              progress: rings.zec,
              builder: (context, zec) => _AnimatedSyncProgress(
                // The transaction list's climb starts afresh, not wound back.
                key: ValueKey(
                  railgun.stage == PrivateUsdSyncLockStage.transactions,
                ),
                progress: railgun.progress,
                builder: (context, railgunProgress) {
                  final railgunReadout = _SyncKeepAwakeRingReadout(
                    name: PrivateUsdCopy.syncLockName,
                    progress: railgunProgress,
                    paused: railgunPaused,
                    large: !both,
                    glow: neon.secondaryGlow,
                    core: neon.secondaryCore,
                    light: light,
                  );
                  return Stack(
                    children: [
                      if (both)
                        Positioned.fill(
                          child: CustomPaint(
                            key: const ValueKey(
                              'sync_keep_awake_privacy_zec_ring',
                            ),
                            painter: _SyncKeepAwakeRingPainter(
                              progress: zec,
                              light: zecPaused ? _pausedLight * light : light,
                              glow: neon.glow,
                              core: neon.core,
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: CustomPaint(
                          key: const ValueKey(
                            'sync_keep_awake_privacy_railgun_ring',
                          ),
                          painter: _SyncKeepAwakeRingPainter(
                            progress: railgunProgress,
                            light: railgunPaused ? _pausedLight * light : light,
                            glow: neon.secondaryGlow,
                            core: neon.secondaryCore,
                            inset: both
                                ? _SyncKeepAwakeRingPainter.outerInset +
                                      _ringGap
                                : _SyncKeepAwakeRingPainter.outerInset,
                          ),
                        ),
                      ),
                      Center(
                        child: Semantics(
                          container: true,
                          label: [
                            both
                                ? _readoutLabel(
                                    _zecName,
                                    zec,
                                    paused: zecPaused,
                                  )
                                : '$_zecName synced',
                            _readoutLabel(
                              PrivateUsdCopy.syncLockName,
                              railgunProgress,
                              paused: railgunPaused,
                            ),
                          ].join('. '),
                          child: SizedBox.square(
                            dimension: both ? _twoFiguresSize : _oneFigureSize,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: ExcludeSemantics(
                                child: both
                                    ? Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _SyncKeepAwakeRingReadout(
                                            name: _zecName,
                                            progress: zec,
                                            paused: zecPaused,
                                            glow: neon.glow,
                                            core: neon.core,
                                            light: light,
                                          ),
                                          const SizedBox(height: AppSpacing.s),
                                          Container(
                                            width: 36,
                                            height: 1,
                                            color: neon.secondaryGlow
                                                .withValues(alpha: 0.2 * light),
                                          ),
                                          const SizedBox(height: AppSpacing.s),
                                          railgunReadout,
                                        ],
                                      )
                                    : railgunReadout,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: SyncKeepAwakePrivacyLockScreen._ringsLineGap),
        SizedBox(
          width: SyncKeepAwakePrivacyLockScreen._doneBodyWidth,
          child: Text(
            line,
            textAlign: TextAlign.center,
            style: SyncKeepAwakePrivacyLockScreen._ringsLineStyle(context),
          ),
        ),
      ],
    );
  }

  static String _readoutLabel(
    String name,
    double progress, {
    required bool paused,
  }) {
    final percent = '${formatSyncStatusPercentage(progress)}%';
    return paused ? '$name paused at $percent' : '$name $percent';
  }
}

/// One sync at the rings' centre: its name, a HUD caption in its ring's
/// light, over its percentage in Thin numerals lit the same way; [large]
/// when it has the rings to itself, as the wallet's single ring's numerals
/// are. Paused, it dims.
class _SyncKeepAwakeRingReadout extends StatelessWidget {
  const _SyncKeepAwakeRingReadout({
    required this.name,
    required this.progress,
    required this.paused,
    required this.glow,
    required this.core,
    required this.light,
    this.large = false,
  });

  final String name;
  final double progress;
  final bool paused;
  final bool large;
  final Color glow;
  final Color core;
  final double light;

  static const _numeralStyle = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w100,
    fontSize: 40,
    height: 1,
    letterSpacing: -0.4,
  );

  static const _percentSignStyle = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w300,
    fontSize: 16,
    height: 1,
    letterSpacing: 1,
  );

  @override
  Widget build(BuildContext context) {
    final k = paused ? _SyncKeepAwakeRingsLockup._pausedLight * light : light;
    final numeralStyle = large
        ? _SyncKeepAwakeProgressLockup._numeralStyle
        : _numeralStyle;
    final percentSignStyle = large
        ? _SyncKeepAwakeProgressLockup._percentSignStyle
        : _percentSignStyle;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name.toUpperCase(),
          style: kNeonHudCaptionStyle.copyWith(
            color: glow.withValues(alpha: paused ? 0.5 : 1),
            shadows: Neon.textGlow(glow, intensity: 0.5 * k),
          ),
        ),
        SizedBox(height: large ? AppSpacing.s : AppSpacing.xs),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: formatSyncStatusPercentage(progress),
                style: numeralStyle.copyWith(
                  color: core.withValues(alpha: paused ? 0.5 : 1),
                  shadows: Neon.textGlow(glow, intensity: k),
                ),
              ),
              TextSpan(
                text: '%',
                style: percentSignStyle.copyWith(
                  color: glow.withValues(alpha: paused ? 0.5 : 1),
                  shadows: Neon.textGlow(glow, intensity: 0.6 * k),
                ),
              ),
            ],
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// [progress], eased from what it was, as the single ring's numerals are.
class _AnimatedSyncProgress extends StatelessWidget {
  const _AnimatedSyncProgress({
    required this.progress,
    required this.builder,
    super.key,
  });

  final double progress;
  final Widget Function(BuildContext context, double progress) builder;

  @override
  Widget build(BuildContext context) {
    final target = progress.clamp(0.0, 1.0).toDouble();
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: target, end: target),
      duration: _SyncKeepAwakeProgressLockup._progressAnimationDuration,
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => builder(context, value),
    );
  }
}

/// The progress ring: the synced share is a lit tube that runs clockwise
/// from the top to a bright head, and the rest is a scale of unlit ticks
/// that the head burns along.
class _SyncKeepAwakeRingPainter extends CustomPainter {
  const _SyncKeepAwakeRingPainter({
    required this.progress,
    required this.light,
    required this.glow,
    required this.core,
    this.inset = outerInset,
  });

  final double progress;

  /// The sign's light level, 0..1 ([NeonIgnition]).
  final double light;
  final Color glow;
  final Color core;

  /// How far inside the square the ring runs.
  final double inset;

  static const _tickCount = 96;
  static const _tickLength = 7.0;
  static const _tubeWidth = 2.2;

  /// Room around the outer ring for its glow.
  static const outerInset = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress.clamp(0.0, 1.0).toDouble();
    final k = light.clamp(0.0, 1.0).toDouble();
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - inset;
    const start = -math.pi / 2;
    final headAngle = start + math.pi * 2 * p;

    // The unlit scale still ahead of the head, kept clear of its glow.
    final tick = Paint()
      ..color = glow.withValues(alpha: 0.24)
      ..strokeWidth = 1;
    for (var i = (p * _tickCount + 1).ceil(); i < _tickCount; i++) {
      final angle = start + math.pi * 2 * i / _tickCount;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * (radius - _tickLength / 2),
        center + direction * (radius + _tickLength / 2),
        tick,
      );
    }

    if (p > 0) {
      final ring = Rect.fromCircle(center: center, radius: radius);
      Neon.strokeTube(
        canvas,
        p >= 1
            ? (Path()..addOval(ring))
            : (Path()..addArc(ring, start, math.pi * 2 * p)),
        glow: glow,
        core: core,
        width: _tubeWidth,
        intensity: 0.9 * k,
      );
    }

    // The head: a lit bead square to the ring, as the sync line's head.
    if (k <= 0) return;
    final head =
        center + Offset(math.cos(headAngle), math.sin(headAngle)) * radius;
    canvas
      ..save()
      ..translate(head.dx, head.dy)
      ..rotate(headAngle);
    Neon.bead(
      canvas,
      Offset.zero,
      glow: glow,
      core: core,
      size: 7,
      blur: 6,
      rim: 2,
      intensity: k,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SyncKeepAwakeRingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.light != light ||
        oldDelegate.glow != glow ||
        oldDelegate.core != core ||
        oldDelegate.inset != inset;
  }
}

/// A screen switching off as a CRT does: it folds to a bright scanline,
/// the line pulls in to a dot, and the dot goes out.
class _CrtSwitchOff extends StatelessWidget {
  const _CrtSwitchOff({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = animation.value;
        final fold = Curves.easeInCubic.transform(NeonMotion.span(t, 0, 0.5));
        final pull = Curves.easeInCubic.transform(
          NeonMotion.span(t, 0.45, 0.85),
        );
        // One tree throughout, so the screen keeps its state as it folds.
        return Stack(
          fit: StackFit.expand,
          children: [
            Transform.scale(scaleY: math.max(0.004, 1 - fold), child: child),
            if (t > 0)
              CustomPaint(
                painter: _CrtLinePainter(
                  fold: fold,
                  pull: pull,
                  fade: 1 - NeonMotion.span(t, 0.85, 1),
                  glow: neon.glow,
                  core: neon.core,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CrtLinePainter extends CustomPainter {
  const _CrtLinePainter({
    required this.fold,
    required this.pull,
    required this.fade,
    required this.glow,
    required this.core,
  });

  final double fold;
  final double pull;
  final double fade;
  final Color glow;
  final Color core;

  @override
  void paint(Canvas canvas, Size size) {
    if (fold < 0.6) return;
    final center = size.center(Offset.zero);
    final half = size.width / 2 * (1 - pull);
    paintNeonScanline(
      canvas,
      center.dy,
      center.dx - half,
      center.dx + half,
      glow: glow,
      core: core,
      width: 1.8,
      intensity: NeonMotion.span(fold, 0.6, 1) * fade,
    );
  }

  @override
  bool shouldRepaint(_CrtLinePainter oldDelegate) =>
      oldDelegate.fold != fold ||
      oldDelegate.pull != pull ||
      oldDelegate.fade != fade ||
      oldDelegate.glow != glow ||
      oldDelegate.core != core;
}
