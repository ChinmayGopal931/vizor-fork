import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/mobile/mobile_home_entry_card.dart';
import '../../models/private_usd_record_key.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_conversion_provider.dart';
import 'private_usd_logo.dart';

/// The banner of a conversion under way, on Home and on `/private-usd`: it
/// stays while a conversion is unfinished, even when Private USD is
/// otherwise unavailable, and opens its progress.
class PrivateUsdConversionBanner extends ConsumerWidget {
  const PrivateUsdConversionBanner({
    required this.accountUuid,
    required this.onOpen,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final String accountUuid;
  final ValueChanged<PrivateUsdRoutePath> onOpen;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banner = ref.watch(privateUsdConversionBannerProvider(accountUuid));
    if (banner == null) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: PrivateUsdConversionBannerView(
        banner: banner,
        onTap: () => onOpen(banner.path),
      ),
    );
  }
}

class PrivateUsdConversionBannerView extends StatelessWidget {
  const PrivateUsdConversionBannerView({
    required this.banner,
    required this.onTap,
    super.key,
  });

  final PrivateUsdBannerState banner;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MobileHomeEntryCard(
      key: const ValueKey('private_usd_conversion_banner'),
      icon: AppIcons.warning,
      // Private USD's logo, unless it asks for attention.
      leading: banner.attention ? null : const PrivateUsdLogo(),
      title: banner.title,
      // Every step still to come needs the seed, so the app must stay open.
      subtitle: PrivateUsdCopy.bannerDetail(banner.detail),
      emphasized: true,
      onTap: onTap,
    );
  }
}
