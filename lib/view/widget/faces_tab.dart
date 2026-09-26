import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/utils/floating_bar.dart';
import 'package:twentyonevision/view/merge_suggestions_screen.dart';
import 'package:twentyonevision/view/person_screen.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';
import 'package:twentyonevision/view/widget/faces_options_sheet.dart';
import 'package:twentyonevision/view/widget/person_menu.dart';

/// The Faces tab: the people found in your photos. The face scan runs by
/// itself (no button) - a progress card shows how far it is, and people appear
/// in the grid as soon as they are found.
class FacesTab extends StatelessWidget {
  const FacesTab({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<FacesController>(
      builder: (faces) {
        final status = faces.status;
        final textTheme = Theme.of(context).textTheme;
        // Shown while it runs, and while it is stopped by the user with photos left.
        final scanning =
            status.error == null &&
            (status.running || (status.userPaused && status.remaining > 0));
        final noModel = !status.ready || status.error == 'no_model';

        final selecting = faces.selecting;
        // Only people still in the list (one may have been hidden or merged since).
        final chosen = faces.selectedPeople.length;

        final scroll = CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                AppSpacing.xs,
                AppSpacing.md,
                0,
              ),
              sliver: SliverToBoxAdapter(
                child: selecting
                    ? Row(
                        children: [
                          Expanded(
                            child: Text(
                              chosen == 0 ? 'Choose people' : '$chosen chosen',
                              style: textTheme.titleMedium,
                            ),
                          ),
                          TextButton(
                            onPressed: faces.stopSelecting,
                            child: const Text('Cancel'),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: Text(
                              faces.people.isEmpty
                                  ? 'People'
                                  : 'People  ·  ${faces.people.length}',
                              style: textTheme.titleMedium,
                            ),
                          ),
                          // Finding photos by several people needs at least two to pick from.
                          if (faces.people.length >= 2)
                            TextButton.icon(
                              onPressed: faces.startSelecting,
                              icon: const Icon(Icons.groups_rounded, size: 18),
                              label: const Text('Find together'),
                            ),
                          IconButton(
                            tooltip: 'Face options',
                            icon: const Icon(
                              Icons.tune_rounded,
                              size: 22,
                              color: AppColors.ink,
                            ),
                            onPressed: () => showFacesOptionsSheet(context),
                          ),
                        ],
                      ),
              ),
            ),
            if (noModel)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.sm,
                  AppSpacing.xl,
                  0,
                ),
                sliver: const SliverToBoxAdapter(child: NoFaceModelCard()),
              )
            else if (scanning)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.sm,
                  AppSpacing.xl,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: FaceScanCard(
                    status: status,
                    onPause: faces.pauseScan,
                    onResume: faces.resumeScan,
                    photosPerSecond: faces.scanRate,
                    eta: faces.scanEta,
                  ),
                ),
              ),
            if (faces.suggestions.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.md,
                  AppSpacing.xl,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: _SuggestionsBanner(count: faces.suggestions.length),
                ),
              ),
            if (faces.people.isEmpty)
              SliverToBoxAdapter(
                child: _EmptyState(
                  status: status,
                  loading: faces.isLoadingPeople,
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.base,
                  AppSpacing.lg,
                  0,
                ),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: AppSpacing.md,
                    crossAxisSpacing: AppSpacing.xs,
                    childAspectRatio: 0.74,
                  ),
                  delegate: SliverChildBuilderDelegate((context, i) {
                    final person = faces.people[i];
                    return PersonTile(
                      key: ValueKey(person.id),
                      person: person,
                      selecting: selecting,
                      selected: faces.selectedIds.contains(person.id),
                      onTap: selecting
                          ? () => faces.toggleSelected(person)
                          : () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => PersonScreen(person: person),
                              ),
                            ),
                      onLongPress: selecting
                          ? null
                          : () => showPersonMenu(context, faces, person),
                    );
                  }, childCount: faces.people.length),
                ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(height: floatingBarClearance(context)),
            ),
          ],
        );

        return scroll;
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.status, required this.loading});

  final FaceStatus status;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final String message;
    if (loading) {
      message = '';
    } else if (!status.ready) {
      message = '';
    } else if (status.running) {
      message =
          'Nobody yet. People appear here as soon as the same face turns up in two photos.';
    } else if (status.total == 0) {
      message =
          'Index your photos first (Library tab). Faces are found in the photos Vector has indexed.';
    } else {
      message =
          'No people found yet. A person shows up once their face appears in at least two photos.';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xxl,
        AppSpacing.xxxl,
        AppSpacing.xxl,
        0,
      ),
      child: Column(
        children: [
          const Icon(
            Icons.face_retouching_natural,
            size: 40,
            color: AppColors.hairline,
          ),
          const SizedBox(height: AppSpacing.md),
          if (message.isNotEmpty)
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(
                color: AppColors.ink48,
                height: 1.45,
              ),
            ),
        ],
      ),
    );
  }
}

/// A nudge when some people may be the same person (see MergeSuggestionsScreen).
class _SuggestionsBanner extends StatelessWidget {
  const _SuggestionsBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const MergeSuggestionsScreen())),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.base,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: AppColors.parchment,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.merge_type_rounded,
              size: 20,
              color: AppColors.primary,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                count == 1
                    ? '1 pair may be the same person'
                    : '$count pairs may be the same person',
                style: textTheme.bodyMedium,
              ),
            ),
            Text(
              'Review',
              style: textTheme.titleSmall?.copyWith(color: AppColors.primary),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.primary),
          ],
        ),
      ),
    );
  }
}
