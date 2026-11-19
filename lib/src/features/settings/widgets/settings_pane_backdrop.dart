import 'package:flutter/widgets.dart';

/// Artwork variants for the etched full-window settings backdrop.
enum SettingsBackdropArt {
  castle('assets/illustrations/desktop/settings_backdrop_castle.webp');

  const SettingsBackdropArt(this.assetPath);

  final String assetPath;
}

/// The full-window backdrop behind settings sub-screens.
///
/// Upstream etches [art] there. Veylor's neon look paints no backgrounds, so
/// it draws nothing and the window's black shows behind the glass sidebar
/// and the pane. Mount it as the `background` of an `AppDesktopBackdropShell`
/// (or any full-window Stack), as upstream does.
class SettingsPaneBackdrop extends StatelessWidget {
  const SettingsPaneBackdrop({required this.art, super.key});

  final SettingsBackdropArt art;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
