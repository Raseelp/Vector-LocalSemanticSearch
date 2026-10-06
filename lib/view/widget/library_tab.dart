import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/indexed_folder_model.dart';
import 'package:twentyonevision/models/model_status.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/utils/floating_bar.dart';
import 'package:twentyonevision/view/widget/confirm_dialog.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/view/widget/library_orbit.dart';
import 'package:twentyonevision/view/widget/scan_square.dart';

class LibraryTab extends StatelessWidget {
  const LibraryTab({super.key, required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final scanning = controller.isScanning;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xl,
        0,
        AppSpacing.xl,
        floatingBarClearance(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The chip stays where it is through idle, scanning and done: only what is on it
          // (and what is written under it) changes.
          _ChipHero(controller: controller),
          AnimatedSize(
            duration: const Duration(milliseconds: 340),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: scanning
                  ? _ScanningControls(
                      key: const ValueKey('scanning'),
                      controller: controller,
                    )
                  : _IdleControls(
                      key: const ValueKey('idle'),
                      controller: controller,
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          // The three tiles, just above the folders; they fold into one quiet line while a
          // scan runs.
          AnimatedSize(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              child: scanning
                  ? _SlimStats(
                      key: const ValueKey('slim'),
                      controller: controller,
                    )
                  : _StatsRow(
                      key: const ValueKey('tiles'),
                      controller: controller,
                    ),
            ),
          ),
          if (controller.allIndexedFoldersList.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xxl),
            Text(
              'INDEXED FOLDERS',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppColors.ink48,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            ...controller.allIndexedFoldersList.map(
              (f) => _FolderRow(folder: f, controller: controller),
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> _startDeviceScan(
  BuildContext context,
  NativeController controller,
) async {
  final granted = await controller.requestMediaPermission(
    contentMode: controller.selectedContentMode,
  );
  if (!granted) return;
  controller.pickAndScanFolders(isScanEntirePhone: true);
}

// Before a scan (and after one): the choices under the chip.
class _IdleControls extends StatelessWidget {
  const _IdleControls({super.key, required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.base),
        if (controller.interruptedScan != null) ...[
          _InterruptedScanBanner(controller: controller),
          const SizedBox(height: AppSpacing.base),
        ],
        _ScanScopeChip(controller: controller),
        const SizedBox(height: AppSpacing.sm),
        Center(
          child: OrbitPill(
            label: 'Choose folder',
            icon: Icons.folder_open_rounded,
            onTap: () =>
                controller.pickAndScanFolders(isScanEntirePhone: false),
          ),
        ),
      ],
    );
  }
}

// What the tiles say, in one line, while a scan is running.
class _SlimStats extends StatelessWidget {
  const _SlimStats({super.key, required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      '${controller.totalImages} images',
      '${controller.totalVideos} videos',
      '${controller.allIndexedFoldersList.length} folders',
      if (controller.totalFailed > 0) '${controller.totalFailed} failed',
    ];
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        parts.join('  ·  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: AppColors.ink80),
      ),
    );
  }
}

// Two tiers, deliberately: Images/Videos/Folders are what someone actually
// asked for ("how much of my stuff is in here"), so they're the large
// primary tiles. Embeddings is real but more of an implementation detail
// (a video contributes several - see refreshLibraryStats' doc) so it's
// folded into the quieter footer line with the index's on-disk size and
// when it was last scanned, rather than competing for the same visual
// weight as the tiles above it.
class _StatsRow extends StatelessWidget {
  const _StatsRow({super.key, required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _StatTile(
                icon: Icons.image_outlined,
                value: '${controller.totalImages}',
                label: 'Images',
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _StatTile(
                icon: Icons.videocam_outlined,
                value: '${controller.totalVideos}',
                label: 'Videos',
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _StatTile(
                icon: Icons.folder_copy_outlined,
                value: '${controller.allIndexedFoldersList.length}',
                label: 'Folders',
              ),
            ),
            // Only shown when there's something to report - most libraries
            // never see it. Files here couldn't be read or embedded (corrupt,
            // unsupported format), which is why a rescan of a "finished"
            // library still tries a handful of files every time.
            if (controller.totalFailed > 0) ...[
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _StatTile(
                  icon: Icons.warning_amber_rounded,
                  iconColor: AppColors.danger,
                  value: '${controller.totalFailed}',
                  label: 'Failed',
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        _StatsFooter(controller: controller),
      ],
    );
  }
}

// A single quiet line rather than more tiles - embeddings/size/last-scan
// are context, not headline numbers, and stacking more tiles under the
// primary row would start to compete with it instead of supporting it.
class _StatsFooter extends StatelessWidget {
  const _StatsFooter({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final parts = <String>['${controller.totalEmbeddings} embeddings'];

    if (controller.indexSizeBytes > 0) {
      parts.add(
        '${ModelDownloadProgress.formatBytes(controller.indexSizeBytes)} on device',
      );
    }

    final lastScan = _lastScanTime(controller.allIndexedFoldersList);
    if (lastScan != null) {
      parts.add('scanned ${_timeAgo(lastScan)}');
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Text(
        parts.join('  ·  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
      ),
    );
  }
}

DateTime? _lastScanTime(List<IndexedFolder> folders) {
  if (folders.isEmpty) return null;
  final latest = folders
      .map((f) => f.updatedAt)
      .reduce((a, b) => a > b ? a : b);
  if (latest <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(latest);
}

String _timeAgo(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${time.month}/${time.day}/${time.year}';
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.value,
    required this.label,
    this.iconColor = AppColors.primary,
  });

  final IconData icon;
  final String value;
  final String label;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.md,
        horizontal: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        children: [
          Icon(icon, color: iconColor, size: 18),
          const SizedBox(height: AppSpacing.xs),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
          ),
        ],
      ),
    );
  }
}

const _scopeOrder = [ContentMode.images, ContentMode.both, ContentMode.videos];

IconData _contentModeIcon(ContentMode mode) {
  switch (mode) {
    case ContentMode.images:
      return Icons.image_outlined;
    case ContentMode.videos:
      return Icons.videocam_outlined;
    case ContentMode.both:
      return Icons.auto_awesome_mosaic_outlined;
  }
}

String _contentModeLabel(ContentMode mode) {
  switch (mode) {
    case ContentMode.images:
      return 'images only';
    case ContentMode.videos:
      return 'videos only';
    case ContentMode.both:
      return 'images and videos';
  }
}

// A bordered pill with a dropdown chevron, not a flat-filled chip - the
// chevron is what reads as "tap to pick" at a glance, the same signal a
// native select control gives. Tapping opens a proper sheet with all three
// options spelled out, rather than blindly cycling through them on tap.
class _ScanScopeChip extends StatelessWidget {
  const _ScanScopeChip({required this.controller, this.locked = false});

  final NativeController controller;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final mode = controller.selectedContentMode;

    return Opacity(
      opacity: locked ? 0.5 : 1,
      child: Align(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            onTap: locked ? null : () => _showScopePicker(context, controller),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.base,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: AppColors.canvas,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: AppColors.hairline),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _contentModeIcon(mode),
                    size: 15,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(
                    child: Text(
                      'Next scan: ${_contentModeLabel(mode)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: AppColors.ink80),
                    ),
                  ),
                  if (!locked) ...[
                    const SizedBox(width: AppSpacing.xs),
                    const Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: AppColors.ink48,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void _showScopePicker(BuildContext context, NativeController controller) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _ScopeSheet(controller: controller),
  );
}

class _ScopeSheet extends StatelessWidget {
  const _ScopeSheet({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl,
          0,
          AppSpacing.xl,
          AppSpacing.xl,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.canvas,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.base),
                child: Text(
                  'What should the next scan include?',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const Divider(height: 1, color: AppColors.hairline),
              for (final mode in _scopeOrder) ...[
                if (mode != _scopeOrder.first)
                  const Divider(height: 1, color: AppColors.dividerSoft),
                _ScopeOption(
                  mode: mode,
                  selected: controller.selectedContentMode == mode,
                  onTap: () {
                    controller.toggleSelectedContentMode(contentMode: mode);
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ScopeOption extends StatelessWidget {
  const _ScopeOption({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final ContentMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.base,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(
              _contentModeIcon(mode),
              size: 18,
              color: selected ? AppColors.primary : AppColors.ink48,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                _contentModeLabel(mode),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: selected ? AppColors.primary : AppColors.ink,
                ),
              ),
            ),
            if (selected)
              const Icon(
                Icons.check_rounded,
                size: 18,
                color: AppColors.primary,
              ),
          ],
        ),
      ),
    );
  }
}

// The chip at the top of the page: waiting to be started, scanning (indexing's progress, the
// photos being read and the queue of those waiting for their faces, and when indexing stops
// to find the faces of a batch the faces lifted out of their photos and placed among the
// people), or done. It is one widget for all three, so the chip itself never moves.
class _ChipHero extends StatelessWidget {
  const _ChipHero({required this.controller});

  final NativeController controller;

  // Before a total is known, native is still walking the picked folder
  // (a whole-device scan skips this phase entirely - see ScanProgress.path)
  // and already reports a live "found N files so far" through path. Parsed
  // back out below to drive an animated counter instead of just printing
  // the string as-is - a number that visibly ticks up reads as "actively
  // working" far more than the same text replacing itself every so often.
  int? _foundSoFarCount(IndexedFolder scan) {
    final match = RegExp(r'\d+').firstMatch(scan.path);
    if (match == null) return null;
    return int.tryParse(match.group(0)!);
  }

  String _thumbKey(RecentEmbeddedItem item) =>
      item.isVideo ? '${item.uri}@${item.timestampMs}' : item.uri;

  @override
  Widget build(BuildContext context) {
    // Indexing and finding faces take turns: every so many photos, indexing waits
    // while their faces are found. The chip shows whichever is happening right now.
    if (!Get.isRegistered<FacesController>()) return _body(context, null);
    return GetBuilder<FacesController>(
      builder: (faces) => _body(context, faces),
    );
  }

  Widget _body(BuildContext context, FacesController? faces) {
    final scan = controller.scanResult;
    final summary = controller.scanSummary;
    final mode = controller.isScanning
        ? ScanChipMode.scanning
        : summary != null
        ? ScanChipMode.complete
        : ScanChipMode.idle;
    final progress = scan.total == 0
        ? 0.0
        : (scan.processed / scan.total).clamp(0.0, 1.0);
    final percent = (progress * 100).round();
    final faceStatus = faces?.status ?? FaceStatus();
    final findingFaces = faceStatus.running && faceStatus.batch;
    final tuning = findingFaces && faceStatus.phase == 'tune';
    final faceFraction = faceStatus.total <= 0
        ? 0.0
        : (faceStatus.processed / faceStatus.total).clamp(0.0, 1.0);
    final photos = [
      for (final item in controller.recentThumbnails)
        OrbitPhoto(
          id: _thumbKey(item),
          bytes: controller.recentThumbBytes[_thumbKey(item)],
        ),
    ];

    final semantics = switch (mode) {
      ScanChipMode.idle => 'Index phone',
      ScanChipMode.complete =>
        'Scan complete, ${summary?.indexed ?? 0} indexed. Tap to dismiss',
      ScanChipMode.scanning =>
        findingFaces
            ? (tuning
                  ? 'Optimising face search for your phone'
                  : 'Finding faces, ${faceStatus.processed} of ${faceStatus.total} photos')
            : scan.total == 0
            ? 'Preparing to index'
            : 'Indexing $percent percent, ${scan.processed} of ${scan.total}',
    };

    return SquareScanHero(
      mode: mode,
      onStart: () => _startDeviceScan(context, controller),
      onDismiss: controller.dismissScanSummary,
      summary: summary == null
          ? null
          : ScanChipSummary(
              indexed: summary.indexed,
              failed: summary.failed,
              people: faceStatus.people,
            ),
      progress: scan.total == 0 ? null : progress,
      stats: ScanChipStats(
        indexed: scan.processed,
        total: scan.total,
        found: scan.total == 0 ? _foundSoFarCount(scan) : null,
        faceDone: faceStatus.processed,
        faceTotal: faceStatus.total,
        people: faceStatus.people,
        tuning: tuning,
        etaMs: controller.scanEtaMs,
      ),
      photos: photos,
      events: findingFaces && !tuning ? faceStatus.recentFaceEvents : const [],
      discovered: scan.total == 0 ? _foundSoFarCount(scan) : null,
      queue: controller.faceQueueCount == null
          ? null
          : OrbitQueueInfo(
              count: controller.faceQueueCount!,
              ms: controller.faceQueueMs,
              photos: controller.faceBatchPhotos,
              windowMs: controller.faceBatchMs,
              at: controller.faceQueueAt,
            ),
      loadPhoto: (uri) => NativeServices()
          .loadUprightPhoto(uri)
          .then<Uint8List?>((bytes) => bytes)
          .catchError((_) => null),
      rate: controller.recentEmbeddingsPerSecond,
      faceMode: mode == ScanChipMode.scanning && findingFaces,
      faceProgress: tuning ? null : faceFraction,
      semanticsLabel: semantics,
    );
  }
}

// While a scan runs: the controls under the chip.
class _ScanningControls extends StatelessWidget {
  const _ScanningControls({super.key, required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<FacesController>()) return _body(context, null);
    return GetBuilder<FacesController>(
      builder: (faces) => _body(context, faces),
    );
  }

  Widget _body(BuildContext context, FacesController? faces) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sm),
        const SizedBox(height: AppSpacing.lg),
        Center(
          child: OrbitPill(
            label: 'Stop indexing',
            icon: Icons.stop_rounded,
            onTap: controller.stopScanning,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Search already works on what\'s finished - this keeps going if you switch apps.',
          textAlign: TextAlign.center,
          style: textTheme.bodySmall?.copyWith(
            color: AppColors.ink48,
            height: 1.4,
          ),
        ),
        const SizedBox(height: AppSpacing.base),
        _BackgroundScanBanner(controller: controller),
        const SizedBox(height: AppSpacing.base),
        _ScanScopeChip(controller: controller, locked: true),
      ],
    );
  }
}

class _BackgroundScanBanner extends StatelessWidget {
  const _BackgroundScanBanner({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final granted = controller.backgroundNotificationsGranted;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                granted
                    ? Icons.notifications_active_rounded
                    : Icons.notifications_none_rounded,
                size: 17,
                color: granted ? AppColors.primary : AppColors.ink48,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  granted
                      ? 'Background scanning enabled'
                      : 'Keep this going in the background',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.ink80,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!granted)
                InkWell(
                  onTap: controller.requestBackgroundScanPermission,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    child: Text(
                      'Enable',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          // Sets expectations rather than overpromising - background
          // scanning genuinely can get cut short on some phones, so a big
          // library is more reliably finished with the app open than left
          // to run unattended for a long stretch.
          Padding(
            padding: const EdgeInsets.only(left: 25),
            child: Text(
              'Big libraries index fastest with the app open - background '
              'scanning works best in short stretches.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.ink48,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Shown in place of the usual scan buttons when a scan was still going the
// last time this app process existed but isn't anymore - see
// NativeController._checkForInterruptedScan for how that's detected.
// Resuming picks up exactly where it left off (embedImages skips whatever
// it already finished, by hash), so this is a one-tap fix rather than a
// full rescan.
class _InterruptedScanBanner extends StatelessWidget {
  const _InterruptedScanBanner({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.play_circle_outline_rounded,
            size: 17,
            color: AppColors.primary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Indexing was interrupted',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.ink80,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Pick up right where it left off',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                ),
              ],
            ),
          ),
          InkWell(
            onTap: controller.dismissInterruptedScan,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: const Padding(
              padding: EdgeInsets.all(AppSpacing.xs),
              child: Icon(
                Icons.close_rounded,
                size: 16,
                color: AppColors.ink48,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          InkWell(
            onTap: controller.resumeInterruptedScan,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(
                'Resume',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppColors.onPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({required this.folder, required this.controller});

  final IndexedFolder folder;
  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.base,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: AppColors.pearl,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Row(
          children: [
            const Icon(Icons.folder_outlined, size: 18, color: AppColors.ink48),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.path.isEmpty ? 'Unknown' : folder.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '${folder.embedded} embeddings',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                  ),
                ],
              ),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              onTap: () => showConfirmDialog(
                context,
                title: 'Remove this folder?',
                message:
                    'This forgets everything indexed from "${folder.path}".',
                confirmLabel: 'Remove',
                onConfirm: () => controller.deleteFolderById(id: folder.id),
              ),
              child: const Padding(
                padding: EdgeInsets.all(AppSpacing.xs),
                child: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: AppColors.ink48,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
