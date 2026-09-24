import 'package:flutter/material.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';

// Shared by both viewers - the action list itself differs (wallpaper/
// clipboard only make sense for a still image), everything else about the
// sheet is identical.
void showMediaActionsSheet(
  BuildContext context, {
  required String uri,
  required bool isVideo,
  required NativeController controller,
}) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _MediaActionsSheet(
      uri: uri,
      isVideo: isVideo,
      controller: controller,
      feedbackContext: context,
    ),
  );
}

class _MediaActionsSheet extends StatelessWidget {
  const _MediaActionsSheet({
    required this.uri,
    required this.isVideo,
    required this.controller,
    required this.feedbackContext,
  });

  final String uri;
  final bool isVideo;
  final NativeController controller;
  // The screen behind the sheet, not the sheet's own builder context - the
  // sheet is popped before its action finishes, so its own context is gone
  // by the time there's a result to report.
  final BuildContext feedbackContext;

  void _showFeedback(String message) {
    if (!feedbackContext.mounted) return;
    ScaffoldMessenger.of(feedbackContext).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(
    BuildContext sheetContext,
    Future<bool> Function() action,
    String successMessage,
    String failureMessage,
  ) async {
    Navigator.of(sheetContext).pop();
    final ok = await action();
    _showFeedback(ok ? successMessage : failureMessage);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.canvas,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ActionRow(
                icon: Icons.share_outlined,
                label: 'Share',
                onTap: () {
                  Navigator.of(context).pop();
                  controller.shareFile(uri: uri, isVideo: isVideo);
                },
              ),
              const Divider(height: 1, color: AppColors.dividerSoft),
              _ActionRow(
                icon: Icons.download_outlined,
                label: 'Save a copy',
                onTap: () => _run(
                  context,
                  () => controller.saveFileCopy(uri: uri, isVideo: isVideo),
                  isVideo ? 'Video saved to Gallery' : 'Photo saved to Gallery',
                  "Couldn't save a copy",
                ),
              ),
              if (!isVideo) ...[
                const Divider(height: 1, color: AppColors.dividerSoft),
                _ActionRow(
                  icon: Icons.wallpaper_outlined,
                  label: 'Set as wallpaper',
                  onTap: () => _run(
                    context,
                    () => controller.setPhotoAsWallpaper(uri: uri),
                    'Wallpaper set',
                    "Couldn't set wallpaper",
                  ),
                ),
                const Divider(height: 1, color: AppColors.dividerSoft),
                _ActionRow(
                  icon: Icons.copy_outlined,
                  label: 'Copy to clipboard',
                  onTap: () => _run(
                    context,
                    () => controller.copyImageToClipboard(uri: uri),
                    'Copied',
                    "Couldn't copy",
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.md),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.ink),
            const SizedBox(width: AppSpacing.md),
            Text(label, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
      ),
    );
  }
}
