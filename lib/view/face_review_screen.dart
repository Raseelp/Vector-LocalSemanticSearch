import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';

/// Every face grouped under one person, so the wrong ones can be taken out.
/// Faint faces (small, blurry or turned away) are marked - they're the ones
/// most likely to be wrong.
class FaceReviewScreen extends StatefulWidget {
  const FaceReviewScreen({super.key, required this.person});

  final Person person;

  @override
  State<FaceReviewScreen> createState() => _FaceReviewScreenState();
}

class _FaceReviewScreenState extends State<FaceReviewScreen> {
  final FacesController _faces = Get.find<FacesController>();
  List<PersonFace>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await _faces.facesOf(widget.person);
    if (mounted) setState(() => _items = items);
  }

  Future<void> _remove(PersonFace face) async {
    // Gone from the grid at once; the edit happens behind it.
    setState(() => _items = _items!.where((f) => f.faceId != face.faceId).toList());
    await _faces.removeFace(face);
  }

  void _confirm(PersonFace face) {
    final name = widget.person.name ?? 'this person';
    showFacesSheet<void>(
      context,
      title: 'This face',
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.base),
            child: FaceAvatar(faceId: face.faceId, size: 140, square: true),
          ),
          SheetRow(
            icon: Icons.person_remove_outlined,
            label: 'Not $name',
            subtitle: 'Take it out of this group',
            danger: true,
            onTap: () {
              Navigator.of(sheet).pop();
              _remove(face);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final items = _items;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.canvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('Review faces', style: textTheme.titleMedium),
      ),
      body: SafeArea(
        child: items == null
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.md),
                    child: Text(
                      'Tap a face that is not ${widget.person.name ?? 'this person'} to take it out.',
                      style: textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.4),
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xl),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: AppSpacing.xs,
                        crossAxisSpacing: AppSpacing.xs,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final face = items[i];
                        return GestureDetector(
                          onTap: () => _confirm(face),
                          child: LayoutBuilder(
                            builder: (context, box) => Stack(
                              children: [
                                FaceAvatar(faceId: face.faceId, size: box.maxWidth, square: true),
                                if (!face.good)
                                  Positioned(
                                    right: 4,
                                    top: 4,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.55),
                                        borderRadius: BorderRadius.circular(AppRadius.pill),
                                      ),
                                      child: const Text(
                                        'faint',
                                        style: TextStyle(color: Colors.white, fontSize: 9),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
