import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/face_review_screen.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';
import 'package:twentyonevision/view/widget/search_results.dart';

/// One person: their face, name, and every photo they're in - the same tiles
/// and viewers as search results and collections.
class PersonScreen extends StatefulWidget {
  const PersonScreen({super.key, required this.person});

  final Person person;

  @override
  State<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends State<PersonScreen> {
  late final FacesController _faces = Get.find<FacesController>();

  @override
  void initState() {
    super.initState();
    // After the first frame: opening notifies listeners, which can't happen mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _faces.openPerson(widget.person));
  }

  @override
  void dispose() {
    _faces.closePerson();
    super.dispose();
  }

  Future<void> _rename(Person person) async {
    final name = await showRenamePersonDialog(context, person.name);
    if (name != null) _faces.rename(person, name);
  }

  void _menu(Person person) {
    showFacesSheet<void>(
      context,
      title: person.name ?? 'This person',
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetRow(
            icon: Icons.edit_outlined,
            label: person.name == null ? 'Add a name' : 'Rename',
            onTap: () {
              Navigator.of(sheet).pop();
              _rename(person);
            },
          ),
          const Divider(height: 1, color: AppColors.dividerSoft),
          SheetRow(
            icon: Icons.merge_type_rounded,
            label: 'Same person as someone else',
            subtitle: 'Merge with another person',
            onTap: () {
              Navigator.of(sheet).pop();
              _pickMerge(person);
            },
          ),
          const Divider(height: 1, color: AppColors.dividerSoft),
          SheetRow(
            icon: Icons.grid_view_rounded,
            label: 'Review faces',
            subtitle: 'Take out faces that are someone else',
            onTap: () {
              Navigator.of(sheet).pop();
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => FaceReviewScreen(person: person)),
              );
            },
          ),
          const Divider(height: 1, color: AppColors.dividerSoft),
          SheetRow(
            icon: Icons.visibility_off_outlined,
            label: 'Hide this person',
            onTap: () {
              Navigator.of(sheet).pop();
              _faces.setHidden(person, true);
            },
          ),
        ],
      ),
    );
  }

  // Everyone else, the likeliest matches first.
  void _pickMerge(Person person) {
    final others = _faces.people.where((p) => p.id != person.id).toList()
      ..sort((x, y) {
        final sx = _faces.suggestionScoreFor(person, x) ?? -1;
        final sy = _faces.suggestionScoreFor(person, y) ?? -1;
        if (sx != sy) return sy.compareTo(sx);
        return y.photoCount.compareTo(x.photoCount);
      });

    showFacesSheet<void>(
      context,
      title: 'Merge ${person.name ?? 'this person'} with...',
      builder: (sheet) => others.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: Text('There is nobody else to merge with yet.'),
            )
          : ListView.separated(
              shrinkWrap: true,
              itemCount: others.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.dividerSoft),
              itemBuilder: (_, i) {
                final other = others[i];
                final suggested = _faces.suggestionScoreFor(person, other) != null;
                return InkWell(
                  onTap: () {
                    Navigator.of(sheet).pop();
                    confirmMerge(context, _faces, keep: person, other: other);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.sm),
                    child: Row(
                      children: [
                        FaceAvatar(faceId: other.coverFaceId, size: 44),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Text(
                            other.name ?? 'Unnamed  ·  ${other.photoCount} photos',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        if (suggested)
                          Text(
                            'Looks similar',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.primary),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GetBuilder<FacesController>(
      builder: (faces) {
        final person = faces.active;
        final native = Get.find<NativeController>();
        final textTheme = Theme.of(context).textTheme;

        // Not opened yet (first frame) - show the header from what we were given.
        final shown = person ?? widget.person;

        // Hidden or merged away from here: nothing left to show, so leave.
        if (person == null && faces.photos.isEmpty && !faces.isLoadingPhotos && _opened) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
          });
        }
        if (person != null) _opened = true;

        return Scaffold(
          backgroundColor: AppColors.canvas,
          body: SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.xs, AppSpacing.sm, 0),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: AppColors.ink),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.more_horiz_rounded, color: AppColors.ink),
                          onPressed: () => _menu(shown),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      FaceAvatar(faceId: shown.coverFaceId, size: 104),
                      const SizedBox(height: AppSpacing.md),
                      InkWell(
                        onTap: () => _rename(shown),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                shown.name ?? 'Add a name',
                                style: shown.name != null
                                    ? textTheme.titleLarge
                                    : textTheme.titleLarge?.copyWith(color: AppColors.ink48),
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              const Icon(Icons.edit_outlined, size: 16, color: AppColors.ink48),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        shown.photoCount == 1 ? '1 photo' : '${shown.photoCount} photos',
                        style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                    ],
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                  sliver: collectionResultsGrid(
                    controller: native,
                    results: faces.photos,
                    bytesFor: (item) => faces.photoThumbs[item['path'] as String],
                    matchQuery: '',
                    loading: faces.isLoadingThumbs,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _opened = false;
}
