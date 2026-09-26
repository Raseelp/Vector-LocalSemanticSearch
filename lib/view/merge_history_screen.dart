import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/confirm_dialog.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';

/// Merges you made, newest first, each with an Undo: the person that was folded
/// in comes back with their name and faces, and the two are remembered as
/// different people so they are never suggested (or merged) together again.
class MergeHistoryScreen extends StatefulWidget {
  const MergeHistoryScreen({super.key});

  @override
  State<MergeHistoryScreen> createState() => _MergeHistoryScreenState();
}

class _MergeHistoryScreenState extends State<MergeHistoryScreen> {
  final FacesController _faces = Get.find<FacesController>();
  List<MergeRecord>? _records;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await _faces.mergeHistory();
    if (mounted) setState(() => _records = records);
  }

  static String _ago(int millis) {
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(millis));
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} h ago';
    if (diff.inDays == 1) return 'yesterday';
    return '${diff.inDays} days ago';
  }

  void _confirmUndo(MergeRecord record) {
    showConfirmDialog(
      context,
      title: 'Undo this merge?',
      message: '${record.removedName ?? 'They'} will be a separate person again, with their own faces. '
          'The two will not be suggested as the same person.',
      confirmLabel: 'Undo merge',
      onConfirm: () async {
        await _faces.undoMerge(record.id);
        await _load();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final records = _records;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.canvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('Undo a merge', style: textTheme.titleMedium),
      ),
      body: SafeArea(
        child: records == null
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : records.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xxl),
                      child: Text(
                        'No merges to undo. When you merge two people, it shows up here so it can be reversed.',
                        textAlign: TextAlign.center,
                        style: textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.45),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.xxl),
                    itemCount: records.length,
                    separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.md),
                    itemBuilder: (context, i) {
                      final r = records[i];
                      return Container(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          color: AppColors.parchment,
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                        ),
                        child: Row(
                          children: [
                            _Avatar(faceId: r.keptCover),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4),
                              child: Icon(Icons.add_rounded, size: 16, color: AppColors.ink48),
                            ),
                            _Avatar(faceId: r.removedCover),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${r.keptName ?? 'Unnamed'} + ${r.removedName ?? 'Unnamed'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${r.faceCount} faces  ·  ${_ago(r.createdAt)}',
                                    style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                                  ),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: () => _confirmUndo(r),
                              child: const Text('Undo'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

// A face, or a plain circle if the picture isn't available any more.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.faceId});

  final int? faceId;

  @override
  Widget build(BuildContext context) {
    final id = faceId;
    if (id == null) {
      return Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(color: AppColors.canvas, shape: BoxShape.circle),
        child: const Icon(Icons.person_rounded, size: 22, color: AppColors.hairline),
      );
    }
    return FaceAvatar(faceId: id, size: 44);
  }
}
