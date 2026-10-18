import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/onboarding/mobile/mobile_passcode_screen.dart';
import '../../../features/onboarding/mobile/passcode_widgets.dart';
import '../../../features/onboarding/shared/onboarding_welcome_art.dart';
import '../../../providers/app_security_provider.dart';
import '../../../providers/biometric_unlock_provider.dart';
import '../../../providers/sync_display_progress_provider.dart';
import '../../../providers/sync_keep_awake_provider.dart';
import '../../../services/biometric_unlock.dart';
import '../../feedback/app_haptics.dart';
import '../../formatting/sync_status_label.dart';
import '../../layout/app_form_factor.dart';
import '../../layout/mobile/mobile_top_nav.dart';
import '../../theme/app_theme.dart';
import '../app_button.dart';
import '../app_icon.dart';
import '../biometric_icon.dart';
import 'neon_horizon.dart';
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
    extends ConsumerState<SyncKeepAwakePrivacyLockHost> {
  Timer? _idleTimer;
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

    final active = ref.watch(syncKeepAwakeActiveProvider);
    final interaction = ref.watch(syncKeepAwakeInteractionProvider);
    final mode = ref.watch(syncKeepAwakePrivacyLockModeProvider);
    final visible = mode != SyncKeepAwakePrivacyLockMode.hidden;
    _syncIdleTimer(active: active, interaction: interaction, visible: visible);

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (visible)
          Positioned.fill(child: SyncKeepAwakePrivacyLockScreen(mode: mode)),
      ],
    );
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    _idleTimer?.cancel();
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
    if (!ref.read(syncKeepAwakeActiveProvider)) return;
    if (ref.read(syncKeepAwakePrivacyLockProvider).isLocked) return;

    final interaction = ref.read(syncKeepAwakeInteractionProvider);
    if (interaction.revision != expectedRevision) {
      _syncIdleTimer(active: true, interaction: interaction, visible: false);
      return;
    }

    // The privacy overlay does not replace the underlying route. Dismiss its
    // input connection and native keyboard controls before covering the content.
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(syncKeepAwakePrivacyLockProvider.notifier).lock();
  }

  void _clearAfterFrameIfInactive() {
    if (_clearScheduled ||
        !ref.read(syncKeepAwakePrivacyLockProvider).isLocked) {
      return;
    }
    _clearScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _clearScheduled = false;
      if (!mounted || ref.read(syncKeepAwakeActiveProvider)) return;
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
    final main = switch (mode) {
      SyncKeepAwakePrivacyLockMode.done => const _SyncKeepAwakeStatusLockup(
        glyph: TronGlyphKind.check,
        glyphKey: ValueKey('sync_keep_awake_privacy_done_check'),
        title: 'Sync complete',
        body: 'Unlock Veylor to continue',
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
        const _SyncKeepAwakeDisplayProgressLockup(),
    };
    final semanticsLabel = switch (mode) {
      SyncKeepAwakePrivacyLockMode.done => 'Veylor is synced',
      SyncKeepAwakePrivacyLockMode.interrupted => 'Veylor sync is paused',
      SyncKeepAwakePrivacyLockMode.hidden ||
      SyncKeepAwakePrivacyLockMode.syncing => 'Veylor is syncing',
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
                  AppButton(
                    key: const ValueKey(
                      'sync_keep_awake_privacy_unlock_button',
                    ),
                    onPressed: onUnlockPressed,
                    leading: _SyncKeepAwakeUnlockIcon(biometric: biometric),
                    minWidth: 165,
                    child: const Text('Unlock Veylor'),
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
  }) {
    final spec = _SyncKeepAwakeLayoutSpec.forMode(mode);
    if (screenHeight >= SyncKeepAwakePrivacyLockScreen._figmaReferenceHeight) {
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

  factory _SyncKeepAwakeLayoutSpec.forMode(SyncKeepAwakePrivacyLockMode mode) {
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
              // The nav's own page title: spaced uppercase Thin.
              Consumer(
                builder: (context, ref, _) => MobileTopNav.back(
                  title: _titleForMode(
                    mode == SyncKeepAwakePrivacyLockMode.syncing ||
                            mode == SyncKeepAwakePrivacyLockMode.hidden
                        ? ref.watch(syncDisplayWholePercentageProvider)
                        : 0,
                  ),
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

                    return Padding(
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

  String _titleForMode(int displayWholePercentage) {
    return switch (mode) {
      SyncKeepAwakePrivacyLockMode.done => 'Synced',
      SyncKeepAwakePrivacyLockMode.interrupted => 'Sync paused',
      SyncKeepAwakePrivacyLockMode.hidden ||
      SyncKeepAwakePrivacyLockMode.syncing =>
        '$displayWholePercentage% Syncing...',
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

/// A title on the privacy screen, drawn as a neon page title. The string
/// stays sentence case: it is upper-cased where drawn, and screen readers
/// get it as written.
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
  });

  final TronGlyphKind glyph;
  final Key glyphKey;
  final String title;
  final String body;

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
              child: NeonGlyphBadge(
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
    fontFamily: 'Gotham',
    fontWeight: FontWeight.w100,
    fontSize: 56,
    height: 1,
    letterSpacing: -0.5,
  );

  /// The percent sign, set beside them as the sign's ticker is.
  static const _percentSignStyle = TextStyle(
    fontFamily: 'Gotham',
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
                          'Veylor is syncing',
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

/// The progress ring in the neon look: the synced share is a lit tube that
/// runs clockwise from the top to a bright head, and the rest is a scale of
/// unlit ticks that the head burns along.
class _SyncKeepAwakeRingPainter extends CustomPainter {
  const _SyncKeepAwakeRingPainter({
    required this.progress,
    required this.light,
    required this.glow,
    required this.core,
  });

  final double progress;

  /// The sign's light level, 0..1 ([NeonIgnition]).
  final double light;
  final Color glow;
  final Color core;

  static const _tickCount = 96;
  static const _tickLength = 7.0;
  static const _tubeWidth = 2.2;

  /// Room around the ring for its glow.
  static const _inset = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress.clamp(0.0, 1.0).toDouble();
    final k = light.clamp(0.0, 1.0).toDouble();
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - _inset;
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
    final bead = Rect.fromCenter(center: Offset.zero, width: 7, height: 7);
    canvas
      ..save()
      ..translate(head.dx, head.dy)
      ..rotate(headAngle)
      ..drawRect(
        bead.inflate(5),
        Paint()
          ..color = glow.withValues(alpha: 0.6 * k)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      )
      ..drawRect(bead, Paint()..color = glow.withValues(alpha: k))
      ..drawRect(bead.deflate(2), Paint()..color = core.withValues(alpha: k))
      ..restore();
  }

  @override
  bool shouldRepaint(covariant _SyncKeepAwakeRingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.light != light ||
        oldDelegate.glow != glow ||
        oldDelegate.core != core;
  }
}
