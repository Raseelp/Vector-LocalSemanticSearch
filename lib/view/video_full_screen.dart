import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/meta_data_model.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/draggable_metadata_sheet.dart';
import 'package:twentyonevision/view/widget/match_strength_bars.dart';
import 'package:twentyonevision/view/widget/media_actions_sheet.dart';
import 'package:twentyonevision/view/widget/media_chrome_button.dart';
import 'package:twentyonevision/view/widget/media_info_widgets.dart';
import 'package:video_player/video_player.dart';

class VideoViewScreen extends StatefulWidget {
  const VideoViewScreen({
    super.key,
    required this.videoUri,
    required this.timestampMs,
    required this.thumbnailBytes,
  });

  final String videoUri;
  final int timestampMs;

  final Uint8List thumbnailBytes;

  @override
  State<VideoViewScreen> createState() => _VideoViewScreenState();
}

class _VideoViewScreenState extends State<VideoViewScreen> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _showControls = true;
  bool _pickingFrame = false;

  String? _initError;

  @override
  void initState() {
    super.initState();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _controller = VideoPlayerController.contentUri(Uri.parse(widget.videoUri));

    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;

          _controller.seekTo(Duration(milliseconds: widget.timestampMs));
          _controller.play();

          setState(() {
            _initialized = true;
          });
        })
        .catchError((Object e) {
          if (!mounted) return;
          setState(() {
            _initError = "Couldn't play this video.";
          });
        });

    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _controller.dispose();
    super.dispose();
  }

  void _toggleControls() {
    // Hiding the scrubber mid-pick would strand the user with a hint about
    // something they can no longer see.
    if (_pickingFrame) return;
    setState(() {
      _showControls = !_showControls;
    });
  }

  // "Search with this" for video: unlike a photo there's no single image to
  // use, so this pauses and turns the playback bar into a proper scrubber -
  // the user picks whichever moment they want, then confirms. See
  // _confirmFrameSearch.
  void _enterFramePicking(NativeController nativeController) {
    nativeController.hideMetadata();
    _controller.pause();
    setState(() {
      _pickingFrame = true;
      _showControls = true;
    });
  }

  void _cancelFramePicking() {
    setState(() => _pickingFrame = false);
  }

  void _confirmFrameSearch(NativeController nativeController) {
    final positionMs = _controller.value.position.inMilliseconds;
    // All the way back to the home screen (this may have been opened from
    // inside a collection, not straight from the results), on the Search
    // tab, then search - not awaited, the results grid shows its own
    // loading state.
    Navigator.of(context).popUntil((route) => route.isFirst);
    nativeController.searchWithVideoFrame(uri: widget.videoUri, timestampMs: positionMs);
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final ready = _initialized && _initError == null;

    // Only wraps the chrome in a reactive builder - the player itself
    // (_controller, _initialized, _showControls) still lives entirely in
    // this State's own setState calls, untouched, just like before.
    return GetBuilder<NativeController>(
      builder: (nativeController) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: kMediaOverlayStyle,
        child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onTap: _toggleControls,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: ready
                        ? AspectRatio(
                            aspectRatio: _controller.value.aspectRatio,
                            child: VideoPlayer(_controller),
                          )
                        : Image.memory(widget.thumbnailBytes, fit: BoxFit.contain),
                  ),

                  if (!_initialized && _initError == null)
                    const Center(child: CircularProgressIndicator(color: Colors.white)),

                  if (_initError != null)
                    Center(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(AppRadius.xl),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              color: Colors.white70,
                              size: 36,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              _initError!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  if (_showControls)
                    AnimatedOpacity(
                      opacity: _showControls ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        decoration: ready
                            ? BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: 0.6),
                                    Colors.transparent,
                                    Colors.transparent,
                                    Colors.black.withValues(alpha: 0.7),
                                  ],
                                ),
                              )
                            : null,
                        child: Column(
                          children: [
                            SafeArea(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.sm,
                                  vertical: AppSpacing.xs,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    MediaChromeButton(
                                      icon: Icons.close,
                                      tooltip: 'Close',
                                      onTap: () => Navigator.of(context).pop(),
                                    ),
                                    Row(
                                      children: [
                                        MediaChromeButton(
                                          icon: _pickingFrame
                                              ? Icons.image_search
                                              : Icons.image_search_rounded,
                                          tooltip: _pickingFrame
                                              ? 'Cancel frame search'
                                              : 'Search with a frame from this video',
                                          onTap: () => _pickingFrame
                                              ? _cancelFramePicking()
                                              : _enterFramePicking(nativeController),
                                        ),
                                        const SizedBox(width: AppSpacing.sm),
                                        MediaChromeButton(
                                          icon: Icons.ios_share_rounded,
                                          tooltip: 'Share and save',
                                          onTap: () => showMediaActionsSheet(
                                            context,
                                            uri: widget.videoUri,
                                            isVideo: true,
                                            controller: nativeController,
                                          ),
                                        ),
                                        const SizedBox(width: AppSpacing.sm),
                                        MediaChromeButton(
                                          icon: nativeController.showMetadata
                                              ? Icons.info
                                              : Icons.info_outline,
                                          tooltip: 'Details',
                                          onTap: nativeController.toggleMetadata,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            if (_pickingFrame) const _FramePickHint(),

                            const Spacer(),

                            if (ready && _pickingFrame)
                              _FramePickBar(
                                controller: _controller,
                                formatDuration: _formatDuration,
                                onCancel: _cancelFramePicking,
                                onSearch: () => _confirmFrameSearch(nativeController),
                              ),

                            if (ready && !_pickingFrame)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  AppSpacing.base,
                                  0,
                                  AppSpacing.base,
                                  AppSpacing.xxl,
                                ),
                                child: Column(
                                  children: [
                                    VideoProgressIndicator(
                                      _controller,
                                      allowScrubbing: true,
                                      colors: const VideoProgressColors(
                                        playedColor: AppColors.primary,
                                        bufferedColor: Colors.white38,
                                        backgroundColor: Colors.white24,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: AppSpacing.sm,
                                      ),
                                    ),

                                    Row(
                                      children: [
                                        IconButton(
                                          icon: Icon(
                                            _controller.value.isPlaying
                                                ? Icons.pause
                                                : Icons.play_arrow,
                                            color: Colors.white,
                                            size: 32,
                                          ),
                                          onPressed: () {
                                            _controller.value.isPlaying
                                                ? _controller.pause()
                                                : _controller.play();
                                          },
                                        ),
                                        const SizedBox(width: AppSpacing.sm),
                                        Text(
                                          _formatDuration(_controller.value.position),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13,
                                          ),
                                        ),
                                        const Text(
                                          ' / ',
                                          style: TextStyle(color: Colors.white54, fontSize: 13),
                                        ),
                                        Text(
                                          _formatDuration(_controller.value.duration),
                                          style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

            DraggableMetadataSheet(
              visible: nativeController.showMetadata,
              onDismissed: nativeController.hideMetadata,
              heightFactor: 0.5,
              child: _VideoMetadataContent(
                metadata: nativeController.selectedMetadata,
                isLoading: nativeController.isFetchingMetadata,
                matchExplanation: nativeController.matchExplanation,
                matchedFrameBytes: widget.thumbnailBytes,
                matchedTimestampMs: widget.timestampMs,
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

// Tells the user what the mode they just entered is for - without it, a
// paused video and a slightly different bar wouldn't say anything about
// searching.
class _FramePickHint extends StatelessWidget {
  const _FramePickHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swipe_rounded, color: Colors.white, size: 16),
            SizedBox(width: AppSpacing.sm),
            Text(
              'Drag the bar to any moment, then search it',
              style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

// The playback bar while picking a frame: a real Slider with a big thumb
// (unlike the thin, thumbless bar normally shown), so it reads as
// draggable at a glance, seeking live so the frame on screen is the frame
// that gets searched.
class _FramePickBar extends StatefulWidget {
  const _FramePickBar({
    required this.controller,
    required this.formatDuration,
    required this.onCancel,
    required this.onSearch,
  });

  final VideoPlayerController controller;
  final String Function(Duration) formatDuration;
  final VoidCallback onCancel;
  final VoidCallback onSearch;

  @override
  State<_FramePickBar> createState() => _FramePickBarState();
}

class _FramePickBarState extends State<_FramePickBar> {
  // Seeking on every drag event floods the player with requests it can't
  // keep up with (the picture lags behind the thumb); this lets one through
  // every ~90ms while dragging and always lands exactly on release.
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  void _seek(double v, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastSeek) < const Duration(milliseconds: 90)) return;
    _lastSeek = now;
    widget.controller.seekTo(Duration(milliseconds: v.round()));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final formatDuration = widget.formatDuration;
    final onCancel = widget.onCancel;
    final onSearch = widget.onSearch;
    final durationMs = controller.value.duration.inMilliseconds;
    final positionMs = controller.value.position.inMilliseconds.clamp(0, durationMs > 0 ? durationMs : 1);

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.base, 0, AppSpacing.base, AppSpacing.xxl),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              activeTrackColor: AppColors.primary,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 11),
              overlayColor: AppColors.primary.withValues(alpha: 0.25),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
            ),
            child: Slider(
              min: 0,
              max: durationMs > 0 ? durationMs.toDouble() : 1,
              value: positionMs.toDouble(),
              onChanged: _seek,
              onChangeEnd: (v) => _seek(v, force: true),
            ),
          ),
          Row(
            children: [
              TextButton(
                onPressed: onCancel,
                child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
              ),
              const Spacer(),
              Text(
                formatDuration(controller.value.position),
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const Spacer(),
              InkWell(
                onTap: onSearch,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.base,
                    vertical: AppSpacing.md,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.image_search_rounded, color: AppColors.onPrimary, size: 18),
                      SizedBox(width: AppSpacing.sm),
                      Text(
                        'Search this frame',
                        style: TextStyle(
                          color: AppColors.onPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VideoMetadataContent extends StatelessWidget {
  const _VideoMetadataContent({
    required this.metadata,
    required this.isLoading,
    required this.matchExplanation,
    required this.matchedFrameBytes,
    required this.matchedTimestampMs,
  });

  final ImageMetadata metadata;
  final bool isLoading;
  final List<MapEntry<String, double>> matchExplanation;
  final Uint8List matchedFrameBytes;
  final int matchedTimestampMs;

  String _formatTimestamp(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Absent unless this was actually opened from a text search
          // result - same guard as the image viewer.
          if (matchExplanation.isNotEmpty) ...[
            const InfoGroupLabel('Why this matched'),
            const SizedBox(height: AppSpacing.sm),
            _MatchedFrameRow(
              bytes: matchedFrameBytes,
              label: 'Matched at ${_formatTimestamp(matchedTimestampMs)}',
            ),
            const SizedBox(height: AppSpacing.base),
            MatchStrengthBars(entries: matchExplanation),
            const SizedBox(height: AppSpacing.xl),
          ],
          const InfoGroupLabel('File information'),
          const SizedBox(height: AppSpacing.sm),
          InfoGroupCard(
            children: [
              InfoRow(
                icon: Icons.videocam_outlined,
                label: 'File name',
                value: metadata.fileName.isNotEmpty ? metadata.fileName : 'Unknown',
              ),
              InfoRow(
                icon: Icons.folder_outlined,
                label: 'File path',
                value: metadata.imagePath.isNotEmpty ? metadata.imagePath : 'Unknown',
              ),
              if (metadata.durationMs > 0)
                InfoRow(
                  icon: Icons.timer_outlined,
                  label: 'Duration',
                  value: metadata.durationFormatted,
                ),
              InfoRow(
                icon: Icons.straighten_rounded,
                label: 'Resolution',
                value: metadata.resolution,
              ),
              InfoRow(
                icon: Icons.storage_rounded,
                label: 'File size',
                value: metadata.fileSizeFormatted,
              ),
              InfoRow(
                icon: Icons.type_specimen_outlined,
                label: 'Format',
                value: metadata.mimeType.split('/').last.toUpperCase(),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }
}

// A small preview of the exact frame CLIP matched, not just the words that
// matched it - the same information the search grid's thumbnail already
// used (see search_results.dart), just surfaced here too so "why this
// matched" reads as concretely as the image viewer's does.
class _MatchedFrameRow extends StatelessWidget {
  const _MatchedFrameRow({required this.bytes, required this.label});

  final Uint8List bytes;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Image.memory(bytes, width: 56, height: 56, fit: BoxFit.cover),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.ink48, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
