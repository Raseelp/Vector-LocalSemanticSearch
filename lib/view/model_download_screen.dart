import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/model_status.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';

/// A model's file name in words a person would use.
String friendlyModelName(String fileName) {
  switch (fileName) {
    case 'clip_vision.onnx':
    case 'clip_text.onnx':
      return 'Search';
    default:
      return fileName;
  }
}

/// First run (and after the models are deleted from Settings). One glance
/// answers three questions - what is this, what do I get, what will it cost -
/// and the download button is always on screen, never below the fold.
class ModelDownloadScreen extends StatelessWidget {
  const ModelDownloadScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<NativeController>(
      builder: (controller) {
        final textTheme = Theme.of(context).textTheme;

        return Scaffold(
          backgroundColor: AppColors.canvas,
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(child: _HeaderIcon(isDownloading: controller.isDownloadingModels)),
                            const SizedBox(height: AppSpacing.lg),
                            Text(
                              'Get Vector ready',
                              textAlign: TextAlign.center,
                              style: textTheme.headlineSmall,
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              'An AI model that runs on your phone. '
                              'Download once, then search works offline.',
                              textAlign: TextAlign.center,
                              style: textTheme.bodyMedium?.copyWith(color: AppColors.ink48, height: 1.45),
                            ),
                            const SizedBox(height: AppSpacing.xl),
                            Container(
                              decoration: BoxDecoration(
                                color: AppColors.parchment,
                                borderRadius: BorderRadius.circular(AppRadius.lg),
                              ),
                              child: Column(
                                children: [
                                  _ModelRow(
                                    icon: Icons.search_rounded,
                                    title: 'Search',
                                    benefit: 'Find any photo by describing it',
                                    sizeBytes: controller.searchModelBytes,
                                    done: controller.searchModelsVerified,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.lock_outline_rounded, size: 15, color: AppColors.ink48),
                                const SizedBox(width: AppSpacing.xs),
                                Text(
                                  'Private - nothing ever leaves your phone',
                                  style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // Pinned: the action is always in reach.
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.xl),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: _ActionArea(controller: controller),
                    ),
                  ),
                ),
              ],
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
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: Icon(
        isDownloading ? Icons.downloading_rounded : Icons.auto_awesome_rounded,
        color: AppColors.primary,
        size: 30,
      ),
    );
  }
}

/// One model in a line: what you get from it, and how big it is.
class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.icon,
    required this.title,
    required this.benefit,
    required this.sizeBytes,
    required this.done,
  });

  final IconData icon;
  final String title;
  final String benefit;
  final int sizeBytes;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.md),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(color: AppColors.canvas, shape: BoxShape.circle),
            child: Icon(icon, size: 20, color: AppColors.primary),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: textTheme.titleSmall),
                const SizedBox(height: 1),
                Text(benefit, style: textTheme.bodySmall?.copyWith(color: AppColors.ink48)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (done)
            const Icon(Icons.check_circle_rounded, size: 20, color: AppColors.primary)
          else if (sizeBytes > 0)
            Text(
              ModelDownloadProgress.formatBytes(sizeBytes),
              style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
            ),
        ],
      ),
    );
  }
}

/// The bottom of the screen: the button (with the total size), or the
/// progress while downloading; an error sits just above whichever it is.
class _ActionArea extends StatelessWidget {
  const _ActionArea({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final downloading = controller.isDownloadingModels;
    final hasError = controller.downloadError.isNotEmpty;
    final total = controller.pendingDownloadBytes;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasError && !downloading)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, color: AppColors.danger, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    controller.downloadError,
                    style: textTheme.bodySmall?.copyWith(color: AppColors.danger, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        if (downloading) ...[
          _Progress(
            progress: controller.downloadProgress,
            bytesPerSecond: controller.downloadBytesPerSecond,
            eta: controller.downloadEta,
          ),
          const SizedBox(height: AppSpacing.md),
          PillButton(label: 'Cancel', onTap: controller.cancelModelDownload, outlined: true),
        ] else ...[
          PillButton(
            label: hasError
                ? 'Try again'
                : (total > 0 ? 'Download  ·  ${ModelDownloadProgress.formatBytes(total)}' : 'Continue'),
            icon: hasError ? Icons.refresh_rounded : Icons.download_rounded,
            onTap: controller.startModelDownload,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Wi-Fi recommended  ·  resumes if interrupted',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
          ),
        ],
      ],
    );
  }
}

/// What is happening right now, in words: connecting, downloading (with speed
/// and time left), or checking the file. The first seconds used to be a bare
/// "Starting..." - nobody knows what that means, or whether it is stuck.
class _Progress extends StatelessWidget {
  const _Progress({required this.progress, required this.bytesPerSecond, required this.eta});

  final ModelDownloadProgress progress;
  final double? bytesPerSecond;
  final Duration? eta;

  static String _left(Duration d) {
    if (d.inHours >= 1) return '${d.inHours} h ${d.inMinutes % 60} min left';
    if (d.inMinutes >= 1) return '${d.inMinutes} min left';
    return 'under a minute left';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final connecting = progress.overallTotalBytes == 0;
    final verifying = progress.isVerifying;
    final what = progress.modelFileName.isEmpty ? null : friendlyModelName(progress.modelFileName);

    final title = connecting
        ? 'Connecting to the download server'
        : verifying
            ? 'Checking the ${what ?? 'file'} model is intact'
            : 'Downloading the ${what ?? ''} model'.replaceAll('  ', ' ');

    final reassurance = connecting
        ? 'Checking your storage and reaching the server - this can take a few seconds. Nothing is wrong.'
        : verifying
            ? 'Making sure it arrived complete and unaltered. Almost there.'
            : 'If the connection drops, it picks up where it left off.';

    final details = <String>[
      if (!connecting)
        '${ModelDownloadProgress.formatBytes(progress.overallBytesDownloaded)} '
            'of ${ModelDownloadProgress.formatBytes(progress.overallTotalBytes)}',
      if (!connecting && !verifying && bytesPerSecond != null) ModelDownloadProgress.formatSpeed(bytesPerSecond!),
      if (!connecting && !verifying && eta != null) _left(eta!),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: textTheme.titleSmall)),
            if (!connecting)
              Text(
                '${(progress.overallFraction * 100).round()}%',
                style: textTheme.titleSmall?.copyWith(color: AppColors.primary),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: LinearProgressIndicator(
            minHeight: 6,
            // Waiting for the first bytes, or checking a finished file: no
            // fraction to show, just "working".
            value: (connecting || verifying) ? null : progress.overallFraction,
            backgroundColor: AppColors.hairline,
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        if (details.isNotEmpty)
          Text(
            details.join('  ·  '),
            style: textTheme.bodySmall?.copyWith(color: AppColors.ink80),
          ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          reassurance,
          style: textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.4),
        ),
      ],
    );
  }
}

/// The app's pill-shaped button (filled, or outlined for secondary actions).
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
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
