import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/hidden_people_screen.dart';
import 'package:twentyonevision/view/merge_history_screen.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';

/// Options for the Faces tab: whether videos are scanned, and the maintenance actions.
///
/// The models are listed in Settings. The expert controls - grouping strictness, the second pass
/// for small and blurry faces, "search harder for small faces", the speed test, regrouping and the
/// model picker - are not shown: their defaults give the best results. They all still exist (in
/// [FacesController] and on the phone); [_expertRows] below is the whole set of controls, ready
/// to be put back into the list if they are ever needed.
Future<void> showFacesOptionsSheet(BuildContext context) {
  return showFacesSheet<void>(
    context,
    title: 'Face options',
    builder: (_) => const _OptionsBody(),
  );
}

class _OptionsBody extends StatelessWidget {
  const _OptionsBody();

  @override
  Widget build(BuildContext context) {
    final faces = Get.find<FacesController>();
    final textTheme = Theme.of(context).textTheme;

    return GetBuilder<FacesController>(
      builder: (_) {
        final status = faces.status;

        return ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
              title: Text('Find people in videos', style: textTheme.bodyMedium),
              subtitle: Text(
                'After the photos, a few frames of each video are checked. Takes a while and uses battery. '
                'Turned off, you can still scan any single video from its own screen.',
                style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
              ),
              value: status.scanVideos,
              onChanged: (v) => faces.setScanVideos(v),
            ),
            if (status.scanVideos)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.base, 0, AppSpacing.base, AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 'fast', label: Text('Fast')),
                          ButtonSegment(value: 'balanced', label: Text('Balanced')),
                          ButtonSegment(value: 'thorough', label: Text('Thorough')),
                        ],
                        selected: {status.videoDensity},
                        onSelectionChanged: (s) => faces.setVideoDensity(s.first),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'How many frames of each video are checked. Applies to videos not scanned yet - '
                      '"Clear face data" in Settings redoes the rest.',
                      style: textTheme.bodySmall?.copyWith(color: AppColors.ink48, fontSize: 11, height: 1.4),
                    ),
                  ],
                ),
              ),
            const Divider(height: 1, color: AppColors.dividerSoft),
            SheetRow(
              icon: Icons.undo_rounded,
              label: 'Undo a merge',
              subtitle: 'Split two people you merged by mistake',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MergeHistoryScreen()));
              },
            ),
            const Divider(height: 1, color: AppColors.dividerSoft),
            SheetRow(
              icon: Icons.visibility_off_outlined,
              label: 'Hidden people',
              subtitle: faces.hiddenPeople.isEmpty ? 'None' : '${faces.hiddenPeople.length} hidden',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HiddenPeopleScreen()));
              },
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------------------------
  // The controls that are not shown (their defaults are the best settings). Everything they call
  // still works: FacesController.setStrictness / setRefine / setThorough / retune / regroup /
  // models / selectModel. To bring any back, add these rows to the list above, e.g.
  //   ..._expertRows(context, faces, status, models)
  // ---------------------------------------------------------------------------------------------

  // ignore: unused_element
  List<Widget> _expertRows(BuildContext context, FacesController faces, FaceStatus status, FaceModels? models) {
    final textTheme = Theme.of(context).textTheme;

    Widget chips(String kind) {
      final list = models?.ofKind(kind) ?? const <FaceModelInfo>[];
      if (list.isEmpty) {
        return Text('none installed', style: textTheme.bodySmall?.copyWith(color: AppColors.danger));
      }
      return Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          for (final m in list)
            ChoiceChip(
              label: Text('${m.name}  ${(m.sizeBytes / 1048576).toStringAsFixed(0)} MB'),
              selected: m.selected,
              onSelected: (_) => faces.selectModel(m),
            ),
        ],
      );
    }

    return [
      // Sorts the automatic groups again from every face known now (names and hand edits are kept).
      SheetRow(
        icon: Icons.auto_fix_high_rounded,
        label: 'Regroup now',
        subtitle: 'Sorts the faces into people again. Names and your edits are kept',
        onTap: () {
          Navigator.of(context).pop();
          faces.regroup();
        },
      ),
      // Models (the detector and the recognition model).
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.base, AppSpacing.base, AppSpacing.base, AppSpacing.xs),
        child: Text('Models', style: textTheme.labelMedium?.copyWith(color: AppColors.ink48)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Finds faces', style: textTheme.bodySmall),
            const SizedBox(height: AppSpacing.xs),
            chips('detector'),
            const SizedBox(height: AppSpacing.md),
            Text('Tells people apart', style: textTheme.bodySmall),
            const SizedBox(height: AppSpacing.xs),
            chips('embedder'),
          ],
        ),
      ),
      // How strict the grouping is (applied by "Regroup now").
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.base, AppSpacing.base, AppSpacing.base, AppSpacing.xs),
        child: Text('Grouping', style: textTheme.labelMedium?.copyWith(color: AppColors.ink48)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
        child: SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'strict', label: Text('Strict')),
              ButtonSegment(value: 'balanced', label: Text('Balanced')),
              ButtonSegment(value: 'loose', label: Text('Loose')),
            ],
            selected: {status.strictness},
            onSelectionChanged: (s) => faces.setStrictness(s.first),
          ),
        ),
      ),
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
        title: Text('Recognise small and blurry faces', style: textTheme.bodyMedium),
        subtitle: Text(
          'A second pass after the clear faces are done, matching the rest to the same people.',
          style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
        ),
        value: status.refine,
        onChanged: (v) => faces.setRefine(v),
      ),
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
        title: Text('Search harder for small faces', style: textTheme.bodyMedium),
        subtitle: Text(
          'Slower. Applies to photos scanned from now on.',
          style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
        ),
        value: status.thorough,
        onChanged: (v) => faces.setThorough(v),
      ),
      SheetRow(
        icon: Icons.speed_rounded,
        label: 'Speed test',
        subtitle: status.tuning ?? 'Runs once, at the start of the next scan',
        onTap: () {
          Navigator.of(context).pop();
          faces.retune();
        },
      ),
    ];
  }
}
