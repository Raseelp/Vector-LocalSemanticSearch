import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/utils/media_view_route.dart';
import 'package:twentyonevision/view/image_full_screen.dart';
import 'package:twentyonevision/view/video_full_screen.dart';

// Higher decode caps requested only for a bento tile big enough to need
// them (see _bentoUpgradeDimension), instead of raising the cap every tile
// shares. Three tiers, roughly matching how much bigger than a plain 1-cell
// tile each one is: a 2-cell tile (the wide/tall filler tiles next to a
// hero or showcase) needs only a small bump, the 4-cell 2x2 hero a bit
// more, the 8/16-slot showcases a lot more. These values are just what
// Dart happens to pass as the "maxDimension" channel argument -
// MainActivity.kt accepts any value, but its
// MAX_COMPRESSED_DIMENSION_WIDE/_HERO/_SHOWCASE constants document what to
// expect here, so keep them in sync.
const int _wideThumbnailMaxDimension = 1900;
const int _heroThumbnailMaxDimension = 2200;
const int _showcaseThumbnailMaxDimension = 3200;

// The bento layout is built from small, independently-verified "movements" -
// each one a short run of tiles that, on its own, ends with every column at
// the same height (checked with a standalone packing simulation copied from
// flutter_staggered_grid_view's own algorithm, not just eyeballed). Because
// concatenating two flush movements is always itself flush, any sequence of
// these can be chained with zero gaps or overlaps, in any order, any number
// of times - which is what lets the generator below splice rare showcase
// movements into the steady rhythm without ever risking a broken layout.
const int _bentoCrossAxisCount = 4;

// Steady rhythm: hero square on the left, a denser no-hero row, hero square
// on the right - the regular backbone of the mosaic.
const List<QuiltedGridTile> _movementHeroLeft = [
  QuiltedGridTile(2, 2),
  QuiltedGridTile(1, 1),
  QuiltedGridTile(1, 1),
  QuiltedGridTile(1, 2),
];
const List<QuiltedGridTile> _movementNoHero = [
  QuiltedGridTile(1, 1),
  QuiltedGridTile(2, 1),
  QuiltedGridTile(1, 1),
  QuiltedGridTile(1, 1),
  QuiltedGridTile(1, 1),
  QuiltedGridTile(1, 2),
];
const List<QuiltedGridTile> _movementHeroRight = [
  QuiltedGridTile(1, 1),
  QuiltedGridTile(1, 1),
  QuiltedGridTile(2, 2),
  QuiltedGridTile(1, 2),
];
const List<List<QuiltedGridTile>> _steadyRotation = [
  _movementHeroLeft,
  _movementNoHero,
  _movementHeroRight,
];

// Rare showcase movements - one full-bleed photo taking up far more room
// than usual, spliced sparingly into the steady rhythm by
// _generateBentoPattern below rather than appearing on a fixed schedule.
const List<QuiltedGridTile> _showcaseHorizontal = [
  QuiltedGridTile(2, 4), // one photo, full width, 2 rows = 8 cells
];
const List<QuiltedGridTile> _showcaseVerticalLeft = [
  QuiltedGridTile(4, 2), // tall hero, left half, 4 rows = 8 cells
  QuiltedGridTile(2, 2),
  QuiltedGridTile(2, 2),
];
const List<QuiltedGridTile> _showcaseVerticalRight = [
  QuiltedGridTile(2, 2), // filler placed first so it's strictly ahead,
  QuiltedGridTile(4, 2), // forcing the tall hero to land on the right half
  QuiltedGridTile(2, 2), // catch-up filler that re-flushes the left side
];
const List<List<QuiltedGridTile>> _showcaseOptions = [
  _showcaseHorizontal,
  _showcaseVerticalLeft,
  _showcaseVerticalRight,
];
const List<QuiltedGridTile> _showcaseGiant = [
  QuiltedGridTile(4, 4), // one photo, full width, 4 rows = 16 cells
];

// The normal grid-tile thumbnail cap (MainActivity.kt's
// MAX_COMPRESSED_DIMENSION) is tuned for a small tile, so a bento tile
// bigger than that needs more source resolution to still look sharp -
// how much more scales with how much bigger the tile actually is. Returns
// null for anything 1 cell/2 cells (no upgrade needed), the hero cap for
// the 4-cell 2x2 hero, and the showcase cap for the 8/16-slot tiles. See
// _ResultTile.upgradeMaxDimension.
int? _bentoUpgradeDimension(QuiltedGridTile tile) {
  final area = tile.mainAxisCount * tile.crossAxisCount;
  if (area >= 8) return _showcaseThumbnailMaxDimension;
  if (area >= 4) return _heroThumbnailMaxDimension;
  if (area >= 2) return _wideThumbnailMaxDimension;
  return null;
}

// The 14-tile/6-row steady cycle, used as-is for the loading skeleton (which
// has no real result count to gate showcase rarity against - see
// _SearchSkeletonGrid.build()). Real result grids use the generator below
// instead, which is showcase-aware and sized exactly to the result count.
const List<QuiltedGridTile> _bentoPattern = [
  ..._movementHeroLeft,
  ..._movementNoHero,
  ..._movementHeroRight,
];

// How many full pattern cycles the loading skeleton renders, to comfortably
// overshoot any real screen height - see _SearchSkeletonGrid.build().
const int _bentoSkeletonCycles = 4;

SliverQuiltedGridDelegate _bentoGridDelegate() {
  return SliverQuiltedGridDelegate(
    crossAxisCount: _bentoCrossAxisCount,
    pattern: _bentoPattern,
    repeatPattern: QuiltedGridRepeatPattern.inverted,
    mainAxisSpacing: AppSpacing.sm,
    crossAxisSpacing: AppSpacing.sm,
  );
}

// A showcase can't be considered at all until the list has enough room left
// to stay a small minority of the content - this is what keeps a short
// result set (a small collection, a person with few photos) from being
// dominated by one giant tile. The giant tile needs an even larger runway
// and a wider gap from the last showcase, so it reads as rarer than the
// 8-slot ones, as requested.
//
// The base chances (0.15/0.04) were tuned up by a 2.5x factor after testing
// on a real device via a temporary Settings slider - settled here as the
// final values, so the slider (and the multiplier plumbing) was removed.
const int _showcaseMinRemainingItems = 20;
const int _showcaseMinMovementGap = 3;
const double _showcaseChance = 0.375;
const int _giantMinRemainingItems = 40;
const int _giantMinMovementGap = 6;
const double _giantChance = 0.1;

// Builds a one-off pattern sized to exactly `resultCount` items (or as close
// as a whole number of movements allows - see the tail fallback in
// _ResultsSliverGrid.build), sprinkling rare showcase movements into the
// steady hero-left/no-hero/hero-right rotation instead of using one fixed
// pattern for every list. `seed` must be stable across rebuilds of the same
// result set (the same search or the same collection re-rendering while its
// thumbnails stream in) or the mosaic would visibly reshuffle mid-load -
// callers should derive it from something that only changes when the
// results themselves change, not from a fresh Random() per build().
List<QuiltedGridTile> _generateBentoPattern({
  required int resultCount,
  required int seed,
}) {
  final rng = Random(seed);
  final pattern = <QuiltedGridTile>[];
  var steadyIndex = 0;
  var movementsSinceShowcase = _showcaseMinMovementGap;
  var movementsSinceGiant = _giantMinMovementGap;

  while (true) {
    final remaining = resultCount - pattern.length;
    final giantEligible = remaining >= _giantMinRemainingItems &&
        movementsSinceGiant >= _giantMinMovementGap;
    final showcaseEligible = remaining >= _showcaseMinRemainingItems &&
        movementsSinceShowcase >= _showcaseMinMovementGap;

    List<QuiltedGridTile> next;
    var isShowcase = false;
    var isGiant = false;

    if (giantEligible && rng.nextDouble() < _giantChance) {
      next = _showcaseGiant;
      isShowcase = true;
      isGiant = true;
    } else if (showcaseEligible && rng.nextDouble() < _showcaseChance) {
      next = _showcaseOptions[rng.nextInt(_showcaseOptions.length)];
      isShowcase = true;
    } else {
      next = _steadyRotation[steadyIndex % _steadyRotation.length];
      steadyIndex++;
    }

    // Doesn't fit without leaving a partial movement (which can't be flush
    // by definition) - stop here and let the caller's uniform-grid tail
    // finish off the remainder gracefully instead.
    if (pattern.length + next.length > resultCount) break;

    pattern.addAll(next);
    movementsSinceShowcase = isShowcase ? 0 : movementsSinceShowcase + 1;
    movementsSinceGiant = isGiant ? 0 : movementsSinceGiant + 1;
  }

  return pattern;
}

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
      case ResultsLayout.bento:
        // Unused - bento builds its own SliverQuiltedGridDelegate below
        // instead of the fixed-cross-axis-count one this getter feeds.
        return _bentoCrossAxisCount;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isList = layout == ResultsLayout.list;
    final isBento = layout == ResultsLayout.bento;
    // Bento's tiles are far from uniform in height (a hero is 4x a small
    // square), so the flat "12" tuned for the old same-size grids falls well
    // short of a screen's worth once cut off mid-pattern. A skeleton has no
    // real data to size itself against, so instead of guessing a pixel
    // height we just render several full pattern cycles - cheap, since
    // SliverChildBuilderDelegate only actually builds the ones that scroll
    // into view, and a little overscroll of shimmer tiles is harmless.
    final childCount = isBento
        ? _bentoPattern.length * _bentoSkeletonCycles
        : (isList ? 6 : 12);
    return SliverGrid(
      gridDelegate: isBento
          ? _bentoGridDelegate()
          : SliverGridDelegateWithFixedCrossAxisCount(
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
        childCount: childCount,
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
      case ResultsLayout.bento:
        // Unused - bento builds its own SliverQuiltedGridDelegate below
        // instead of the fixed-cross-axis-count one this getter feeds.
        return _bentoCrossAxisCount;
    }
  }

  // `upgradeMaxDimension` is only ever non-null for a bento hero/showcase
  // tile (see _bentoUpgradeDimension) - it tells _ResultTile to chase a
  // sharper thumbnail at that specific cap, since the normal cached [bytes]
  // below is decoded at a size tuned for an ordinary small grid cell.
  Widget _buildTile(BuildContext context, int index, {int? upgradeMaxDimension}) {
    final item = _results[index];
    final uri = item['path'] as String;
    final isVideo = item['isVideo'] as bool? ?? false;
    final timestampMs = (item['timestampMs'] as num?)?.toInt() ?? 0;
    final cacheKey = controller.cacheKeyForResult(item);
    final bytes = bytesFor != null
        ? bytesFor!(item)
        : controller.imageCache[cacheKey];

    // A permanent failure (never expected to arrive) just fades in as-is -
    // the deliberate reveal pacing below is about a photo actually loading,
    // not a missing one.
    if (bytes == null && !loading) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: KeyedSubtree(
          key: const ValueKey('missing'),
          child: ClipRRect(
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
          ),
        ),
      );
    }

    return _RevealGate(
      cacheKey: cacheKey,
      ready: bytes != null,
      placeholder: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: _LoadingTile(index: index, isVideo: isVideo),
      ),
      child: bytes == null
          ? const SizedBox.shrink()
          : _ResultTile(
              bytes: bytes,
              isVideo: isVideo,
              upgradeMaxDimension: upgradeMaxDimension,
              uri: uri,
              timestampMs: timestampMs,
              onTap: () {
                // A rapid double-tap otherwise pushes the viewer twice (the
                // second tap lands before the first push's transition even
                // starts) - once this tile's own route is no longer the one
                // on top, a further tap on it is a leftover from that same
                // gesture, not a fresh one.
                if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
                // Fire-and-forget, same as loadMetaDataByUri below - the
                // viewer picks it up reactively once it resolves rather
                // than navigation waiting on it.
                controller.loadMatchExplanation(
                  path: uri,
                  isVideo: isVideo,
                  timestampMs: timestampMs,
                  query: matchQuery,
                );
                controller.loadMetaDataByUri(uri: uri, isVideo: isVideo);
                if (isVideo) {
                  Navigator.of(context).push(
                    mediaViewRoute(
                      (_) => VideoViewScreen(
                        videoUri: uri,
                        timestampMs: timestampMs,
                        thumbnailBytes: bytes,
                      ),
                    ),
                  );
                } else {
                  // A collection's / person's grid holds small thumbnails,
                  // so the viewer loads the sharp photo itself; live search
                  // results are already viewer-sized.
                  Navigator.of(context).push(
                    mediaViewRoute(
                      (_) => ImageViewScreen(imageBytes: bytes, uri: uri, loadFullRes: bytesFor != null),
                    ),
                  );
                }
              },
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isList = controller.resultsLayout == ResultsLayout.list;
    final isBento = controller.resultsLayout == ResultsLayout.bento;

    if (!isBento) {
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _crossAxisCount,
          crossAxisSpacing: AppSpacing.sm,
          mainAxisSpacing: AppSpacing.sm,
          childAspectRatio: isList ? 1.7 : 0.86,
        ),
        delegate: SliverChildBuilderDelegate(
          _buildTile,
          childCount: _results.length,
        ),
      );
    }

    // A one-off pattern generated for exactly this list (see
    // _generateBentoPattern) - not a fixed block repeating forever, so
    // showcase placement stays irregular instead of falling into a visible
    // rhythm, and rare tiles only get considered once the list has enough
    // room to not be dominated by them. The seed is derived from data that's
    // stable across this list's own rebuilds (progressive thumbnail loading
    // doesn't change the result count or its first item) but changes for a
    // genuinely different search/collection, so the mosaic won't reshuffle
    // mid-load.
    final seed = Object.hash(
      _results.length,
      _results.isNotEmpty ? _results.first['path'] : null,
    );
    final pattern = _generateBentoPattern(
      resultCount: _results.length,
      seed: seed,
    );
    final bentoCount = pattern.length;
    final tailCount = _results.length - bentoCount;

    // The generator only ever produces whole movements, so whatever it
    // couldn't fit (a partial movement can't be flush - see its own doc)
    // finishes as a plain uniform row(s) instead of a half-formed mosaic
    // block.
    final slivers = <Widget>[
      if (bentoCount > 0)
        SliverGrid(
          gridDelegate: SliverQuiltedGridDelegate(
            crossAxisCount: _bentoCrossAxisCount,
            pattern: pattern,
            mainAxisSpacing: AppSpacing.sm,
            crossAxisSpacing: AppSpacing.sm,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildTile(
              context,
              index,
              upgradeMaxDimension: _bentoUpgradeDimension(pattern[index]),
            ),
            childCount: bentoCount,
          ),
        ),
      // SliverMainAxisGroup just stacks its slivers with no gap of its own -
      // each SliverGrid's mainAxisSpacing only applies between its own rows,
      // not between two different slivers, so without this the tail's first
      // row sits flush against the bento block's last row.
      if (bentoCount > 0 && tailCount > 0)
        SliverToBoxAdapter(child: SizedBox(height: AppSpacing.sm)),
      if (tailCount > 0)
        SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _bentoCrossAxisCount,
            crossAxisSpacing: AppSpacing.sm,
            mainAxisSpacing: AppSpacing.sm,
            childAspectRatio: 0.86,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, tailIndex) => _buildTile(context, bentoCount + tailIndex),
            childCount: tailCount,
          ),
        ),
    ];
    return SliverMainAxisGroup(slivers: slivers);
  }
}

// A cache key that has made it through this gate once stays revealed
// forever (in-memory only, cleared on app restart - purely cosmetic, never
// worth persisting). So scrolling a tile out of view and back, or any later
// rebuild while other tiles' thumbnails stream in, never replays the reveal
// for a photo the user has already been shown.
final Set<String> _revealedTileKeys = <String>{};

// However fast a photo's bytes actually arrive - even already sitting in
// memory on the very first frame - the placeholder stays up for at least
// this long the first time its cache key is shown, so a load always reads
// as a deliberate reveal rather than an instant, jarring pop-in. Paid once
// per cache key; see _revealedTileKeys.
const Duration _minimumRevealDelay = Duration(milliseconds: 450);

// Gates the placeholder -> real-content swap behind _minimumRevealDelay
// (first time only) and a plain crossfade (every time). The timer starts
// at mount, not at data-arrival, so slow-arriving bytes are never held up
// any further - it only ever adds a wait when the data was already there.
class _RevealGate extends StatefulWidget {
  const _RevealGate({
    required this.cacheKey,
    required this.ready,
    required this.placeholder,
    required this.child,
  });

  final String cacheKey;
  final bool ready;
  final Widget placeholder;
  final Widget child;

  @override
  State<_RevealGate> createState() => _RevealGateState();
}

class _RevealGateState extends State<_RevealGate> {
  bool _delayElapsed = false;

  @override
  void initState() {
    super.initState();
    _startOrSkipDelay();
  }

  @override
  void didUpdateWidget(_RevealGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different item can land in this same slot (a fresh search, or the
    // bento pattern reshuffling which index gets which tile) - only a
    // genuinely different cache key should re-arm the delay.
    if (oldWidget.cacheKey != widget.cacheKey) {
      _delayElapsed = false;
      _startOrSkipDelay();
    }
  }

  void _startOrSkipDelay() {
    if (_revealedTileKeys.contains(widget.cacheKey)) {
      _delayElapsed = true;
      return;
    }
    Future.delayed(_minimumRevealDelay, () {
      if (!mounted) return;
      setState(() => _delayElapsed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final reveal = widget.ready && _delayElapsed;
    if (reveal) _revealedTileKeys.add(widget.cacheKey);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: KeyedSubtree(
        key: ValueKey(reveal),
        child: reveal ? widget.child : widget.placeholder,
      ),
    );
  }
}

class _ResultTile extends StatefulWidget {
  const _ResultTile({
    required this.bytes,
    required this.isVideo,
    required this.onTap,
    this.upgradeMaxDimension,
    this.uri,
    this.timestampMs = 0,
  });

  final Uint8List bytes;
  final bool isVideo;
  final VoidCallback onTap;

  // Non-null only for a bento hero/showcase tile (see
  // _bentoUpgradeDimension) - [bytes] above is still the normal, cheap
  // grid-tile decode (arrives immediately so the tile never waits on this),
  // and this triggers a one-time background fetch of a sharper version at
  // that specific cap, crossfaded in once it lands, instead of raising the
  // shared per-tile cap that every other tile would also pay for.
  final int? upgradeMaxDimension;
  final String? uri;
  final int timestampMs;

  @override
  State<_ResultTile> createState() => _ResultTileState();
}

class _ResultTileState extends State<_ResultTile>
    with SingleTickerProviderStateMixin {
  Uint8List? _upgradedBytes;

  // Bumped every time _maybeUpgrade is (re)triggered - a result that lands
  // after a newer request has already started is from a superseded uri
  // (the same State can be reused for a different item at this grid index -
  // see didUpdateWidget) and must be dropped, not applied on top of the
  // tile that's now showing.
  int _upgradeRequestId = 0;

  // Plays once, the moment a sharper upgrade actually lands (see
  // _maybeUpgrade) - never touched for the vast majority of tiles that
  // have no upgrade at all, so it costs nothing anywhere but the rare
  // hero/showcase tile it's meant for. See the sheen/scale it drives in
  // build() below.
  late final AnimationController _focusReveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
  );

  @override
  void initState() {
    super.initState();
    _maybeUpgrade();
  }

  @override
  void dispose() {
    _focusReveal.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_ResultTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Uint8List has no structural equality, so this is an identity check -
    // the same cached bytes object coming through on a rebuild (thumbnails
    // for other tiles streaming in) correctly does nothing here; only a
    // genuinely different item landing in this slot re-triggers the fetch.
    if (oldWidget.bytes != widget.bytes || oldWidget.uri != widget.uri) {
      _upgradedBytes = null;
      _focusReveal.value = 0;
      _maybeUpgrade();
    }
  }

  Future<void> _maybeUpgrade() async {
    final maxDimension = widget.upgradeMaxDimension;
    if (maxDimension == null || widget.uri == null) return;
    final requestId = ++_upgradeRequestId;
    try {
      final upgraded = widget.isVideo
          ? await NativeServices().loadVideoThumbnail(
              uri: widget.uri!,
              timestampMs: widget.timestampMs,
              maxDimension: maxDimension,
            )
          : await NativeServices().loadImageBytes(
              uri: widget.uri!,
              isCompressed: true,
              maxDimension: maxDimension,
            );
      if (!mounted || requestId != _upgradeRequestId) return;
      setState(() => _upgradedBytes = upgraded);
      _focusReveal.forward(from: 0);
    } catch (_) {
      // The normal-res bytes already on screen are a perfectly fine
      // fallback - never worth surfacing an error for a missed sharpness
      // upgrade.
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeBytes = _upgradedBytes ?? widget.bytes;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: widget.onTap,
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
                  // Crossfades once _upgradedBytes lands (keyed by object
                  // identity, so this only fires for that one swap, not on
                  // every rebuild while _upgradedBytes stays the same).
                  //
                  // AnimatedSwitcher's default layoutBuilder stacks its
                  // children with StackFit.loose, not expand - Image.memory
                  // has no explicit width/height, so under loose constraints
                  // it fell back to the source's own intrinsic size instead
                  // of filling the tile, leaving a gap/border around every
                  // photo. The override below is the same StackFit.expand
                  // this Stack itself uses, just applied one level deeper.
                  //
                  // _focusReveal (see its own doc) layers a one-shot "coming
                  // into focus" cue on top of that crossfade: a soft diagonal
                  // sheen in the app's own accent tint sweeps across once,
                  // rising and fading back out rather than sitting on
                  // screen, paired with the sharper image settling in from
                  // a hair larger than its final size. Both are driven by
                  // the same controller so they read as one small gesture,
                  // not two separate effects, and both are complete no-ops
                  // (a plain crossfade, nothing drawn) for every tile that
                  // never gets an upgrade in the first place.
                  AnimatedBuilder(
                    animation: _focusReveal,
                    builder: (context, child) {
                      final t = _focusReveal.value;
                      final eased = Curves.easeOutCubic.transform(t);
                      final scale = 1.02 - 0.02 * eased;
                      // Bell-shaped, not linear: silent at both ends of the
                      // animation, briefly visible only in the middle of
                      // the sweep - a flourish that appears and dissolves
                      // rather than something that's merely there then gone.
                      final sheenStrength = sin(t * pi).clamp(0.0, 1.0);
                      return Transform.scale(
                        scale: scale,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            child!,
                            if (sheenStrength > 0.01)
                              IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment(-1.6 + 3.2 * t, -1),
                                      end: Alignment(-0.5 + 3.2 * t, 1),
                                      colors: [
                                        Colors.transparent,
                                        AppColors.primaryFocus.withValues(
                                          alpha: sheenStrength * 0.16,
                                        ),
                                        Colors.transparent,
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      switchInCurve: Curves.easeOut,
                      layoutBuilder: (currentChild, previousChildren) => Stack(
                        fit: StackFit.expand,
                        children: [
                          ...previousChildren,
                          if (currentChild != null) currentChild,
                        ],
                      ),
                      child: Image.memory(
                        activeBytes,
                        key: ValueKey(identityHashCode(activeBytes)),
                        fit: BoxFit.cover,
                        cacheWidth: cacheWidth,
                      ),
                    ),
                  ),
                  if (widget.isVideo)
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
    case ResultsLayout.bento:
      return Icons.dashboard_customize_rounded;
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
    case ResultsLayout.bento:
      return 'Bento - varied tile sizes';
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
