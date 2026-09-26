import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/face_review_screen.dart';
import 'package:twentyonevision/view/split_person_screen.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';

/// Everything you can do with one person, in one menu - the same list whether it
/// was opened by holding a face in the People tab or by the dots on the person's
/// own page.
void showPersonMenu(
  BuildContext context,
  FacesController faces,
  Person person,
) {
  showFacesSheet<void>(
    context,
    title: person.name ?? 'This person',
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SheetRow(
          icon: Icons.edit_outlined,
          label: person.name == null ? 'Add a name' : 'Rename',
          onTap: () async {
            Navigator.of(sheet).pop();
            final name = await showRenamePersonDialog(context, person.name);
            if (name != null) faces.rename(person, name);
          },
        ),
        const Divider(height: 1, color: AppColors.dividerSoft),
        SheetRow(
          icon: Icons.groups_rounded,
          label: 'Find photos with someone else',
          subtitle: 'Together, or just the two of them',
          onTap: () {
            Navigator.of(sheet).pop();
            // To the People tab, in "choose people" mode with this one ticked
            // (from a person's own page that means going back to it first).
            Navigator.of(context).popUntil((route) => route.isFirst);
            Get.find<NativeController>().setHomeTab(3);
            faces.startSelecting(person);
          },
        ),
        const Divider(height: 1, color: AppColors.dividerSoft),
        SheetRow(
          icon: Icons.merge_type_rounded,
          label: 'Same person as someone else',
          subtitle: 'Merge with another person',
          onTap: () {
            Navigator.of(sheet).pop();
            showMergePicker(context, faces, person);
          },
        ),
        const Divider(height: 1, color: AppColors.dividerSoft),
        SheetRow(
          icon: Icons.call_split_rounded,
          label: 'Split into two people',
          subtitle: 'If two different people were mixed up',
          onTap: () {
            Navigator.of(sheet).pop();
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SplitPersonScreen(person: person)),
            );
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
              MaterialPageRoute(
                builder: (_) => FaceReviewScreen(person: person),
              ),
            );
          },
        ),
        const Divider(height: 1, color: AppColors.dividerSoft),
        SheetRow(
          icon: Icons.visibility_off_outlined,
          label: 'Hide this person',
          onTap: () {
            Navigator.of(sheet).pop();
            faces.setHidden(person, true);
          },
        ),
      ],
    ),
  );
}

/// Everyone else, the likeliest matches first; tapping one asks to confirm the merge.
void showMergePicker(
  BuildContext context,
  FacesController faces,
  Person person,
) {
  final others = faces.people.where((p) => p.id != person.id).toList()
    ..sort((x, y) {
      final sx = faces.suggestionScoreFor(person, x) ?? -1;
      final sy = faces.suggestionScoreFor(person, y) ?? -1;
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
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: AppColors.dividerSoft),
            itemBuilder: (_, i) {
              final other = others[i];
              final suggested = faces.suggestionScoreFor(person, other) != null;
              return InkWell(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                onTap: () {
                  Navigator.of(sheet).pop();
                  confirmMerge(context, faces, keep: person, other: other);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.base,
                    vertical: AppSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      FaceAvatar(faceId: other.coverFaceId, size: 44),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Text(
                          other.name ??
                              'Unnamed  ·  ${other.photoCount} photos',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      if (suggested)
                        Text(
                          'Looks similar',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppColors.primary),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
  );
}
