import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/model_status.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/model_download_screen.dart';
import 'package:twentyonevision/view/widget/confirm_dialog.dart';

/// A face picture, cut from its photo on demand (see FacesController.crop).
/// Round for avatars, or a rounded square for the review grid.
class FaceAvatar extends StatefulWidget {
  const FaceAvatar({
    super.key,
    required this.faceId,
    required this.size,
    this.square = false,
  });

  final int faceId;
  final double size;
  final bool square;

  @override
  State<FaceAvatar> createState() => _FaceAvatarState();
}

class _FaceAvatarState extends State<FaceAvatar> {
  final FacesController _controller = Get.find<FacesController>();
  Uint8List? _bytes;
  // The face this widget has asked the controller for and not yet been given.
  int? _holding;

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _release() {
    final held = _holding;
    if (held != null) {
      _controller.releaseCrop(held);
      _holding = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant FaceAvatar old) {
    super.didUpdateWidget(old);
    if (old.faceId != widget.faceId) _load();
  }

  void _load() {
    _release();
    final id = widget.faceId;
    final cached = _controller.cachedCrop(id);
    if (cached != null) {
      _bytes = cached;
      return;
    }

    // Not made yet: the picture already showing (the person's previous one) stays
    // until this one is ready, so a change is a fade, never a blank tile.
    _holding = id;
    _controller.crop(id).then((bytes) {
      if (_holding == id) _release();
      if (mounted && widget.faceId == id && bytes != null) setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final bytes = _bytes;
    final picture = bytes == null
        ? Container(
            key: const ValueKey('placeholder'),
            color: AppColors.parchment,
            alignment: Alignment.center,
            child: Icon(Icons.person_rounded, size: widget.size * 0.45, color: AppColors.hairline),
          )
        : Image.memory(
            bytes,
            key: ValueKey(bytes),
            fit: BoxFit.cover,
            cacheWidth: (widget.size * dpr).round(),
            gaplessPlayback: true,
          );
    // Cross-fades when the picture is swapped (stack that fills the tile, so
    // the pictures aren't left loose in it).
    final child = AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [...previous, if (current != null) current],
      ),
      child: picture,
    );

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: widget.square
          ? ClipRRect(borderRadius: BorderRadius.circular(AppRadius.md), child: child)
          : ClipOval(child: child),
    );
  }
}

/// One person in the people grid.
class PersonTile extends StatelessWidget {
  const PersonTile({
    super.key,
    required this.person,
    required this.onTap,
    this.onLongPress,
    this.selecting = false,
    this.selected = false,
  });

  final Person person;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  // While picking several people: every tile shows a tick circle; ticked ones
  // get a ring around the face.
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final named = person.name != null;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          children: [
            LayoutBuilder(
              builder: (context, box) {
                // Room for the selection ring (4 either side) inside the tile: the picture
                // plus ring must leave space for the name and count under it.
                final size = (box.maxWidth - 24).clamp(60.0, 112.0);
                return SizedBox(
                  width: size + 8,
                  height: size + 8,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: size + 8,
                        height: size + 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? AppColors.primary : Colors.transparent,
                            width: 3,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: AnimatedScale(
                            duration: const Duration(milliseconds: 160),
                            scale: selected ? 0.94 : 1,
                            child: FaceAvatar(faceId: person.coverFaceId, size: size),
                          ),
                        ),
                      ),
                      if (selecting)
                        Positioned(
                          right: 0,
                          top: 0,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: selected ? AppColors.primary : AppColors.canvas,
                              border: Border.all(
                                color: selected ? AppColors.primary : AppColors.hairline,
                                width: 1.5,
                              ),
                            ),
                            child: selected
                                ? const Icon(Icons.check_rounded, size: 16, color: AppColors.onPrimary)
                                : null,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              named ? person.name! : 'Add name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleSmall?.copyWith(color: named ? AppColors.ink : AppColors.ink48),
            ),
            const SizedBox(height: 1),
            Text(
              person.photoCount == 1 ? '1 photo' : '${person.photoCount} photos',
              style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
            ),
          ],
        ),
      ),
    );
  }
}

/// Live progress of the automatic face scan. The people found so far are
/// already usable underneath it.
class FaceScanCard extends StatelessWidget {
  const FaceScanCard({
    super.key,
    required this.status,
    required this.onPause,
    required this.onResume,
    this.photosPerSecond,
    this.eta,
  });

  final FaceStatus status;

  /// Current speed and time left, from the controller (null while unknown).
  final double? photosPerSecond;
  final Duration? eta;
  final VoidCallback onPause;
  final VoidCallback onResume;

  static String? _speed(double? perSecond, {bool videos = false}) {
    if (perSecond == null || perSecond <= 0) return null;
    final unit = videos ? 'videos' : 'photos';
    if (perSecond >= 1) return '${perSecond.toStringAsFixed(1)} $unit/s';
    return '${(perSecond * 60).round()} $unit/min';
  }

  static String _eta(Duration d) {
    if (d.inHours >= 1) return '${d.inHours} h ${d.inMinutes % 60} min left';
    if (d.inMinutes >= 1) return '${d.inMinutes} min left';
    return 'under a minute left';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final stopped = status.userPaused;
    final tuning = status.phase == 'tune';
    final refining = status.phase == 'refine';
    final videos = status.phase == 'videos';
    final title = stopped
        ? 'Face search paused'
        : status.paused
            ? 'Waiting for indexing to finish'
            : tuning
                ? 'Optimising for your phone'
                : refining
                    ? 'Refining small and blurry faces'
                    : videos
                        ? 'Finding faces in videos'
                        : 'Finding faces';
    final details = <String>[
      if (tuning && !stopped) 'One-time speed test, about a minute',
      if (!tuning && status.total > 0) '${status.processed} of ${status.total} ${videos ? 'videos' : 'photos'}',
      if (!tuning && status.faces > 0) '${status.faces} faces',
    ];
    // Speed and time left: only once there's a real reading, and not while stopped.
    final speed = _speed(photosPerSecond, videos: videos);
    if (!stopped && !tuning) {
      if (speed != null) details.add(speed);
      final left = eta;
      if (left != null) details.add(_eta(left));
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.base),
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.face_retouching_natural, size: 18, color: AppColors.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(title, style: textTheme.titleSmall)),
              if (status.fraction != null)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.xs),
                  child: Text(
                    '${(status.fraction! * 100).floor()}%',
                    style: textTheme.titleSmall?.copyWith(color: AppColors.primary),
                  ),
                ),
              // The user's control: stop the scan, or start it again.
              SizedBox(
                width: 36,
                height: 36,
                child: IconButton.filled(
                  padding: EdgeInsets.zero,
                  tooltip: stopped ? 'Resume' : 'Pause',
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
                  ),
                  icon: Icon(stopped ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 20),
                  onPressed: stopped ? onResume : onPause,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: (status.paused && !stopped) ? null : status.fraction,
              minHeight: 5,
              backgroundColor: AppColors.hairline,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            details.isEmpty ? 'Getting started...' : details.join('  ·  '),
            style: textTheme.bodySmall?.copyWith(color: AppColors.ink80),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            stopped
                ? 'Stopped. It stays stopped until you resume.'
                : refining
                    ? 'The clear faces are done - now the small ones are matched to the same people.'
                    : videos
                        ? 'Photos are done - now the videos, a few seconds each. It only looks at some frames of each.'
                        : 'People show up below as they are found. This runs by itself, on this device only.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.4),
          ),
        ],
      ),
    );
  }
}

/// Shown when the face recognition model isn't on the device: what it is, why
/// it is needed, and the download - same model system as the search models.
class NoFaceModelCard extends StatelessWidget {
  const NoFaceModelCard({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return GetBuilder<NativeController>(
      builder: (native) {
        final size = native.faceModelBytes;
        final downloading = native.isDownloadingModels;
        final progress = native.downloadProgress;

        return Container(
          padding: const EdgeInsets.all(AppSpacing.base),
          decoration: BoxDecoration(
            color: AppColors.parchment,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.face_retouching_natural, size: 20, color: AppColors.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text('Turn on People', style: textTheme.titleSmall)),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Grouping photos by who is in them needs a small face recognition model, '
                'downloaded once${size > 0 ? ' (${ModelDownloadProgress.formatBytes(size)})' : ''}. '
                'It runs entirely on this phone: nothing is uploaded, and it works offline afterwards.',
                style: textTheme.bodySmall?.copyWith(color: AppColors.ink80, height: 1.45),
              ),
              if (native.downloadError.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  native.downloadError,
                  style: textTheme.bodySmall?.copyWith(color: AppColors.danger, fontWeight: FontWeight.w600),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              if (downloading) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    value: progress.overallTotalBytes == 0 ? null : progress.overallFraction,
                    backgroundColor: AppColors.hairline,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  progress.overallTotalBytes == 0
                      ? 'Starting...'
                      : '${ModelDownloadProgress.formatBytes(progress.overallBytesDownloaded)} '
                          'of ${ModelDownloadProgress.formatBytes(progress.overallTotalBytes)}',
                  style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                ),
                const SizedBox(height: AppSpacing.sm),
                PillButton(label: 'Cancel', onTap: native.cancelModelDownload, outlined: true),
              ] else
                PillButton(
                  label: native.downloadError.isEmpty ? 'Download' : 'Retry download',
                  icon: native.downloadError.isEmpty ? Icons.download_rounded : Icons.refresh_rounded,
                  onTap: () => native.startModelDownload(onlyFaces: true),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ---- sheets and dialogs ----

class SheetRow extends StatelessWidget {
  const SheetRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.danger = false,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool danger;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final color = danger ? AppColors.danger : AppColors.ink;
    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.md),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: textTheme.bodyMedium?.copyWith(color: color)),
                    if (subtitle != null)
                      Text(subtitle!, style: textTheme.bodySmall?.copyWith(color: AppColors.ink48)),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

/// A bottom sheet in the app's style: a rounded canvas card with a title.
Future<T?> showFacesSheet<T>(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
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
                  child: Text(title, style: Theme.of(context).textTheme.titleSmall),
                ),
                const Divider(height: 1, color: AppColors.hairline),
                Flexible(child: builder(sheetContext)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Confirms and performs a merge; the person with a name (else the one in more
/// photos) is the one that stays.
void confirmMerge(BuildContext context, FacesController faces, {required Person keep, required Person other}) {
  final keepIsA = keep.name != null || (other.name == null && keep.photoCount >= other.photoCount);
  final winner = keepIsA ? keep : other;
  final loser = keepIsA ? other : keep;
  showConfirmDialog(
    context,
    title: 'Merge these two?',
    message: '${loser.name ?? 'This person'} will be treated as the same person as '
        '${winner.name ?? 'the other'}, and their photos combined.',
    confirmLabel: 'Merge',
    onConfirm: () => faces.merge(keep: winner, other: loser),
  );
}

/// Asks for a name. Returns the text (empty means "remove the name"), or null if cancelled.
Future<String?> showRenamePersonDialog(BuildContext context, String? current) {
  final field = TextEditingController(text: current ?? '');
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.canvas,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      insetPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              current == null ? 'Who is this?' : 'Rename',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: field,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
              decoration: InputDecoration(
                hintText: 'Name',
                filled: true,
                fillColor: AppColors.parchment,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(field.text.trim()),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
