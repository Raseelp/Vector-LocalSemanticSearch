import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/media_tray.dart';

/// The strip opened from the "search with this" button instead of jumping straight to a full
/// results screen: up to ten photos and videos whose CLIP embedding is closest to the one just
/// tapped, using the same search already computed for it. A button of its own runs the full
/// search anyway, for when ten isn't enough. Lives in a [MediaTray], the same shell the people
/// strip uses, so the two read as one family rather than two one-off cards.
class SimilarItemsBar extends StatelessWidget {
  const SimilarItemsBar({
    super.key,
    required this.items,
    required this.bytesFor,
    required this.loading,
    required this.onTapItem,
    required this.onSearchFull,
    this.label = 'Similar to this',
  });

  final List<Map<String, dynamic>> items;
  final Uint8List? Function(Map<String, dynamic> item) bytesFor;
  final bool loading;
  final void Function(Map<String, dynamic> item, Uint8List? bytes) onTapItem;
  final VoidCallback onSearchFull;
  final String label;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return MediaTray(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: textTheme.labelMedium?.copyWith(color: Colors.white.withValues(alpha: 0.75)),
                  ),
                ),
                _TrayActionPill(label: 'Search with this', onTap: onSearchFull),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 92,
            child: items.isEmpty
                ? (loading
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
                        child: Row(
                          children: [
                            for (var i = 0; i < 4; i++) ...[
                              if (i > 0) const SizedBox(width: AppSpacing.sm),
                              _ShimmerTile(index: i),
                            ],
                          ],
                        ),
                      )
                    : Center(
                        child: Text(
                          'Nothing similar found',
                          style: textTheme.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.6)),
                        ),
                      ))
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
                    itemBuilder: (context, i) {
                      final item = items[i];
                      final bytes = bytesFor(item);
                      // Center, not the tile directly: a horizontal ListView hands every item a
                      // TIGHT cross-axis constraint (exactly this row's height, not just capped
                      // at it), so the tile's own fixed 72x72 SizedBox would get stretched taller
                      // to fill it - which is exactly why the loaded tile came out taller than
                      // the shimmer next to it (that one sits in a plain Row, which loosens its
                      // children's cross-axis instead). Center absorbs the tight constraint
                      // itself and hands the tile a loose one, so it's free to actually be 72x72.
                      return Center(
                        child: _SimilarTile(
                          index: i,
                          isVideo: item['isVideo'] as bool? ?? false,
                          bytes: bytes,
                          onTap: bytes == null ? null : () => onTapItem(item, bytes),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// A solid little button, not a translucent chip tinted and outlined in the same colour - that
/// combination (soft fill, matching border, matching text) is its own cliche. This is built the
/// way the rest of the app's real pill buttons are: a confident solid fill in the app's own
/// primary teal, white text, no wishy-washy transparency - just lifted a touch off the glass with
/// a soft shadow and a thin bright line along its own top edge, echoing the tray's light rather
/// than repeating its colour.
class _TrayActionPill extends StatelessWidget {
  const _TrayActionPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The shadow lives on this outer, unclipped box - Material's own Clip.antiAlias below (kept
    // so the ink ripple stays within the pill's rounded corners) would otherwise cut off a
    // BoxShadow set on the Ink inside it, since a shadow paints outside its box's own edge and
    // clipping is applied at exactly that edge.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1F7A70), AppColors.primary],
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: 10,
                  right: 10,
                  top: 1.5,
                  child: Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [Colors.transparent, Colors.white.withValues(alpha: 0.55), Colors.transparent]),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 2, vertical: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(color: AppColors.onPrimary, fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.north_east_rounded, size: 13, color: AppColors.onPrimary),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SimilarTile extends StatelessWidget {
  const _SimilarTile({
    required this.index,
    required this.isVideo,
    required this.bytes,
    required this.onTap,
  });

  final int index;
  final bool isVideo;
  final Uint8List? bytes;
  final VoidCallback? onTap;

  static const double _size = 72;

  @override
  Widget build(BuildContext context) {
    // Same index-based stagger as the initial four-tile loading row, so a tile whose own
    // thumbnail is still streaming in doesn't pulse in lockstep with its neighbours.
    if (bytes == null) return _ShimmerTile(index: index);

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: SizedBox(
          width: _size,
          height: _size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(bytes!, fit: BoxFit.cover, cacheWidth: (_size * 2).round()),
              if (isVideo)
                const Positioned(
                  right: 4,
                  bottom: 4,
                  child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 18),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A calm, endlessly sweeping placeholder for a tile whose thumbnail hasn't arrived yet - the
/// same "something is being developed" idea as the light-mode search grid's own loading tiles
/// (see search_results.dart's _LoadingTile), just a band of white light on dark glass instead of
/// pearl-on-parchment, to suit this tray instead of a bright canvas.
class _ShimmerTile extends StatefulWidget {
  const _ShimmerTile({this.index = 0});

  final int index;

  @override
  State<_ShimmerTile> createState() => _ShimmerTileState();
}

class _ShimmerTileState extends State<_ShimmerTile> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 1700));

  @override
  void initState() {
    super.initState();
    // Neighbouring tiles start at different points so the row doesn't pulse in lockstep - but
    // the value has to be set *before* repeat() starts, not after: AnimationController.value's
    // setter stops the controller as part of setting it, so doing this in the other order (as
    // it was) started the repeat and then immediately cancelled it again in the same frame,
    // which is exactly what "stuck, not animating" looks like.
    _sweep.value = (widget.index * 0.137) % 1;
    _sweep.repeat();
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Its own compositing layer - several of these can be ticking at once in the strip, each
    // independently, and none of that should force a repaint of the glass tray around them.
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: SizedBox(
          width: _SimilarTile._size,
          height: _SimilarTile._size,
          child: AnimatedBuilder(
            animation: _sweep,
            builder: (context, _) {
              final t = _sweep.value;
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(-2 + 4 * t, -1),
                    end: Alignment(-1 + 4 * t, 1),
                    colors: [
                      Colors.white.withValues(alpha: 0.05),
                      Colors.white.withValues(alpha: 0.17),
                      Colors.white.withValues(alpha: 0.05),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
