import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/indexed_folder_model.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/confirm_dialog.dart';

class LibraryTab extends StatelessWidget {
  const LibraryTab({super.key, required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StatsRow(controller: controller),
          const SizedBox(height: AppSpacing.lg),
          if (controller.isScanning) ...[
            _IndexingSection(controller: controller),
          ] else ...[
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
                    onTap: () => controller.pickAndScanFolders(isScanEntirePhone: false),
                  ),
                ),
              ],
            ),
          ],
          if (controller.allIndexedFoldersList.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xxl),
            Text(
              'INDEXED FOLDERS',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: AppColors.ink48, letterSpacing: 0.5),
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

  Future<void> _startDeviceScan(BuildContext context, NativeController controller) async {
    final granted = await controller.requestMediaPermission(
      contentMode: controller.selectedContentMode,
    );
    if (!granted) return;
    controller.pickAndScanFolders(isScanEntirePhone: true);
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            icon: Icons.hub_outlined,
            value: '${controller.totalEmbeddings}',
            label: 'Embeddings',
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
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.icon, required this.value, required this.label});

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.base, horizontal: AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        children: [
          Icon(icon, color: AppColors.primary, size: 20),
          const SizedBox(height: AppSpacing.xs),
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
          ),
        ],
      ),
    );
  }
}

class _PillAction extends StatelessWidget {
  const _PillAction({required this.label, required this.filled, required this.onTap});

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
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md, horizontal: AppSpacing.sm),
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
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: filled ? AppColors.onPrimary : AppColors.ink),
          ),
        ),
      ),
    );
  }
}

class _ScanScopeChip extends StatelessWidget {
  const _ScanScopeChip({required this.controller, this.locked = false});

  final NativeController controller;
  final bool locked;

  IconData get _icon {
    switch (controller.selectedContentMode) {
      case ContentMode.images:
        return Icons.image_outlined;
      case ContentMode.videos:
        return Icons.videocam_outlined;
      case ContentMode.both:
        return Icons.auto_awesome_mosaic_outlined;
    }
  }

  String get _label {
    switch (controller.selectedContentMode) {
      case ContentMode.images:
        return 'images only';
      case ContentMode.videos:
        return 'videos only';
      case ContentMode.both:
        return 'images and videos';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: locked ? 0.5 : 1,
      child: Align(
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: locked ? null : controller.cycleContentMode,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.base,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: AppColors.parchment,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_icon, size: 15, color: AppColors.ink48),
                const SizedBox(width: AppSpacing.xs),
                Flexible(
                  child: Text(
                    'Next scan: $_label',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.ink80),
                  ),
                ),
                if (!locked) ...[
                  const SizedBox(width: AppSpacing.xs),
                  const Icon(Icons.sync_alt_rounded, size: 14, color: AppColors.ink48),
                ],
              ],
            ),
          ),
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

  @override
  Widget build(BuildContext context) {
    final scan = controller.scanResult;
    final progress = scan.total == 0 ? 0.0 : (scan.processed / scan.total).clamp(0.0, 1.0);
    final percent = (progress * 100).round();
    final etaText = controller.scanEtaText;

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
                  Text('$percent%', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      scan.total == 0 ? 'Preparing...' : '${scan.processed} / ${scan.total}',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.ink48,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: scan.total == 0 ? null : progress,
                  backgroundColor: AppColors.hairline,
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Text(
                    _speedLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.ink48,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (etaText != null) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        '$etaText left',
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.ink48,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (controller.recentThumbnails.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.base),
                const Divider(height: 1, color: AppColors.hairline),
                const SizedBox(height: AppSpacing.base),
                Text(
                  'JUST INDEXED',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: AppColors.ink48, letterSpacing: 0.5),
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
        _PillAction(label: 'Stop indexing', filled: false, onTap: controller.stopScanning),
      ],
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
  const _RecentThumbTile({super.key, required this.bytes, required this.isVideo});

  final Uint8List? bytes;
  final bool isVideo;

  @override
  State<_RecentThumbTile> createState() => _RecentThumbTileState();
}

class _RecentThumbTileState extends State<_RecentThumbTile> with SingleTickerProviderStateMixin {
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
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 850));
    _scale = Tween<double>(begin: 0.55, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0, 0.55, curve: Curves.easeOutBack)),
    );
    _fade = CurvedAnimation(parent: _controller, curve: const Interval(0, 0.35, curve: Curves.easeOut));
    _ringOpacity = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.15, 1, curve: Curves.easeOut)),
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
                          border: Border.all(color: AppColors.primary, width: 2),
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
                  child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18),
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
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          Icon(
            granted ? Icons.notifications_active_rounded : Icons.notifications_none_rounded,
            size: 17,
            color: granted ? AppColors.primary : AppColors.ink48,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              granted ? 'Background scanning enabled' : 'Keep this going in the background',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.ink80, fontWeight: FontWeight.w600),
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
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: AppColors.primary),
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
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.md),
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
                message: 'This forgets everything indexed from "${folder.path}".',
                confirmLabel: 'Remove',
                onConfirm: () => controller.deleteFolderById(id: folder.id),
              ),
              child: const Padding(
                padding: EdgeInsets.all(AppSpacing.xs),
                child: Icon(Icons.close_rounded, size: 16, color: AppColors.ink48),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
