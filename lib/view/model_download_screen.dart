import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/model_status.dart';
import 'package:twentyonevision/utils/app_colors.dart';

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
          backgroundColor: AppColors.backGroundColor,
          body: DecoratedBox(
            decoration: const BoxDecoration(gradient: AppColors.screenGradient),
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _HeaderIcon(isDownloading: controller.isDownloadingModels),
                        const SizedBox(height: 24),
                        Text(
                          'One-time setup',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Vector needs its on-device AI models '
                          'before it can search your photos and videos. '
                          'This happens once — everything after this runs '
                          'fully offline, and your media never leaves this '
                          'device.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: AppColors.textSecondary,
                                height: 1.5,
                              ),
                        ),
                        const SizedBox(height: 28),
                        _DownloadCard(
                          controller: controller,
                          totalBytes: totalBytes,
                        ),
                      ],
                    ),
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
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        gradient: AppColors.heroGradient,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: AppColors.primarybuttonColor.withValues(alpha: 0.25),
            blurRadius: 26,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Icon(
        isDownloading
            ? Icons.downloading_rounded
            : Icons.auto_awesome_rounded,
        color: Colors.white,
        size: 38,
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
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: AppColors.borderColor.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadowColor.withValues(alpha: 0.4),
            blurRadius: 26,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.isDownloadingModels) ...[
            _ProgressSection(progress: controller.downloadProgress),
          ] else ...[
            Row(
              children: [
                const Icon(
                  Icons.sd_storage_outlined,
                  color: AppColors.primarybuttonColor,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  totalBytes != null
                      ? 'Download size: ${ModelDownloadProgress.formatBytes(totalBytes!)}'
                      : 'Preparing download info...',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'A stable connection is recommended — the download can '
              'resume if interrupted.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ],
          if (controller.downloadError.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: AppColors.dangerColor,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      controller.downloadError,
                      style: const TextStyle(
                        color: AppColors.dangerColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
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
            const Expanded(
              child: Text(
                'Downloading models...',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Text(
              '$percent%',
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: AppColors.primarybuttonColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            minHeight: 10,
            value: progress.overallTotalBytes == 0
                ? null
                : progress.overallFraction,
            backgroundColor: AppColors.surfaceAccent,
            valueColor: const AlwaysStoppedAnimation<Color>(
              AppColors.primarybuttonColor,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          progress.overallTotalBytes == 0
              ? 'Starting...'
              : '${ModelDownloadProgress.formatBytes(progress.overallBytesDownloaded)} '
                    'of ${ModelDownloadProgress.formatBytes(progress.overallTotalBytes)}'
                    '${progress.modelFileName.isNotEmpty ? ' — ${progress.modelFileName}' : ''}',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
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
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: controller.cancelModelDownload,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.accentSoft,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Center(
              child: Text(
                'Cancel',
                style: TextStyle(
                  color: AppColors.dangerColor,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final hasError = controller.downloadError.isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: controller.startModelDownload,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.primarybuttonColor,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: AppColors.primarybuttonColor.withValues(alpha: 0.25),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                hasError ? Icons.refresh_rounded : Icons.download_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                hasError ? 'Retry download' : 'Download models',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
