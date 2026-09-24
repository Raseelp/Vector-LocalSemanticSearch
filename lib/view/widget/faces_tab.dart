import 'package:flutter/material.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/utils/floating_bar.dart';

// Placeholder until face grouping exists - the tab is here now so the
// navigation is final, and the screen says what's coming instead of being
// blank.
class FacesTab extends StatelessWidget {
  const FacesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        // Bottom clearance keeps the centred message clear of the floating bar.
        padding: EdgeInsets.fromLTRB(AppSpacing.xxl, 0, AppSpacing.xxl, floatingBarClearance(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.parchment,
                borderRadius: BorderRadius.circular(AppRadius.xl),
              ),
              child: const Icon(
                Icons.face_retouching_natural,
                color: AppColors.primary,
                size: 34,
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            Text('Faces', style: textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Coming soon. Vector will group your photos by the people in them - '
              'all on this device, nothing uploaded.',
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
