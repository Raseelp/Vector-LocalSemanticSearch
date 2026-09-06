import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/model_status.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';

class ModelDownloadScreen extends StatelessWidget {
  const ModelDownloadScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<NativeController>(
      builder: (controller) {
        final totalBytes = controller.modelStatuses.isEmpty
            ? null
            : controller.modelStatuses.fold<int>(
                0,
                (sum, m) => sum + m.sizeBytes,
              );

        return Scaffold(
          backgroundColor: AppColors.canvas,
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _HeaderIcon(isDownloading: controller.isDownloadingModels),
                      const SizedBox(height: AppSpacing.xl),
                      Text(
                        'One-time setup',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Vector needs its on-device AI models before it can '
                        'search your photos and videos. This happens once - '
                        'everything after this runs fully offline, and your '
                        'media never leaves this device.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.ink48,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      _DownloadCard(controller: controller, totalBytes: totalBytes),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({required this.isDownloading});

  final bool isDownloading;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: Icon(
        isDownloading ? Icons.downloading_rounded : Icons.auto_awesome_rounded,
        color: AppColors.primary,
        size: 32,
      ),
    );
  }
}

class _DownloadCard extends StatelessWidget {
  const _DownloadCard({required this.controller, required this.totalBytes});

  final NativeController controller;
  final int? totalBytes;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.isDownloadingModels) ...[
            _ProgressSection(progress: controller.downloadProgress),
          ] else ...[
            Row(
              children: [
                const Icon(Icons.sd_storage_outlined, color: AppColors.ink48, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    totalBytes != null
                        ? 'Download size: ${ModelDownloadProgress.formatBytes(totalBytes!)}'
                        : 'Preparing download info...',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'A stable connection is recommended - the download can '
              'resume if interrupted.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.ink48,
                height: 1.4,
              ),
            ),
          ],
          if (controller.downloadError.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.base),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, color: AppColors.danger, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    controller.downloadError,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.danger,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          _ActionRow(controller: controller),
        ],
      ),
    );
  }
}

class _ProgressSection extends StatelessWidget {
  const _ProgressSection({required this.progress});

  final ModelDownloadProgress progress;

  @override
  Widget build(BuildContext context) {
    final percent = (progress.overallFraction * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Downloading models...', style: Theme.of(context).textTheme.titleSmall),
            ),
            Text(
              '$percent%',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: AppColors.primary),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: LinearProgressIndicator(
            minHeight: 6,
            value: progress.overallTotalBytes == 0 ? null : progress.overallFraction,
            backgroundColor: AppColors.hairline,
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          progress.overallTotalBytes == 0
              ? 'Starting...'
              : '${ModelDownloadProgress.formatBytes(progress.overallBytesDownloaded)} '
                    'of ${ModelDownloadProgress.formatBytes(progress.overallTotalBytes)}'
                    '${progress.modelFileName.isNotEmpty ? ' - ${progress.modelFileName}' : ''}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.isDownloadingModels) {
      return _PillButton(
        label: 'Cancel',
        onTap: controller.cancelModelDownload,
        outlined: true,
      );
    }

    final hasError = controller.downloadError.isNotEmpty;
    return _PillButton(
      label: hasError ? 'Retry download' : 'Download models',
      icon: hasError ? Icons.refresh_rounded : Icons.download_rounded,
      onTap: controller.startModelDownload,
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.onTap,
    this.icon,
    this.outlined = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final foreground = outlined ? AppColors.ink : AppColors.onPrimary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: outlined ? Colors.transparent : AppColors.primary,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: outlined ? Border.all(color: AppColors.hairline) : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, color: foreground, size: 18),
                const SizedBox(width: AppSpacing.sm),
              ],
              Text(
                label,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
