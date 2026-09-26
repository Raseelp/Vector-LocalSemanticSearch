import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/hidden_people_screen.dart';
import 'package:twentyonevision/view/widget/confirm_dialog.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';

/// Options for face grouping: which models run, how strict grouping is, and
/// the maintenance actions.
Future<void> showFacesOptionsSheet(BuildContext context) {
  return showFacesSheet<void>(
    context,
    title: 'Face options',
    builder: (_) => const _OptionsBody(),
  );
}

class _OptionsBody extends StatefulWidget {
  const _OptionsBody();

  @override
  State<_OptionsBody> createState() => _OptionsBodyState();
}

class _OptionsBodyState extends State<_OptionsBody> {
  final FacesController _faces = Get.find<FacesController>();
  FaceModels? _models;

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  Future<void> _loadModels() async {
    try {
      final models = await _faces.models();
      if (mounted) setState(() => _models = models);
    } catch (_) {}
  }

  void _chooseModel(FaceModelInfo model) {
    if (model.selected) return;
    // The detector is safe to swap (a rescan isn't forced); a different
    // recognition model makes every stored face unusable, so it restarts the
    // grouping - which loses names - and asks first.
    if (model.kind == 'detector') {
      _faces.selectModel(model).then((_) => _loadModels());
      return;
    }
    showConfirmDialog(
      context,
      title: 'Switch recognition model?',
      message:
          'Faces are compared using this model, so everything is grouped again from scratch. '
          'Names you gave will be lost.',
      confirmLabel: 'Switch',
      onConfirm: () => _faces.selectModel(model).then((_) => _loadModels()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return GetBuilder<FacesController>(
      builder: (faces) {
        final status = faces.status;
        final models = _models;

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
                  onSelected: (_) => _chooseModel(m),
                ),
            ],
          );
        }

        return ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
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
                  if (models != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'To try another model, copy its .onnx file into ${models.dir} and reopen this.',
                      style: textTheme.bodySmall?.copyWith(color: AppColors.ink48, fontSize: 11, height: 1.4),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            const Divider(height: 1, color: AppColors.hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.base, AppSpacing.base, AppSpacing.base, AppSpacing.xs),
              child: Text('Grouping', style: textTheme.labelMedium?.copyWith(color: AppColors.ink48)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'strict', label: Text('Strict')),
                        ButtonSegment(value: 'balanced', label: Text('Balanced')),
                        ButtonSegment(value: 'loose', label: Text('Loose')),
                      ],
                      selected: {status.strictness},
                      onSelectionChanged: (s) => _faces.setStrictness(s.first),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Strict keeps look-alikes apart but may split one person in two. '
                    'Loose joins more, but may mix people up. Regroup to apply.',
                    style: textTheme.bodySmall?.copyWith(color: AppColors.ink48, fontSize: 11, height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SheetRow(
              icon: Icons.auto_fix_high_rounded,
              label: 'Regroup now',
              subtitle: 'Names and your edits are kept',
              onTap: () {
                Navigator.of(context).pop();
                _faces.regroup();
              },
            ),
            const Divider(height: 1, color: AppColors.dividerSoft),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
              title: Text('Recognise small and blurry faces', style: textTheme.bodyMedium),
              subtitle: Text(
                'A second pass after the clear faces are done, matching the rest to the same people. '
                'Turn off to finish sooner - those faces just won\'t be matched.',
                style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
              ),
              value: status.refine,
              onChanged: (v) => _faces.setRefine(v),
            ),
            const Divider(height: 1, color: AppColors.dividerSoft),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
              title: Text('Search harder for small faces', style: textTheme.bodyMedium),
              subtitle: Text(
                'Slower. Applies to photos scanned from now on - use "Scan again" for older ones.',
                style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
              ),
              value: status.thorough,
              onChanged: (v) => _faces.setThorough(v),
            ),
            const Divider(height: 1, color: AppColors.dividerSoft),
            SheetRow(
              icon: Icons.speed_rounded,
              label: 'Speed test',
              subtitle: status.tuning ?? 'Runs once, at the start of the next scan',
              onTap: () {
                Navigator.of(context).pop();
                _faces.retune();
              },
            ),
            const Divider(height: 1, color: AppColors.dividerSoft),
            SheetRow(
              icon: Icons.visibility_off_outlined,
              label: 'Hidden people',
              subtitle: _faces.hiddenPeople.isEmpty ? 'None' : '${_faces.hiddenPeople.length} hidden',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HiddenPeopleScreen()));
              },
            ),
            const Divider(height: 1, color: AppColors.dividerSoft),
            SheetRow(
              icon: Icons.restart_alt_rounded,
              label: 'Scan all photos again',
              subtitle: 'Forgets every group and name, then starts over',
              danger: true,
              onTap: () => showConfirmDialog(
                context,
                title: 'Scan everything again?',
                message: 'All groups and the names you gave will be removed, and every photo is searched for faces again.',
                confirmLabel: 'Scan again',
                onConfirm: () {
                  Navigator.of(context).pop();
                  _faces.rescanEverything();
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
