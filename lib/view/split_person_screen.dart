import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/model_download_screen.dart' show PillButton;
import 'package:twentyonevision/view/widget/face_widgets.dart';

/// For a person who is really two people: shows the two groups their faces fall
/// into, side by side, and splits them if you say so. The bigger group stays with
/// the person; the smaller becomes a new person (rename either afterwards).
class SplitPersonScreen extends StatefulWidget {
  const SplitPersonScreen({super.key, required this.person});

  final Person person;

  @override
  State<SplitPersonScreen> createState() => _SplitPersonScreenState();
}

class _SplitPersonScreenState extends State<SplitPersonScreen> {
  final FacesController _faces = Get.find<FacesController>();
  SplitPreview? _preview;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    SplitPreview? preview;
    try {
      preview = await _faces.previewSplit(widget.person);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _preview = preview;
        _loaded = true;
      });
    }
  }

  Future<void> _split(SplitPreview preview) async {
    setState(() => _busy = true);
    await _faces.splitPerson(widget.person, preview.second);
    if (!mounted) return;
    Navigator.of(context).pop();
    Get.closeAllSnackbars();
    Get.snackbar(
      'Split into two people',
      'Give each a name from their page.',
      duration: const Duration(seconds: 5),
      snackPosition: SnackPosition.BOTTOM,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 110),
      backgroundColor: AppColors.ink,
      colorText: Colors.white,
      borderRadius: 14,
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final preview = _preview;
    final name = widget.person.name ?? 'this person';

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.canvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('Split into two people', style: textTheme.titleMedium),
      ),
      body: SafeArea(
        child: !_loaded
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : preview == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xxl),
                      child: Text(
                        'There are not enough clear faces of $name to tell two groups apart. '
                        'Use "Review faces" to take out any that are someone else.',
                        textAlign: TextAlign.center,
                        style: textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.45),
                      ),
                    ),
                  )
                : Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.base),
                          children: [
                            Text(
                              'Vector found two groups among the faces of $name. If they are two different '
                              'people, split them.',
                              style: textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.45),
                            ),
                            const SizedBox(height: AppSpacing.base),
                            _Group(
                              title: 'Stays as $name',
                              count: preview.first.length,
                              covers: preview.firstCovers,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            _Group(
                              title: 'Becomes a new person',
                              count: preview.second.length,
                              covers: preview.secondCovers,
                              highlight: true,
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _busy
                                ? const Padding(
                                    padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                                  )
                                : PillButton(
                                    label: 'Split into two people',
                                    icon: Icons.call_split_rounded,
                                    onTap: () => _split(preview),
                                  ),
                            const SizedBox(height: AppSpacing.sm),
                            TextButton(
                              onPressed: _busy ? null : () => Navigator.of(context).pop(),
                              child: const Text('They are the same person'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.count, required this.covers, this.highlight = false});

  final String title;
  final int count;
  final List<int> covers;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.base),
      decoration: BoxDecoration(
        color: highlight ? AppColors.primary.withValues(alpha: 0.07) : AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: highlight ? Border.all(color: AppColors.primary.withValues(alpha: 0.3)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: textTheme.titleSmall)),
              Text('$count faces', style: textTheme.bodySmall?.copyWith(color: AppColors.ink48)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [for (final id in covers) FaceAvatar(faceId: id, size: 56, square: true)],
          ),
        ],
      ),
    );
  }
}
