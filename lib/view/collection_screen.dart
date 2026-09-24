import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/collections_controller.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/collection_widgets.dart';
import 'package:twentyonevision/view/widget/search_results.dart';

// One collection's members - the same tiles and viewers as search results,
// with the collection as the header instead of a search bar.
class CollectionScreen extends StatefulWidget {
  const CollectionScreen({super.key});

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  late final CollectionsController _collections =
      Get.find<CollectionsController>();

  @override
  void dispose() {
    _collections.closeCollection();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GetBuilder<CollectionsController>(
      builder: (collections) {
        final collection = collections.active;
        final native = Get.find<NativeController>();
        final textTheme = Theme.of(context).textTheme;

        if (collection == null) {
          // Deleted from its own menu - nothing left to show, so leave.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          });
          return const Scaffold(
            backgroundColor: AppColors.canvas,
            body: SizedBox.shrink(),
          );
        }

        final members = collections.members;

        return Scaffold(
          backgroundColor: AppColors.canvas,
          body: SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm,
                      AppSpacing.xs,
                      AppSpacing.sm,
                      0,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            size: 18,
                            color: AppColors.ink,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(
                            Icons.more_horiz_rounded,
                            color: AppColors.ink,
                          ),
                          onPressed: () => showCollectionMenu(
                            context,
                            collection,
                            collections,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    0,
                    AppSpacing.xl,
                    AppSpacing.base,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.parchment,
                            borderRadius: BorderRadius.circular(AppRadius.lg),
                          ),
                          child: collections.coverFor(collection.id) == null
                              ? Icon(collection.icon, color: AppColors.ink48)
                              : ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.lg,
                                  ),
                                  child: Image.memory(
                                    collections.coverFor(collection.id)!,
                                    width: 52,
                                    height: 52,
                                    fit: BoxFit.cover,
                                    cacheWidth: 156,
                                    cacheHeight: 156,
                                  ),
                                ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                collection.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.titleLarge,
                              ),
                              Text(
                                collections.isLoadingMembers
                                    ? 'Finding matches...'
                                    : _subtitle(
                                        collections,
                                        collection.queryText,
                                        members.length,
                                      ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodySmall?.copyWith(
                                  color: AppColors.ink48,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (collections.isLoadingMembers)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    ),
                  )
                else if (members.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xxl),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            collection.icon,
                            size: 40,
                            color: AppColors.ink48,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            'Nothing here yet',
                            style: textTheme.titleMedium,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            'Nothing indexed matches "${collection.queryText}" so far. Scan more of your library and this fills in on its own.',
                            textAlign: TextAlign.center,
                            style: textTheme.bodySmall?.copyWith(
                              color: AppColors.ink48,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl,
                    ),
                    sliver: collectionResultsGrid(
                      controller: native,
                      results: members,
                      bytesFor: (item) =>
                          collections.memberThumbs[collections.memberKey(item)],
                      // A photo collection has no words to explain a match by.
                      matchQuery: collection.isPhotos
                          ? ''
                          : collection.queryText,
                      loading: collections.isLoadingThumbs,
                    ),
                  ),
                const SliverToBoxAdapter(
                  child: SizedBox(height: AppSpacing.xl),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _subtitle(CollectionsController collections, String query, int count) {
    final items = count == 1 ? '1 item' : '$count items';
    final active = collections.active!;
    if (active.isBuiltIn) return items;
    if (active.isPhotos) return '$items · like a photo you saved';
    return '$items · "$query"';
  }
}
