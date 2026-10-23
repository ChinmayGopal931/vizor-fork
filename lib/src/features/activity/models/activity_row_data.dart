import 'package:flutter/widgets.dart';

class ActivityRowData {
  const ActivityRowData({
    this.stableId,
    required this.title,
    required this.leadingIconName,
    required this.leadingBackgroundColor,
    required this.leadingIconColor,
    this.leading,
    this.leadingProgressValue,
    this.subtitle,
    this.subtitleIconName,
    required this.amountText,
    this.amountIconName,
    this.amountIconColor,
    this.amountColor,
    this.amountSubtitle,
    this.amountSubtitleIconName,
    this.amountSubtitleIconColor,
    required this.statusText,
    required this.timestampText,
    this.statusIconName,
    this.statusColor,
    this.backgroundColor,
    this.selected = false,
    this.childRows = const [],
    this.details,
    this.onTap,
  });

  final String? stableId;
  final String title;
  final String leadingIconName;
  final Color leadingBackgroundColor;
  final Color leadingIconColor;

  /// An image drawn in place of the leading icon and its plate, at the
  /// avatar's size: an asset's logo (Private USD's).
  final Widget? leading;
  final double? leadingProgressValue;
  final String? subtitle;
  final String? subtitleIconName;
  final String amountText;
  final String? amountIconName;
  final Color? amountIconColor;
  final Color? amountColor;
  final String? amountSubtitle;
  final String? amountSubtitleIconName;
  final Color? amountSubtitleIconColor;
  final String statusText;
  final String timestampText;
  final String? statusIconName;
  final Color? statusColor;
  final Color? backgroundColor;
  final bool selected;
  final List<ActivityRowData> childRows;

  /// Drawn under the row and its [childRows]: what a row that unfolds in
  /// place shows once [onTap] opens it (a Private USD row's details).
  final Widget? details;
  final VoidCallback? onTap;
}
