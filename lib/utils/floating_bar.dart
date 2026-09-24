import 'package:flutter/widgets.dart';
import 'package:twentyonevision/utils/app_spacing.dart';

/// Height of the floating navigation pill (and the round search button).
const double kFloatingBarHeight = 58;

/// Gap between the pill and the bottom of the screen (above the system
/// navigation area).
const double kFloatingBarBottomGap = 20;

/// The home screen's navigation bar floats over its content, so each tab's
/// scrollable ends with this much empty space - the last item can scroll up
/// clear of the bar instead of being stuck underneath it. Just a small
/// margin while the keyboard is up, since the bar is hidden then.
double floatingBarClearance(BuildContext context) {
  final media = MediaQuery.of(context);
  if (media.viewInsets.bottom > 0) return AppSpacing.base;
  return media.padding.bottom + kFloatingBarHeight + kFloatingBarBottomGap + AppSpacing.base;
}
