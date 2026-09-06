import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/indexed_folder_model.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/settings_screen.dart';
import 'package:twentyonevision/view/widget/search_results.dart';

/// Search is the app - there is no bottom nav. Settings lives behind the
/// gear icon; indexing takes over the body in place of results instead of
/// occupying its own tab, and search stays usable throughout (it runs on
/// its own native thread even while a scan is active).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<NativeController>(
      builder: (controller) {
        final showResults =
            controller.isSearching ||
            controller.searchResults.isNotEmpty ||
            controller.error.isNotEmpty;

        return Scaffold(
          backgroundColor: AppColors.canvas,
          body: SafeArea(
            child: Column(
              children: [
                const _HomeTopBar(),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.xl,
                      AppSpacing.xs,
                      AppSpacing.xl,
                      AppSpacing.xl,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SearchPill(controller: controller),
                        const SizedBox(height: AppSpacing.lg),
                        if (showResults) ...[
                          if (controller.isScanning)
                            _BackgroundIndexingNote(controller: controller),
                          SearchResultsGrid(controller: controller),
                        ] else if (controller.isScanning) ...[
                          _IndexingSection(controller: controller),
                        ] else ...[
                          _IdleSection(controller: controller),
                        ],
                      ],
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

class _HomeTopBar extends StatelessWidget {
  const _HomeTopBar();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.sm, AppSpacing.md, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Vector', style: Theme.of(context).textTheme.titleLarge),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: AppColors.ink, size: 22),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
    );
  }
}

// The search bar has two input modes - typed text, or an attached photo for
// a reverse-image search - and one explicit way to submit either. Picking a
// photo only attaches it (shown as a chip, same idea as an attachment
// preview above a chat message) - nothing runs until Search is pressed,
// exactly like typing text doesn't search until then either.
class _SearchPill extends StatelessWidget {
  const _SearchPill({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final hasImage = controller.pickedSearchImageUri != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.xxs),
          decoration: BoxDecoration(
            color: AppColors.parchment,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            children: [
              if (hasImage) ...[
                Expanded(child: _AttachedImageChip(controller: controller)),
              ] else ...[
                const Icon(Icons.search_rounded, size: 19, color: AppColors.ink48),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: controller.searchTextController,
                    onTapOutside: (_) => FocusScope.of(context).unfocus(),
                    onSubmitted: (_) => controller.runSearch(),
                    textInputAction: TextInputAction.search,
                    style: Theme.of(context).textTheme.bodyMedium,
                    decoration: const InputDecoration(
                      hintText: 'Search your photos and videos',
                      hintStyle: TextStyle(color: AppColors.ink48),
                      border: InputBorder.none,
                      isCollapsed: true,
                      contentPadding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: AppSpacing.sm),
              _SearchSubmitButton(controller: controller),
            ],
          ),
        ),
        if (!hasImage) ...[
          const SizedBox(height: AppSpacing.xs),
          _ImageSearchHint(onTap: controller.pickSearchImage),
        ],
      ],
    );
  }
}

class _AttachedImageChip extends StatelessWidget {
  const _AttachedImageChip({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final bytes = controller.pickedSearchImageBytes;

    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: SizedBox(
            width: 32,
            height: 32,
            child: bytes == null
                ? const ColoredBox(color: AppColors.hairline)
                : Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 64, cacheHeight: 64),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            'Matching this photo',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.ink80),
          ),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: controller.clearPickedSearchImage,
          child: const Padding(
            padding: EdgeInsets.all(AppSpacing.xs),
            child: Icon(Icons.close_rounded, size: 17, color: AppColors.ink48),
          ),
        ),
      ],
    );
  }
}

class _ImageSearchHint extends StatelessWidget {
  const _ImageSearchHint({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xxs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_search_rounded, size: 14, color: AppColors.ink48),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                'Or match a photo instead of describing it',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// A live listener on the text field, not just a GetX rebuild - typing
// doesn't call update(), so without this the button's enabled state would
// only refresh whenever something unrelated happened to rebuild the screen.
class _SearchSubmitButton extends StatelessWidget {
  const _SearchSubmitButton({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.searchTextController,
      builder: (context, _) {
        final enabled =
            controller.pickedSearchImageUri != null ||
            controller.searchTextController.text.trim().isNotEmpty;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? controller.runSearch : null,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: enabled ? AppColors.primary : AppColors.hairline,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.arrow_forward_rounded,
                size: 18,
                color: enabled ? AppColors.onPrimary : AppColors.ink48,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BackgroundIndexingNote extends StatelessWidget {
  const _BackgroundIndexingNote({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.base),
      child: Row(
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Indexing continues in the background - ${controller.totalEmbeddings} indexed so far.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
            ),
          ),
        ],
      ),
    );
  }
}

class _IdleSection extends StatelessWidget {
  const _IdleSection({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final hasIndex = controller.totalEmbeddings > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.parchment,
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: Icon(
              hasIndex ? Icons.search_rounded : Icons.travel_explore_rounded,
              color: AppColors.primary,
              size: 28,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            hasIndex ? 'Search your photos and videos' : 'Index your phone to get started',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            hasIndex
                ? 'Describe a moment above, or add another folder below.'
                : 'Vector builds a private, on-device index so you can find any '
                      'photo or video by describing it.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.45),
          ),
          const SizedBox(height: AppSpacing.xl),
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
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.sm),
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
            ],
          ),
        ),
        if (controller.recentThumbnails.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Text(
            'RECENTLY INDEXED',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: AppColors.ink48, letterSpacing: 0.5),
          ),
          const SizedBox(height: AppSpacing.sm),
          _RecentThumbStrip(controller: controller),
        ],
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
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: controller.recentThumbnails.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) {
          final item = controller.recentThumbnails[index];
          final key = _keyFor(item);
          return _RecentThumbTile(key: ValueKey(key), bytes: controller.recentThumbBytes[key]);
        },
      ),
    );
  }
}

class _RecentThumbTile extends StatefulWidget {
  const _RecentThumbTile({super.key, required this.bytes});

  final Uint8List? bytes;

  @override
  State<_RecentThumbTile> createState() => _RecentThumbTileState();
}

class _RecentThumbTileState extends State<_RecentThumbTile> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    // Plays once when this tile's key first enters the strip - an existing
    // tile that just gets repositioned is never recreated, so it never
    // re-plays this.
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: SizedBox(
          width: 52,
          height: 52,
          child: widget.bytes == null
              ? const ColoredBox(color: AppColors.parchment)
              : Image.memory(widget.bytes!, fit: BoxFit.cover, cacheWidth: 104, cacheHeight: 104),
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
              granted
                  ? 'Background scanning enabled'
                  : 'Keep this going in the background',
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
