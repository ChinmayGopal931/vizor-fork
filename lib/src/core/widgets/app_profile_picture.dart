import 'package:flutter/widgets.dart';

import '../layout/app_form_factor.dart';
import '../profile_pictures.dart';
import '../theme/app_theme.dart';

const _mobile = kAppFormFactor == AppFormFactor.mobile;

enum AppProfilePictureSize {
  medium(24),
  large(32),
  navLarge(40),
  xLarge(56),
  xxLarge(72);

  const AppProfilePictureSize(this.dimension);

  final double dimension;

  double get radius => dimension / 2;
}

class AppProfilePicture extends StatelessWidget {
  const AppProfilePicture({
    super.key,
    required this.profilePictureId,
    this.size = AppProfilePictureSize.medium,
  });

  final String profilePictureId;
  final AppProfilePictureSize size;

  @override
  Widget build(BuildContext context) {
    final option = resolveProfilePictureOption(profilePictureId);
    final image = Image.asset(
      option.assetPath,
      width: size.dimension,
      height: size.dimension,
      fit: BoxFit.cover,
    );

    if (_mobile) {
      // Mobile frames a portrait as a cut-corner plate with a lit red edge,
      // not a circle.
      final cut = size.dimension * 0.24;
      final colors = context.colors;
      return SizedBox(
        width: size.dimension,
        height: size.dimension,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: ShapeDecoration(
            shape: Neon.chamferBorder(
              cut: cut,
              side: BorderSide(
                color: colors.border.brandCrimsonStrong.withValues(alpha: 0.8),
              ),
            ),
          ),
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: Neon.chamferBorder(cut: cut)),
            child: ColoredBox(color: colors.background.raised, child: image),
          ),
        ),
      );
    }

    return SizedBox(
      width: size.dimension,
      height: size.dimension,
      child: ClipOval(child: image),
    );
  }
}
