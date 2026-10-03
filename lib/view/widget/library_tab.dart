import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/indexed_folder_model.dart';
import 'package:twentyonevision/models/model_status.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/utils/floating_bar.dart';
import 'package:twentyonevision/view/widget/confirm_dialog.dart';

class LibraryTab extends StatelessWidget {
  const LibraryTab({super.key, required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
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
          _StatsRow(controller: controller),
          const SizedBox(height: AppSpacing.lg),
          if (controller.isScanning) ...[
            _IndexingSection(controller: controller),
          ] else ...[
            if (controller.scanSummary != null) ...[
              _ScanCompleteCard(
                key: ValueKey(controller.scanSummary),
                summary: controller.scanSummary!,
                onDismiss: controller.dismissScanSummary,
              ),
              const SizedBox(height: AppSpacing.base),
            ],
            if (controller.interruptedScan != null) ...[
              _InterruptedScanBanner(controller: controller),
              const SizedBox(height: AppSpacing.base),
            ],
            _ScanScopeChip(controller: controller),
            const SizedBox(height: AppSpacing.base),
            Row(
              children: [
                Expanded(
                  child: _PillAction(
                    label: 'Index phone',
                    filled: true,
                    onTap: () => _startDeviceScan(context, controller),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _PillAction(
                    label: 'Choose folder',
                    filled: false,
                    onTap: () =>
                        controller.pickAndScanFolders(isScanEntirePhone: false),
                  ),
                ),
              ],
            ),
          ],
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
}

// Two tiers, deliberately: Images/Videos/Folders are what someone actually
// asked for ("how much of my stuff is in here"), so they're the large
// primary tiles. Embeddings is real but more of an implementation detail
// (a video contributes several - see refreshLibraryStats' doc) so it's
// folded into the quieter footer line with the index's on-disk size and
// when it was last scanned, rather than competing for the same visual
// weight as the tiles above it.
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.controller});

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
      parts.add('${ModelDownloadProgress.formatBytes(controller.indexSizeBytes)} on device');
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
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
      ),
    );
  }
}

DateTime? _lastScanTime(List<IndexedFolder> folders) {
  if (folders.isEmpty) return null;
  final latest = folders.map((f) => f.updatedAt).reduce((a, b) => a > b ? a : b);
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

class _PillAction extends StatelessWidget {
  const _PillAction({
    required this.label,
    required this.filled,
    required this.onTap,
  });

  final String label;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.md,
            horizontal: AppSpacing.sm,
          ),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: filled ? null : Border.all(color: AppColors.hairline),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: filled ? AppColors.onPrimary : AppColors.ink,
            ),
          ),
        ),
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

class _IndexingSection extends StatelessWidget {
  const _IndexingSection({required this.controller});

  final NativeController controller;

  String get _speedLabel {
    final perSecond = controller.recentEmbeddingsPerSecond;
    if (perSecond <= 0) return 'measuring speed';
    if (perSecond >= 1) return '${perSecond.toStringAsFixed(1)}/sec';
    return '${(1000 / perSecond).round()}ms/item';
  }

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

  @override
  Widget build(BuildContext context) {
    final scan = controller.scanResult;
    final progress = scan.total == 0
        ? 0.0
        : (scan.processed / scan.total).clamp(0.0, 1.0);
    final percent = (progress * 100).round();
    final etaText = controller.scanEtaText;

    // Indexing and finding faces take turns: every so many photos, indexing waits
    // while their faces are found. The card shows whichever is happening right now.
    return GetBuilder<FacesController>(
      builder: (faces) => _buildCard(context, scan, progress, percent, etaText, faces.status),
    );
  }

  Widget _buildCard(
    BuildContext context,
    IndexedFolder scan,
    double progress,
    int percent,
    String? etaText,
    FaceStatus faceStatus,
  ) {
    final findingFaces = faceStatus.running && faceStatus.batch;
    final tuning = findingFaces && faceStatus.phase == 'tune';
    final faceFraction = faceStatus.total <= 0
        ? 0.0
        : (faceStatus.processed / faceStatus.total).clamp(0.0, 1.0);
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: AppColors.ink48,
      fontWeight: FontWeight.w600,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.base),
          decoration: BoxDecoration(
            color: AppColors.parchment,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    findingFaces
                        ? (tuning ? 'Optimising' : 'Finding faces')
                        : '$percent%',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  if (findingFaces && !tuning && faceStatus.total > 0)
                    Expanded(
                      child: Text(
                        '${faceStatus.processed} / ${faceStatus.total}',
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    )
                  else if (!findingFaces && scan.total > 0)
                    Expanded(
                      child: Text(
                        '${scan.processed} / ${scan.total}',
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ),
                ],
              ),
              if (scan.total == 0) ...[
                const SizedBox(height: AppSpacing.xs),
                // Its own full-width line rather than squeezed next to the
                // percent above - a folder that takes a while to enumerate
                // can report a count here, and it needs the room. The
                // number itself animates up to each new value instead of
                // jumping, so it visibly moves even between the roughly
                // half-second gaps native's own updates arrive at.
                _FoundSoFarLabel(count: _foundSoFarCount(scan)),
              ],
              const SizedBox(height: AppSpacing.sm),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: scan.total == 0
                    ? const _ScanningPulseBar()
                    : LinearProgressIndicator(
                        minHeight: 6,
                        // Faces: how far through this batch; a one-off speed test has
                        // no end to show. Otherwise indexing's own progress.
                        value: findingFaces
                            ? (tuning ? null : faceFraction)
                            : progress,
                        backgroundColor: AppColors.hairline,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.primary,
                        ),
                      ),
              ),
              const SizedBox(height: AppSpacing.sm),
              if (findingFaces)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        tuning
                            ? 'One-time speed test, about a minute'
                            : 'Indexing carries on right after',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ),
                    if (scan.total > 0) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        '${scan.processed} / ${scan.total} indexed',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ],
                  ],
                )
              else ...[
                Row(
                  children: [
                    Text(
                      _speedLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                    if (etaText != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          '$etaText left',
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ),
                    ],
                  ],
                ),
                if (faceStatus.following && faceStatus.people > 0) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '${faceStatus.people} ${faceStatus.people == 1 ? 'person' : 'people'} found so far',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ],
              ],
              if (controller.recentThumbnails.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.base),
                const Divider(height: 1, color: AppColors.hairline),
                const SizedBox(height: AppSpacing.base),
                Text(
                  'JUST INDEXED',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColors.ink48,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                _RecentThumbStrip(controller: controller),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        _BackgroundScanBanner(controller: controller),
        const SizedBox(height: AppSpacing.base),
        _ScanScopeChip(controller: controller, locked: true),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Search already works on what\'s finished - this keeps going if you switch apps.',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.4),
        ),
        const SizedBox(height: AppSpacing.base),
        _PillAction(
          label: 'Stop indexing',
          filled: false,
          onTap: controller.stopScanning,
        ),
      ],
    );
  }
}

// Ticks up to each new count instead of jumping straight to it, so the
// number itself is a source of visible motion between native's updates,
// not just a value that occasionally gets replaced. Null count (nothing
// found yet at all) shows "Preparing..." with no animation - there's
// nothing to count up from yet.
class _FoundSoFarLabel extends StatelessWidget {
  const _FoundSoFarLabel({required this.count});

  final int? count;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: AppColors.ink48,
      fontWeight: FontWeight.w600,
    );

    if (count == null) {
      return Text(
        'Preparing...',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    return TweenAnimationBuilder<int>(
      tween: IntTween(end: count!),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOut,
      builder: (context, value, child) {
        return Text(
          'Found $value files so far',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      },
    );
  }
}

// Stands in for the plain indeterminate bar while a folder's still being
// enumerated - a row of small bars whose brightness ripples across them
// in a wave, like a calm audio equalizer rather than a scanner sweep.
// Nothing here ever changes position - only color/brightness does - which
// is what makes it comfortable to watch for a while: a moving element
// (an earlier version swept a highlight across the whole track; another
// pulsed the entire bar in and out) reads as flickery/dizzying much
// faster than a fixed shape that's simply breathing.
class _ScanningPulseBar extends StatefulWidget {
  const _ScanningPulseBar();

  @override
  State<_ScanningPulseBar> createState() => _ScanningPulseBarState();
}

class _ScanningPulseBarState extends State<_ScanningPulseBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const _barCount = 5;
  static const _gap = 3.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 6,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            children: List.generate(_barCount * 2 - 1, (i) {
              if (i.isOdd) return const SizedBox(width: _gap);

              final barIndex = i ~/ 2;
              // Each bar's brightness follows its own sine wave, phase-
              // shifted from its neighbors so the bright point appears to
              // travel across the row - purely a color change per bar,
              // never a moving shape.
              final phase = barIndex / _barCount;
              final t = (_controller.value + phase) % 1.0;
              final brightness = (math.sin(t * 2 * math.pi) + 1) / 2;

              return Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color.lerp(
                      AppColors.hairline,
                      AppColors.primary,
                      0.25 + 0.65 * brightness,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const SizedBox(height: 6),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

class _RecentThumbStrip extends StatelessWidget {
  const _RecentThumbStrip({required this.controller});

  final NativeController controller;

  String _keyFor(RecentEmbeddedItem item) =>
      item.isVideo ? '${item.uri}@${item.timestampMs}' : item.uri;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 58,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: controller.recentThumbnails.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) {
          final item = controller.recentThumbnails[index];
          final key = _keyFor(item);
          return _RecentThumbTile(
            key: ValueKey(key),
            bytes: controller.recentThumbBytes[key],
            isVideo: item.isVideo,
          );
        },
      ),
    );
  }
}

class _RecentThumbTile extends StatefulWidget {
  const _RecentThumbTile({
    super.key,
    required this.bytes,
    required this.isVideo,
  });

  final Uint8List? bytes;
  final bool isVideo;

  @override
  State<_RecentThumbTile> createState() => _RecentThumbTileState();
}

class _RecentThumbTileState extends State<_RecentThumbTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _fade;
  late final Animation<double> _ringOpacity;

  @override
  void initState() {
    super.initState();
    // Plays once when this tile's key first enters the strip - an existing
    // tile that just gets repositioned is never recreated, so it never
    // re-plays this. A small overshoot on the scale plus a fading accent
    // ring gives each new arrival a brief "just landed" moment instead of
    // a flat fade-in.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    _scale = Tween<double>(begin: 0.55, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, 0.55, curve: Curves.easeOutBack),
      ),
    );
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.35, curve: Curves.easeOut),
    );
    _ringOpacity = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.15, 1, curve: Curves.easeOut),
      ),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _fade.value,
          child: Transform.scale(
            scale: _scale.value,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                child!,
                Positioned.fill(
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: _ringOpacity.value,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadius.md + 3),
                          border: Border.all(
                            color: AppColors.primary,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: SizedBox(
          width: 58,
          height: 58,
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.bytes == null
                  ? const ColoredBox(color: AppColors.canvas)
                  : Image.memory(
                      widget.bytes!,
                      fit: BoxFit.cover,
                      cacheWidth: 116,
                      cacheHeight: 116,
                    ),
              if (widget.isVideo)
                Container(
                  alignment: Alignment.center,
                  color: Colors.black.withValues(alpha: 0.16),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
            ],
          ),
        ),
      ),
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
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

// The moment a scan reaches 100% - instead of the progress card just
// vanishing back to the idle buttons, a ring draws itself, a check strokes
// in, pulses radiate out, and the indexed count ticks up. Auto-dismisses
// after a few seconds (or on tap of the X).
class _ScanCompleteCard extends StatefulWidget {
  const _ScanCompleteCard({super.key, required this.summary, required this.onDismiss});

  final ScanSummary summary;
  final VoidCallback onDismiss;

  @override
  State<_ScanCompleteCard> createState() => _ScanCompleteCardState();
}

class _ScanCompleteCardState extends State<_ScanCompleteCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    HapticFeedback.mediumImpact();
    // The auto-dismiss clock starts when the animation *finishes*, not when
    // the card is built: the tabs live in an IndexedStack, so if the scan
    // completes while another tab is showing, this animation is paused until
    // the Library tab is actually visible - a timer started here would tick
    // down unseen and remove the card before anyone looked at it.
    _anim.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _autoDismiss = Timer(const Duration(seconds: 8), () {
          if (mounted) widget.onDismiss();
        });
      }
    });
    _anim.forward();
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.base),
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _anim,
            builder: (context, _) {
              return SizedBox(
                width: 72,
                height: 72,
                child: CustomPaint(painter: _CompletePainter(_anim.value)),
              );
            },
          ),
          const SizedBox(width: AppSpacing.base),
          Expanded(
            child: AnimatedBuilder(
              animation: _anim,
              builder: (context, child) {
                final t = Curves.easeOut.transform(((_anim.value - 0.45) / 0.4).clamp(0.0, 1.0));
                return Opacity(
                  opacity: t,
                  child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: child),
                );
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Scan complete', style: textTheme.titleSmall),
                  const SizedBox(height: 2),
                  TweenAnimationBuilder<int>(
                    tween: IntTween(begin: 0, end: summary.indexed),
                    duration: const Duration(milliseconds: 1400),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => Text(
                      '$value indexed and searchable',
                      style: textTheme.bodySmall?.copyWith(color: AppColors.ink80),
                    ),
                  ),
                  if (summary.failed > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      '${summary.failed} couldn\'t be read',
                      style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                    ),
                  ],
                ],
              ),
            ),
          ),
          InkWell(
            onTap: widget.onDismiss,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: const Padding(
              padding: EdgeInsets.all(AppSpacing.xs),
              child: Icon(Icons.close_rounded, size: 16, color: AppColors.ink48),
            ),
          ),
        ],
      ),
    );
  }
}

// One timeline for the whole thing (t in 0..1): the ring sweeps in over the
// first ~40%, the check strokes over ~35-65%, and two pulse rings expand
// and fade from ~55% on. The whole mark also settles with a small overshoot.
class _CompletePainter extends CustomPainter {
  _CompletePainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 6;

    final scale = Curves.elasticOut.transform((t / 0.5).clamp(0.0, 1.0));
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(0.6 + 0.4 * scale);
    canvas.translate(-center.dx, -center.dy);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = AppColors.hairline;
    canvas.drawCircle(center, radius, track);

    final ringT = Curves.easeInOut.transform((t / 0.4).clamp(0.0, 1.0));
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = AppColors.primary;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * ringT,
      false,
      ring,
    );

    final checkT = Curves.easeOut.transform(((t - 0.35) / 0.3).clamp(0.0, 1.0));
    if (checkT > 0) {
      final path = Path()
        ..moveTo(size.width * 0.30, size.height * 0.52)
        ..lineTo(size.width * 0.44, size.height * 0.65)
        ..lineTo(size.width * 0.71, size.height * 0.36);
      final metric = path.computeMetrics().first;
      final check = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = AppColors.primary;
      canvas.drawPath(metric.extractPath(0, metric.length * checkT), check);
    }
    canvas.restore();

    for (var i = 0; i < 2; i++) {
      final pulseT = ((t - 0.55 - i * 0.15) / 0.45).clamp(0.0, 1.0);
      if (pulseT <= 0 || pulseT >= 1) continue;
      final pulse = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = AppColors.primary.withValues(alpha: 0.35 * (1 - pulseT));
      canvas.drawCircle(center, radius * (1 + 0.5 * pulseT), pulse);
    }
  }

  @override
  bool shouldRepaint(_CompletePainter old) => old.t != t;
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
              child: Icon(Icons.close_rounded, size: 16, color: AppColors.ink48),
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
