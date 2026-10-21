import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/account_provider.dart';
import '../../profile_pictures.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_profile_picture.dart';
import '../../widgets/mobile/mobile_account_avatar.dart';
import 'mobile_top_nav.dart';

/// [MobileTopNav.account] bound to live state: the active account's
/// name and profile picture from [accountProvider]. It shows no sync
/// status; Home's sync line (`NeonSyncBackdrop`) carries it.
class MobileTopNavAccount extends ConsumerWidget {
  const MobileTopNavAccount({
    this.onAccountTap,
    this.compact = false,
    super.key,
  });

  final VoidCallback? onAccountTap;

  /// A smaller portrait in a shorter bar, tucked into the corner (Home).
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final account = ref.watch(accountProvider).value?.activeAccount;
    return MobileTopNav.account(
      accountName: account?.name ?? '',
      height: compact ? 40 : kMobileTopNavHeight,
      avatar: MobileAccountAvatar(
        profilePictureId: account?.profilePictureId ?? kDefaultProfilePictureId,
        size: compact
            ? AppProfilePictureSize.large
            : AppProfilePictureSize.navLarge,
        hardwareSignerKind: account?.hardwareSignerKind,
        badgeRingColor: colors.background.window,
      ),
      onAccountTap: onAccountTap,
    );
  }
}
