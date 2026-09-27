import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/image_full_screen.dart';
import 'package:twentyonevision/view/video_full_screen.dart';

// Slivers, not a single boxed widget - this used to be a GridView.builder
// with shrinkWrap:true/NeverScrollableScrollPhysics inside an outer
// SingleChildScrollView, which is a well-known trap: a shrink-wrapped
// grid like that loses proper lazy building/recycling (it has to size
// itself to fit inside a non-scrolling parent), so with enough results
// (a higher "results per search" setting, say) it ends up holding far
// more decoded images in memory at once than are ever actually visible -
// the direct cause of both the occasional crash and the images visibly
// flickering out and back in while scrolling that were reported. Returned
// as slivers so SearchTab's CustomScrollView is the one true scrollable,
// letting the grid genuinely virtualize the way SliverGrid is meant to.
List<Widget> searchResultsSlivers({required NativeController controller}) {
  if (controller.isSearching) {
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        sliver: _SearchSkeletonGrid(layout: controller.resultsLayout),
      ),
    ];
  }

  if (controller.error.isNotEmpty) {
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        sliver: SliverToBoxAdapter(
          child: _CenterNote(
            icon: Icons.error_outline_rounded,
            title: 'Something went wrong',
            subtitle: controller.error,
          ),
        ),
      ),
    ];
  }

  if (controller.searchResults.isEmpty) {
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        sliver: SliverToBoxAdapter(
          child: _CenterNote(
            icon: Icons.search_rounded,
            title: 'Search your media',
            subtitle: controller.totalEmbeddings == 0
                ? 'Index a folder or your phone first, then come back to search.'
                : 'Describe a photo, place, or moment above.',
          ),
        ),
      ),
    ];
  }

  return [
    SliverPadding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        0,
        AppSpacing.xl,
        AppSpacing.sm,
      ),
      sliver: SliverToBoxAdapter(
        child: Builder(
          builder: (context) => Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.xs),
                child: Text(
                  '${controller.searchResults.length} results',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColors.ink48,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const Spacer(),
              _LayoutPickerButton(controller: controller),
            ],
          ),
        ),
      ),
    ),
    SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      sliver: _ResultsSliverGrid(controller: controller),
    ),
  ];
}

// A placeholder grid shaped like the real results grid, shown while a search is in flight -
// the same shimmering _LoadingTile the real grid falls back to for a thumbnail that hasn't
// arrived yet, just filling the whole space rather than waiting for a spinner to clear before
// anything about the coming layout is visible.
class _SearchSkeletonGrid extends StatelessWidget {
  const _SearchSkeletonGrid({required this.layout});

  final ResultsLayout layout;

  int get _crossAxisCount {
    switch (layout) {
      case ResultsLayout.list:
        return 1;
      case ResultsLayout.grid2:
        return 2;
      case ResultsLayout.grid3:
        return 3;
      case ResultsLayout.grid4:
        return 4;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isList = layout == ResultsLayout.list;
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _crossAxisCount,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
        childAspectRatio: isList ? 1.7 : 0.86,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) => ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: _LoadingTile(index: index, isVideo: index % 3 == 2),
        ),
        childCount: isList ? 6 : 12,
      ),
    );
  }
}

// A real SliverGrid, not GridView.builder(shrinkWrap: true) - see
// searchResultsSlivers' doc for why that distinction is the actual fix
// here. SliverChildBuilderDelegate keeps its default addAutomaticKeepAlives/
// addRepaintBoundaries on, which is what stops an offscreen tile's decoded
// image from being discarded and redecoded every time it scrolls back
// into view.
class _ResultsSliverGrid extends StatelessWidget {
  const _ResultsSliverGrid({
    required this.controller,
    this.results,
    this.bytesFor,
    this.matchQuery,
    this.loading = false,
  });

  final NativeController controller;

  // Default to the live search - a collection passes its own list, its own
  // thumbnail cache, and the phrase to explain matches by.
  final List<Map<String, dynamic>>? results;
  final Uint8List? Function(Map<String, dynamic> item)? bytesFor;
  final String? matchQuery;

  // True while thumbnails are still arriving (a collection's progressive
  // loading): a missing one then shows an animated placeholder instead of
  // the "couldn't load" icon, which is only for one that really failed.
  final bool loading;

  List<Map<String, dynamic>> get _results =>
      results ?? controller.searchResults;

  int get _crossAxisCount {
    switch (controller.resultsLayout) {
      case ResultsLayout.list:
        return 1;
      case ResultsLayout.grid2:
        return 2;
      case ResultsLayout.grid3:
        return 3;
      case ResultsLayout.grid4:
        return 4;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isList = controller.resultsLayout == ResultsLayout.list;

    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _crossAxisCount,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
        childAspectRatio: isList ? 1.7 : 0.86,
      ),
      delegate: SliverChildBuilderDelegate((context, index) {
        final item = _results[index];
        final uri = item['path'] as String;
        final isVideo = item['isVideo'] as bool? ?? false;
        final timestampMs = (item['timestampMs'] as num?)?.toInt() ?? 0;
        final bytes = bytesFor != null
            ? bytesFor!(item)
            : controller.imageCache[controller.cacheKeyForResult(item)];

        if (bytes == null && loading) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: _LoadingTile(
              index: index,
              isVideo: item['isVideo'] as bool? ?? false,
            ),
          );
        }

        if (bytes == null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: ColoredBox(
              color: AppColors.parchment,
              child: const Center(
                child: Icon(
                  Icons.image_not_supported_outlined,
                  color: AppColors.ink48,
                ),
              ),
            ),
          );
        }

        return _ResultTile(
          bytes: bytes,
          isVideo: isVideo,
          onTap: () {
            // Fire-and-forget, same as loadMetaDataByUri below - the
            // viewer picks it up reactively once it resolves rather than
            // navigation waiting on it.
            controller.loadMatchExplanation(
              path: uri,
              isVideo: isVideo,
              timestampMs: timestampMs,
              query: matchQuery,
            );
            controller.loadMetaDataByUri(uri: uri, isVideo: isVideo);
            if (isVideo) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => VideoViewScreen(
                    videoUri: uri,
                    timestampMs: timestampMs,
                    thumbnailBytes: bytes,
                  ),
                ),
              );
            } else {
              // A collection's / person's grid holds small thumbnails, so the
              // viewer loads the sharp photo itself; live search results are
              // already viewer-sized.
              Get.to(() => ImageViewScreen(imageBytes: bytes, uri: uri, loadFullRes: bytesFor != null));
            }
          },
        );
      }, childCount: _results.length),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.bytes,
    required this.isVideo,
    required this.onTap,
  });

  final Uint8List bytes;
  final bool isVideo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Bounds the decode to roughly this tile's actual on-screen
              // size - without this, Image.memory decodes at the source's
              // full resolution (native already caps that, but it's still
              // far bigger than a grid cell) just to shrink it for
              // display, which is the other half of what made scrolling
              // through many results memory-hungry.
              //
              // Only cacheWidth is set, deliberately - passing *both*
              // cacheWidth and cacheHeight tells Flutter to decode to
              // exactly that box, ignoring the source photo's own aspect
              // ratio (that's what was stretching every thumbnail,
              // worst on list view where the tile's own aspect ratio is
              // furthest from a typical photo's). With only one given,
              // Flutter scales the other side to match the source's real
              // proportions, and BoxFit.cover crops the (correctly
              // proportioned) result to fill the tile the normal way.
              // Sized off the longer tile edge so there's always enough
              // resolution to cover regardless of the tile's own shape.
              final dpr = MediaQuery.of(context).devicePixelRatio;
              final tileEdge = constraints.maxWidth > constraints.maxHeight
                  ? constraints.maxWidth
                  : constraints.maxHeight;
              final cacheWidth = tileEdge.isFinite
                  ? (tileEdge * dpr).round()
                  : null;

              return Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    cacheWidth: cacheWidth,
                  ),
                  if (isVideo)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 13,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// Same bordered-pill-plus-chevron treatment as the scan-scope control, and
// the same sheet-with-options pattern for picking - one consistent "this is
// how pickers look and behave" language instead of inventing a new one here.
class _LayoutPickerButton extends StatelessWidget {
  const _LayoutPickerButton({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: () => _showLayoutPicker(context, controller),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
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
                _layoutIcon(controller.resultsLayout),
                size: 14,
                color: AppColors.ink80,
              ),
              const SizedBox(width: AppSpacing.xxs),
              const Icon(
                Icons.expand_more_rounded,
                size: 14,
                color: AppColors.ink48,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _showLayoutPicker(BuildContext context, NativeController controller) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _LayoutSheet(controller: controller),
  );
}

class _LayoutSheet extends StatelessWidget {
  const _LayoutSheet({required this.controller});

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
                  'How should results be laid out?',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const Divider(height: 1, color: AppColors.hairline),
              for (final layout in ResultsLayout.values) ...[
                if (layout != ResultsLayout.values.first)
                  const Divider(height: 1, color: AppColors.dividerSoft),
                _LayoutOption(
                  layout: layout,
                  selected: controller.resultsLayout == layout,
                  onTap: () {
                    controller.setResultsLayout(layout);
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

class _LayoutOption extends StatelessWidget {
  const _LayoutOption({
    required this.layout,
    required this.selected,
    required this.onTap,
  });

  final ResultsLayout layout;
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
              _layoutIcon(layout),
              size: 18,
              color: selected ? AppColors.primary : AppColors.ink48,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                _layoutLabel(layout),
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

IconData _layoutIcon(ResultsLayout layout) {
  switch (layout) {
    case ResultsLayout.list:
      return Icons.view_agenda_outlined;
    case ResultsLayout.grid2:
      return Icons.grid_view_rounded;
    case ResultsLayout.grid3:
      return Icons.view_module_rounded;
    case ResultsLayout.grid4:
      return Icons.apps_rounded;
  }
}

String _layoutLabel(ResultsLayout layout) {
  switch (layout) {
    case ResultsLayout.list:
      return 'List - one large preview per row';
    case ResultsLayout.grid2:
      return 'Grid - 2 across';
    case ResultsLayout.grid3:
      return 'Grid - 3 across';
    case ResultsLayout.grid4:
      return 'Grid - 4 across';
  }
}

class _CenterNote extends StatelessWidget {
  const _CenterNote({
    this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData? icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.huge),
      child: Column(
        children: [
          if (icon != null) Icon(icon, size: 32, color: AppColors.ink48),
          const SizedBox(height: AppSpacing.base),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.ink48,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The results grid for something other than the live search (a
/// collection): same tiles and viewers, its own list and thumbnails.
Widget collectionResultsGrid({
  required NativeController controller,
  required List<Map<String, dynamic>> results,
  required Uint8List? Function(Map<String, dynamic> item) bytesFor,
  required String matchQuery,
  bool loading = false,
}) {
  return _ResultsSliverGrid(
    loading: loading,
    controller: controller,
    results: results,
    bytesFor: bytesFor,
    matchQuery: matchQuery,
  );
}

// What a thumbnail that hasn't arrived yet looks like: a soft band of light
// drifting across the tile while a small icon - one that suits the media,
// swapping every moment - fades in and out, so a grid that's still filling
// in feels like it's being developed rather than broken.
class _LoadingTile extends StatefulWidget {
  const _LoadingTile({required this.index, required this.isVideo});

  final int index;
  final bool isVideo;

  @override
  State<_LoadingTile> createState() => _LoadingTileState();
}

class _LoadingTileState extends State<_LoadingTile>
    with SingleTickerProviderStateMixin {
  static const _imageIcons = [
    Icons.landscape_outlined,
    Icons.wb_sunny_outlined,
    Icons.local_florist_outlined,
    Icons.pets_outlined,
    Icons.photo_outlined,
  ];
  static const _videoIcons = [
    Icons.movie_outlined,
    Icons.play_circle_outline_rounded,
    Icons.videocam_outlined,
  ];

  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  );
  Timer? _swap;
  late int _iconIndex = widget.index;

  List<IconData> get _icons => widget.isVideo ? _videoIcons : _imageIcons;

  @override
  void initState() {
    super.initState();
    // Neighbouring tiles start at different points so the grid doesn't pulse in lockstep - the
    // value has to be set *before* repeat() starts, not after: AnimationController.value's
    // setter stops the controller as part of setting it, so the other order started the repeat
    // and immediately cancelled it again in the same frame - a shimmer frozen in place.
    _sweep.value = (widget.index * 0.137) % 1;
    _sweep.repeat();
    _swap = Timer.periodic(const Duration(milliseconds: 1300), (_) {
      if (mounted) setState(() => _iconIndex++);
    });
  }

  @override
  void dispose() {
    _swap?.cancel();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = _icons[_iconIndex % _icons.length];

    // A grid full of these ticks constantly and independently - without its own compositing
    // layer, every tile's sweep would ask Flutter to reconsider repainting the whole grid each
    // frame instead of just the one tile that actually changed.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _sweep,
        builder: (context, child) {
          final t = _sweep.value;
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(-2 + 4 * t, -1),
                end: Alignment(-1 + 4 * t, 1),
                colors: const [
                  AppColors.parchment,
                  AppColors.pearl,
                  AppColors.parchment,
                ],
              ),
            ),
            child: child,
          );
        },
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween(begin: 0.7, end: 1.0).animate(animation),
                child: child,
              ),
            ),
            child: Icon(
              icon,
              key: ValueKey(icon),
              size: 28,
              color: AppColors.ink48.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}
