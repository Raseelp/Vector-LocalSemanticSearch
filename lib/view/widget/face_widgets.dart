import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
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
    _bytes = _controller.cachedCrop(id);
    if (_bytes != null) return;

    _holding = id;
    _controller.crop(id).then((bytes) {
      if (_holding == id) _release();
      if (mounted && widget.faceId == id && bytes != null) setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final child = _bytes == null
        ? Container(
            color: AppColors.parchment,
            alignment: Alignment.center,
            child: Icon(Icons.person_rounded, size: widget.size * 0.45, color: AppColors.hairline),
          )
        : Image.memory(
            _bytes!,
            fit: BoxFit.cover,
            cacheWidth: (widget.size * dpr).round(),
            gaplessPlayback: true,
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
  const PersonTile({super.key, required this.person, required this.onTap, this.onLongPress});

  final Person person;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

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
              builder: (context, box) => FaceAvatar(
                faceId: person.coverFaceId,
                size: (box.maxWidth - AppSpacing.md).clamp(64.0, 120.0),
              ),
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

  static String? _speed(double? perSecond) {
    if (perSecond == null || perSecond <= 0) return null;
    if (perSecond >= 1) return '${perSecond.toStringAsFixed(1)} photos/s';
    return '${(perSecond * 60).round()} photos/min';
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
    final title = stopped
        ? 'Face search paused'
        : status.paused
            ? 'Waiting for indexing to finish'
            : tuning
                ? 'Optimising for your phone'
                : refining
                    ? 'Refining small and blurry faces'
                    : 'Finding faces';
    final details = <String>[
      if (tuning && !stopped) 'One-time speed test, about a minute',
      if (!tuning && status.total > 0) '${status.processed} of ${status.total} photos',
      if (!tuning && status.faces > 0) '${status.faces} faces',
    ];
    // Speed and time left: only once there's a real reading, and not while stopped.
    final speed = _speed(photosPerSecond);
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
                    : 'People show up below as they are found. This runs by itself, on this device only.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.4),
          ),
        ],
      ),
    );
  }
}

/// Shown when no face recognition model is installed.
class NoFaceModelCard extends StatelessWidget {
  const NoFaceModelCard({super.key, required this.modelsDir});

  final String modelsDir;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.base),
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Face recognition model missing', style: textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Copy a recognition model (an .onnx file, e.g. w600k_r50.onnx) into:\n$modelsDir',
            style: textTheme.bodySmall?.copyWith(color: AppColors.ink80, height: 1.45),
          ),
        ],
      ),
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
