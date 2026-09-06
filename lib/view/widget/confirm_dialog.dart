import 'package:flutter/material.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';

/// A centered confirm dialog for irreversible actions - no shadow, a
/// hairline divider above the button row, canvas background. Used instead
/// of the platform AlertDialog chrome so every confirm in the app looks
/// the same.
Future<void> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required VoidCallback onConfirm,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.canvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxxl),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xl,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Column(
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      ctx,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.ink80, height: 1.4),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.hairline),
            IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(
                    child: _DialogButton(
                      label: 'Cancel',
                      color: AppColors.primary,
                      onTap: () => Navigator.of(ctx).pop(false),
                    ),
                  ),
                  const VerticalDivider(width: 1, color: AppColors.hairline),
                  Expanded(
                    child: _DialogButton(
                      label: confirmLabel,
                      color: AppColors.danger,
                      onTap: () => Navigator.of(ctx).pop(true),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  if (confirmed == true) onConfirm();
}

class _DialogButton extends StatelessWidget {
  const _DialogButton({required this.label, required this.color, required this.onTap});

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}
