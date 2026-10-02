import 'package:flutter/material.dart';
import 'package:twentyonevision/controllers/collections_controller.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/collection_model.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/utils/floating_bar.dart';
import 'package:twentyonevision/view/collection_screen.dart';
import 'package:twentyonevision/view/widget/collection_widgets.dart';

/// Opens [collection] - shared by the tab's cards and the Search tab's chips.
void openCollectionScreen(
  BuildContext context,
  CollectionsController controller,
  SmartCollection collection,
) {
  controller.openCollection(collection);
  Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => const CollectionScreen()));
}

// The full grid: the user's own collections first, then the built-ins that
// aren't hidden. Long-press a card to edit/hide/delete.
class CollectionsTab extends StatelessWidget {
  const CollectionsTab({
    super.key,
    required this.controller,
    required this.native,
  });

  final CollectionsController controller;
  final NativeController native;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final nothingIndexed = native.totalEmbeddings == 0;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            0,
            AppSpacing.xl,
            AppSpacing.base,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nothingIndexed
                      ? 'Collections fill in once something is indexed.'
                      : 'Saved searches that stay up to date as you scan. Long-press one to edit it.',
                  style: textTheme.bodySmall?.copyWith(
                    color: AppColors.ink48,
                    height: 1.4,
                  ),
                ),
                if (controller.isScoring) ...[
                  const SizedBox(height: AppSpacing.md),
                  _ScoringProgress(controller: controller),
                ],
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: AppSpacing.md,
              mainAxisSpacing: AppSpacing.md,
              childAspectRatio: 1.05,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              if (index == 0) {
                return NewCollectionCard(onTap: () => _createNew(context));
              }
              final collection = controller.visible[index - 1];
              final stats = controller.statsFor(collection.id);
              return CollectionCard(
                collection: collection,
                stats: stats,
                coverBytes: controller.coverFor(collection.id),
                syncing: controller.syncing.contains(collection.id),
                onTap: () =>
                    openCollectionScreen(context, controller, collection),
                onLongPress: () =>
                    showCollectionMenu(context, collection, controller),
              );
            }, childCount: controller.visible.length + 1),
          ),
        ),
        if (controller.hiddenCollections.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                AppSpacing.lg,
                AppSpacing.xl,
                0,
              ),
              child: Row(
                children: [
                  Text(
                    '${controller.hiddenCollections.length} hidden',
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.ink48,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  InkWell(
                    onTap: controller.unhideAll,
                    child: Text(
                      'Restore',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(child: SizedBox(height: floatingBarClearance(context))),
      ],
    );
  }

  void _createNew(BuildContext context) {
    showSaveCollectionSheet(
      context,
      title: 'New collection',
      showQuery: true,
      // Stays on the tab: the new card appears at the top and plays its own
      // "finding matches" animation - opening it straight away would hide that.
      onSave: (name, query, personIds) => controller.createCollection(
        name: name,
        query: query,
        personIds: personIds,
      ),
    );
  }
}

// Shown while collections are being (re)scored. The first pass also has to
// embed every collection's prompts, which is the slow part - that gets a
// real "x of y"; after that it's just a quick refresh.
class _ScoringProgress extends StatelessWidget {
  const _ScoringProgress({required this.controller});

  final CollectionsController controller;

  @override
  Widget build(BuildContext context) {
    final settingUp = controller.setupTotal > 0;
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
          Text(
            settingUp
                ? 'Getting collections ready  ·  ${controller.setupDone} of ${controller.setupTotal}'
                : 'Updating collections',
            style: textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            settingUp
                ? 'A one-time setup - it only takes a moment and you can keep using the app.'
                : 'Counting what matches each one.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
          ),
          const SizedBox(height: AppSpacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              minHeight: 4,
              value: settingUp
                  ? controller.setupDone / controller.setupTotal
                  : null,
              backgroundColor: AppColors.hairline,
              color: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}
