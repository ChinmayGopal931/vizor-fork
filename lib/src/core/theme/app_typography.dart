/// Typography tokens from the Figma design system.
///
/// The Figma `Fonts` variable collection has a Desktop and a Mobile mode
/// (`3 Fonts-3.zip`). Both modes are materialized as complete const
/// token sets — [AppTypographyDesktop] and [AppTypographyMobile] — and
/// [AppTypography] selects between them at **compile time** via
/// [kAppFormFactor], so call sites keep the familiar
/// `AppTypography.bodyMedium` shape, stay const, and the unused set is
/// tree-shaken out of release builds. Reference a mode set directly only
/// in tooling (widgetbook galleries, token tests) that must show both
/// modes inside one binary.
///
/// **Every style renders in Gotham**, the app's only family (registered by
/// `loadGothamFonts`, see `gotham_fonts.dart`). The Figma `Fonts` collection
/// still names Geist, Geist Mono and Young Serif; the "Figma ..." comments
/// below keep those names because they describe the Figma tokens, not the
/// face that is drawn. Sizes, line heights and letter spacings keep the Figma
/// values unless a comment says otherwise. Gotham is wider than Geist, has no
/// SemiBold (`w600` resolves to Bold) and no monospace companion, so the
/// `code*` styles are proportional.
///
/// Desktop serif styles enable the OpenType 'case' feature and mobile serif
/// styles pin lining figures. That served Young Serif, whose default figures
/// are old-style; Gotham's figures are lining and it has neither feature, so
/// both are inert. They stay so the tokens still compare 1:1 with Figma.
///
/// Naming maps Figma → Dart by full word and camelCase where possible:
/// `Headline L` → `headlineLarge`, `Body L` → `bodyLarge`,
/// `Label S` → `labelSmall`, `Code M` → `codeMedium`. The one outlier is
/// `Body M Medium`, the emphasis variant of the regular body — surfaced
/// as [AppTypography.bodyMediumStrong]. The old `display*` constants are
/// legacy aliases onto the headline scale (`displayLarge` /
/// `displayMedium` → `Headline XL`, `displaySmall` → `Headline L`).
///
/// Font sizes and letter spacings are authored in logical pixels. The
/// sans families and letter spacings are identical across modes; the
/// serif display scale differs by size between modes. Line heights are
/// stored as the unitless multiplier Flutter expects (`TextStyle.height`)
/// — computed as `figmaLineHeightPx / fontSizePx` so the original Figma
/// design still reproduces exactly.
///
/// Colors are not baked into these styles. Callers merge colors in at
/// the call site (usually through `DefaultTextStyle.merge` or
/// `style.copyWith(color: context.colors.text.primary)`). This keeps
/// the token a pure typographic concern and lets it work with whichever
/// semantic text color the caller needs.
library;

import 'package:flutter/widgets.dart';

import '../layout/app_form_factor.dart';
import 'gotham_fonts.dart' show kGothamFamily;

export 'gotham_fonts.dart' show kGothamFamily;

// ─── Mode-invariant styles (identical in both Figma modes) ───────────

/// Desktop Young Serif styles use the `case` feature for lining digits.
const _youngSerifCaseFigures = [FontFeature.enable('case')];

/// Young Serif's default numerals are old-style figures (6/8 ascend,
/// 3/4/5/7/9 descend below the baseline); the mobile frames render every
/// serif number — balance, send amount, numpad — with uniform lining
/// figures, so the Young Serif tokens pin the font's `lnum` feature.
const _youngSerifFigures = [FontFeature.liningFigures()];

/// Figma desktop `Headline L` — Young Serif, 32 / 33 px.
///
/// The original `Desktop.tokens.json` export predated the design system's
/// serif migration and still said Libre Caslon; the live desktop screen
/// frames use Young Serif.
const _headlineLDesktop = TextStyle(
  fontFamily: kGothamFamily,
  fontWeight: FontWeight.w400,
  fontSize: 32,
  height: 33 / 32,
  letterSpacing: 0,
  fontFeatures: _youngSerifCaseFigures,
);

/// Figma desktop `Headline M` — Young Serif, 28 / 30 px, −0.28.
const _headlineMDesktop = TextStyle(
  fontFamily: kGothamFamily,
  fontWeight: FontWeight.w400,
  fontSize: 28,
  height: 30 / 28,
  letterSpacing: -0.28,
  fontFeatures: _youngSerifCaseFigures,
);

/// Figma mobile app `Headline L` — Young Serif, 32 / 33 px.
///
/// The current `3 Fonts-3.zip` variable export lists Libre Caslon Text for
/// this slot, but the actual mobile screen frames still render the display
/// headline scale with Young Serif. Keep the app token aligned with the
/// screen frames until the design file and variable export agree.
///
/// **Deviation from Figma: 28 px, not 32.** Gotham sets wider than Young
/// Serif and its x-height is 17% larger (0.517 em against 0.440 em), so
/// 28 px keeps Young Serif's x-height (14.5 px against 14.1 px). The 33 px
/// line box is unchanged, so vertical rhythm holds. Desktop keeps 32 px.
const _headlineLMobile = TextStyle(
  fontFamily: kGothamFamily,
  fontWeight: FontWeight.w100,
  fontSize: 28,
  height: 33 / 28,
  letterSpacing: 0,
  fontFeatures: _youngSerifFigures,
);

/// Figma mobile app `Headline M` — Young Serif, 28 / 30 px, −0.28.
///
/// **Deviation from Figma: 24 px, tracking −0.24.** Scaled with
/// [_headlineLMobile] for the same reason, so Headline M stays one step below
/// Headline L (28 / 24 px, as 32 / 28 px was). The 30 px line box is unchanged.
const _headlineMMobile = TextStyle(
  fontFamily: kGothamFamily,
  fontWeight: FontWeight.w100,
  fontSize: 24,
  height: 30 / 24,
  letterSpacing: -0.24,
  fontFeatures: _youngSerifFigures,
);

/// Figma `Code M` — Geist Mono Medium, 14 / 21 px.
const _codeMDesktop = TextStyle(
  fontFamily: kGothamFamily,
  fontWeight: FontWeight.w500,
  fontSize: 14,
  height: 21 / 14,
  letterSpacing: 0,
);

/// Figma `Code M`, Mobile mode — Geist Mono Medium, 16 / 21 px, set in
/// Light like the rest of the mobile type.
const _codeMMobile = TextStyle(
  fontFamily: kGothamFamily,
  fontWeight: FontWeight.w300,
  fontSize: 16,
  height: 21 / 16,
  letterSpacing: 0,
);

/// Figma `Code S` — Geist Mono Medium, 13 / 17 px.
const _codeS = TextStyle(
  fontFamily: kGothamFamily,
  fontWeight: FontWeight.w500,
  fontSize: 13,
  height: 17 / 13,
  letterSpacing: 0,
);

/// Figma `Code S`, Mobile mode — the [_codeS] metrics in Light.
const _codeSMobile = TextStyle(
  fontFamily: kGothamFamily,
  fontWeight: FontWeight.w300,
  fontSize: 13,
  height: 17 / 13,
  letterSpacing: 0,
);

/// The Desktop mode of the Figma `Fonts` collection.
abstract final class AppTypographyDesktop {
  /// Figma `Headline XL` — 45 / 48 px, letter-spacing −1.35.
  static const displayLarge = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w400,
    fontFeatures: _youngSerifCaseFigures,
    fontSize: 45,
    height: 48 / 45,
    letterSpacing: -1.35,
  );

  static const displayMedium = displayLarge;
  static const displaySmall = _headlineLDesktop;
  static const headlineLarge = _headlineLDesktop;
  static const headlineMedium = _headlineMDesktop;

  /// Figma `Headline S` — Geist Medium, 16 / 20 px.
  static const headlineSmall = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w500,
    fontSize: 16,
    height: 20 / 16,
    letterSpacing: 0,
  );

  /// Figma `Body L` — Geist Medium, 16 / 24 px, −0.24.
  static const bodyLarge = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w500,
    fontSize: 16,
    height: 24 / 16,
    letterSpacing: -0.24,
  );

  /// Figma `Body M` — Geist Regular, 14 / 21 px, −0.21.
  static const bodyMedium = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w400,
    fontSize: 14,
    height: 21 / 14,
    letterSpacing: -0.21,
  );

  /// Figma `Body M Medium` — Geist Medium, 14 / 21 px, −0.21.
  static const bodyMediumStrong = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w500,
    fontSize: 14,
    height: 21 / 14,
    letterSpacing: -0.21,
  );

  /// Figma `Body S` — Geist Regular, 12 / 18 px, −0.12.
  static const bodySmall = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w400,
    fontSize: 12,
    height: 18 / 12,
    letterSpacing: -0.12,
  );

  /// Figma `Body XS` — Geist Regular, 11 / 16 px, −0.055.
  static const bodyExtraSmall = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w400,
    fontSize: 11,
    height: 16 / 11,
    letterSpacing: -0.055,
  );

  /// Figma `Label M` — Geist Medium, 14 / 16 px, −0.06.
  static const labelLarge = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w500,
    fontSize: 14,
    height: 16 / 14,
    letterSpacing: -0.06,
  );

  /// Figma `Label S` — Geist Medium, 13 / 14 px.
  static const labelMedium = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w500,
    fontSize: 13,
    height: 14 / 13,
    letterSpacing: 0,
  );

  static const labelSmall = labelMedium;
  static const codeMedium = _codeMDesktop;
  static const codeSmall = _codeS;
}

/// The Mobile mode of the Figma `Fonts` collection.
///
/// Body, label, and code metrics follow the current mobile variable
/// export. The display headline scale intentionally follows the actual
/// mobile screen frames, which still use Young Serif.
abstract final class AppTypographyMobile {
  // The mobile weights are lighter than Figma's: Thin (100) for headlines
  // and display numerals, Light (300) for everything else. No mobile style
  // is Book (400) or heavier; emphasis comes from colour and size, not
  // weight.

  /// Figma mobile app `Headline XL` — Young Serif, 40 / 40 px, −1.35.
  static const displayLarge = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w100,
    fontSize: 40,
    height: 40 / 40,
    letterSpacing: -1.35,
    fontFeatures: _youngSerifFigures,
  );

  static const displayMedium = displayLarge;
  static const displaySmall = _headlineLMobile;
  static const headlineLarge = _headlineLMobile;
  static const headlineMedium = _headlineMMobile;

  /// Figma `Headline S` — Geist Medium, 18 / 22 px.
  static const headlineSmall = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w300,
    fontSize: 18,
    height: 22 / 18,
    letterSpacing: 0,
  );

  /// Figma `Body L` — Geist Medium, 18 / 26 px, −0.24.
  static const bodyLarge = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w300,
    fontSize: 18,
    height: 26 / 18,
    letterSpacing: -0.24,
  );

  /// Figma `Body M` — Geist Regular, 16 / 25 px, −0.21.
  static const bodyMedium = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w300,
    fontSize: 16,
    height: 25 / 16,
    letterSpacing: -0.21,
  );

  /// Figma `Body M Medium` — Geist Medium, 16 / 25 px, −0.21. Light like
  /// [bodyMedium]: the mobile type has no heavier weight to emphasise with.
  static const bodyMediumStrong = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w300,
    fontSize: 16,
    height: 25 / 16,
    letterSpacing: -0.21,
  );

  /// Figma `Body S` — Geist Regular, 14 / 20 px, −0.12.
  static const bodySmall = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w300,
    fontSize: 14,
    height: 20 / 14,
    letterSpacing: -0.12,
  );

  /// Figma `Body XS` — Geist Regular, 13 / 18 px, −0.055.
  static const bodyExtraSmall = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w300,
    fontSize: 13,
    height: 18 / 13,
    letterSpacing: -0.055,
  );

  /// Figma `Label M` — Geist Medium, 16 / 17 px, −0.06.
  static const labelLarge = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w300,
    fontSize: 16,
    height: 17 / 16,
    letterSpacing: -0.06,
  );

  /// Figma `Label S` — Geist Medium, 14 / 15 px.
  static const labelMedium = TextStyle(
    fontFamily: kGothamFamily,
    fontWeight: FontWeight.w300,
    fontSize: 14,
    height: 15 / 14,
    letterSpacing: 0,
  );

  static const labelSmall = labelMedium;
  static const codeMedium = _codeMMobile;
  static const codeSmall = _codeSMobile;
}

const _mobile = kAppFormFactor == AppFormFactor.mobile;

/// The typography tokens for the form factor this binary was built for.
///
/// See the library doc above for the selection mechanism and
/// [AppTypographyDesktop] / [AppTypographyMobile] for per-style Figma
/// metrics.
abstract final class AppTypography {
  // ─── Display (legacy aliases onto the headline scale) ─────────────

  /// Largest onboarding/welcome headline (Figma `Headline XL`).
  static const displayLarge = _mobile
      ? AppTypographyMobile.displayLarge
      : AppTypographyDesktop.displayLarge;

  /// Hero headlines (Figma `Headline XL`).
  static const displayMedium = displayLarge;

  /// Step-level headlines inside onboarding flows (Figma `Headline L`).
  static const displaySmall = _mobile
      ? AppTypographyMobile.displaySmall
      : AppTypographyDesktop.displaySmall;

  // ─── Headline ─────────────────────────────────────────────────────

  /// Section headings inside content panes (Figma `Headline L`).
  static const headlineLarge = _mobile
      ? AppTypographyMobile.headlineLarge
      : AppTypographyDesktop.headlineLarge;

  /// Sub-section headings (Figma `Headline M`).
  static const headlineMedium = _mobile
      ? AppTypographyMobile.headlineMedium
      : AppTypographyDesktop.headlineMedium;

  /// Card titles, group labels (Figma `Headline S`).
  static const headlineSmall = _mobile
      ? AppTypographyMobile.headlineSmall
      : AppTypographyDesktop.headlineSmall;

  // ─── Body ─────────────────────────────────────────────────────────

  /// Comfortable paragraph copy, intro descriptions (Figma `Body L`).
  static const bodyLarge = _mobile
      ? AppTypographyMobile.bodyLarge
      : AppTypographyDesktop.bodyLarge;

  /// Default paragraph and subtitle copy (Figma `Body M`).
  static const bodyMedium = _mobile
      ? AppTypographyMobile.bodyMedium
      : AppTypographyDesktop.bodyMedium;

  /// Emphasis variant of [bodyMedium]; same metrics, medium weight. Use
  /// for inline emphasis where italic / bold would over-shout (Figma
  /// `Body M Medium`).
  static const bodyMediumStrong = _mobile
      ? AppTypographyMobile.bodyMediumStrong
      : AppTypographyDesktop.bodyMediumStrong;

  /// Fine print, legal footers, metadata (Figma `Body S`).
  static const bodySmall = _mobile
      ? AppTypographyMobile.bodySmall
      : AppTypographyDesktop.bodySmall;

  /// Smallest readable copy: footnotes, dense table cells, chip text
  /// (Figma `Body XS`).
  static const bodyExtraSmall = _mobile
      ? AppTypographyMobile.bodyExtraSmall
      : AppTypographyDesktop.bodyExtraSmall;

  // ─── Label ────────────────────────────────────────────────────────

  /// Button labels and nav item text (Figma `Label M`).
  static const labelLarge = _mobile
      ? AppTypographyMobile.labelLarge
      : AppTypographyDesktop.labelLarge;

  /// Compact label copy (Figma `Label S`).
  static const labelMedium = _mobile
      ? AppTypographyMobile.labelMedium
      : AppTypographyDesktop.labelMedium;

  /// Micro-copy: tag pills, status badges, dense controls (Figma
  /// `Label S`).
  static const labelSmall = labelMedium;

  // ─── Code ─────────────────────────────────────────────────────────
  // Figma specifies Geist Mono here; the app has no monospace face, so these
  // render in Gotham and glyph widths vary. Use for addresses, transaction
  // IDs, mnemonics and hex dumps, but never rely on columns lining up.

  /// Primary monospace copy (Figma `Code M`).
  static const codeMedium = _mobile
      ? AppTypographyMobile.codeMedium
      : AppTypographyDesktop.codeMedium;

  /// Secondary monospace copy: mnemonic word indices, compact numeric
  /// metadata (Figma `Code S`).
  static const codeSmall = _mobile
      ? AppTypographyMobile.codeSmall
      : AppTypographyDesktop.codeSmall;
}

/// The Desktop weights: the Figma weight each [AppFontWeight] names.
abstract final class AppFontWeightDesktop {
  static const regular = FontWeight.w400;
  static const medium = FontWeight.w500;

  /// Drawn as Gotham Bold: Gotham has no SemiBold.
  static const semiBold = FontWeight.w600;
  static const bold = FontWeight.w700;

  /// Drawn as Gotham Black.
  static const extraBold = FontWeight.w800;

  /// Medium: the Figma weight of the Body L and Headline S tokens that
  /// sheet titles and a state's statement are set in.
  static const heading = FontWeight.w500;
}

/// The Mobile weights: nothing heavier than Light, so every emphasis weight
/// is Light, and headings are Thin.
abstract final class AppFontWeightMobile {
  static const regular = FontWeight.w300;
  static const medium = FontWeight.w300;
  static const semiBold = FontWeight.w300;
  static const bold = FontWeight.w300;
  static const extraBold = FontWeight.w300;
  static const heading = FontWeight.w100;
}

/// Weights for one-off overrides of a token's weight, as in
/// `AppTypography.bodyMedium.copyWith(fontWeight: AppFontWeight.medium)`,
/// for the form factor this binary was built for.
///
/// The emphasis weights keep the Figma weight they name on desktop and are
/// Light on mobile, so mobile-only code needs none of them. [heading] is the
/// one mobile code uses: it sets a sheet title or a state's statement in
/// Thin, as the screen titles are, over a token that is Light on mobile.
abstract final class AppFontWeight {
  /// Regular (`w400`) on desktop.
  static const regular = _mobile
      ? AppFontWeightMobile.regular
      : AppFontWeightDesktop.regular;

  /// Medium (`w500`) on desktop.
  static const medium = _mobile
      ? AppFontWeightMobile.medium
      : AppFontWeightDesktop.medium;

  /// SemiBold (`w600`) on desktop.
  static const semiBold = _mobile
      ? AppFontWeightMobile.semiBold
      : AppFontWeightDesktop.semiBold;

  /// Bold (`w700`) on desktop.
  static const bold = _mobile
      ? AppFontWeightMobile.bold
      : AppFontWeightDesktop.bold;

  /// ExtraBold (`w800`) on desktop.
  static const extraBold = _mobile
      ? AppFontWeightMobile.extraBold
      : AppFontWeightDesktop.extraBold;

  /// A heading's weight: Thin (`w100`) on mobile, Medium (`w500`) on desktop.
  static const heading = _mobile
      ? AppFontWeightMobile.heading
      : AppFontWeightDesktop.heading;
}
