import 'package:flutter/material.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';

// Shared by the image and video metadata sheets - same grouped-card grammar
// as Settings: a pearl-toned card, dividerSoft between rows, an uppercase
// muted caption above each group.
class InfoGroupLabel extends StatelessWidget {
  const InfoGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: AppColors.ink48, letterSpacing: 0.5),
    );
  }
}

class InfoGroupCard extends StatelessWidget {
  const InfoGroupCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: ColoredBox(
        color: AppColors.pearl,
        child: Column(
          children: [
            for (int i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: AppColors.dividerSoft),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const InfoRow({super.key, required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                ),
                const SizedBox(height: 1),
                Text(value, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
