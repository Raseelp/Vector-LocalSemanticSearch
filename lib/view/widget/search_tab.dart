import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/collections_controller.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/view/person_screen.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';
import 'package:twentyonevision/view/widget/collection_widgets.dart';
import 'package:twentyonevision/view/widget/collections_tab.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/utils/floating_bar.dart';
import 'package:twentyonevision/view/widget/search_filter_sheet.dart';
import 'package:twentyonevision/view/widget/search_results.dart';

class SearchTab extends StatelessWidget {
  const SearchTab({
    super.key,
    required this.controller,
    required this.onSeeAllCollections,
  });

  final NativeController controller;

  // Switches the home screen to the Collections tab.
  final VoidCallback onSeeAllCollections;

  @override
  Widget build(BuildContext context) {
    final showResults =
        controller.isSearching ||
        controller.searchResults.isNotEmpty ||
        controller.error.isNotEmpty;
    final hasImage = controller.pickedSearchImageUri != null;

    // CustomScrollView, not SingleChildScrollView(child: Column(...)) -
    // the results grid needs to be a real sliver participating in this
    // one true scrollable to actually virtualize (see searchResultsSlivers'
    // doc); everything above it just rides along as a plain boxed sliver.
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            0,
            AppSpacing.xl,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SearchPill(controller: controller),
                if (!hasImage) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _ImageSearchAction(onTap: controller.pickSearchImage),
                ],
                const SizedBox(height: AppSpacing.lg),
                if (controller.isScanning)
                  _BackgroundIndexingNote(controller: controller),
              ],
            ),
          ),
        ),
        if (showResults)
          ...searchResultsSlivers(controller: controller)
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            sliver: SliverToBoxAdapter(
              child: Column(
                children: [
                  _CollectionChipRow(onSeeAll: onSeeAllCollections),
                  _PeopleRow(
                    onSeeAll: () {
                      // Same as tapping the People tab: show it, refreshed, with the scan going.
                      controller.setHomeTab(3);
                      final faces = Get.find<FacesController>();
                      faces.refreshAll();
                      faces.startScan();
                    },
                  ),
                  _SearchIdlePrompt(controller: controller),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(child: SizedBox(height: floatingBarClearance(context))),
      ],
    );
  }
}

// The search bar has two input modes - typed text, or an attached photo for
// a reverse-image search - and one explicit way to submit either. Picking a
// photo only attaches it (shown as a chip, same idea as an attachment
// preview above a chat message) - nothing runs until Search is pressed,
// exactly like typing text doesn't search until then either.
class _SearchPill extends StatelessWidget {
  const _SearchPill({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final hasImage = controller.pickedSearchImageUri != null;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        children: [
          if (hasImage) ...[
            Expanded(child: _AttachedImageChip(controller: controller)),
          ] else ...[
            const Icon(Icons.search_rounded, size: 19, color: AppColors.ink48),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: TextField(
                controller: controller.searchTextController,
                focusNode: controller.searchFocusNode,
                onTapOutside: (_) => FocusScope.of(context).unfocus(),
                onSubmitted: (_) => controller.runSearch(),
                textInputAction: TextInputAction.search,
                style: Theme.of(context).textTheme.bodyMedium,
                decoration: const InputDecoration(
                  hintText: 'Search your photos and videos',
                  hintStyle: TextStyle(color: AppColors.ink48),
                  border: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                ),
              ),
            ),
          ],
          const SizedBox(width: AppSpacing.sm),
          _FilterButton(controller: controller),
          _SaveCollectionButton(controller: controller),
          const SizedBox(width: AppSpacing.sm),
          _SearchSubmitButton(controller: controller),
        ],
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => showSearchFilterSheet(context, controller),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          child: const Icon(
            Icons.tune_rounded,
            size: 19,
            color: AppColors.ink80,
          ),
        ),
      ),
    );
  }
}

class _AttachedImageChip extends StatelessWidget {
  const _AttachedImageChip({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final bytes = controller.pickedSearchImageBytes;

    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: SizedBox(
            width: 32,
            height: 32,
            child: bytes == null
                ? const ColoredBox(color: AppColors.hairline)
                : Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    cacheWidth: 64,
                    cacheHeight: 64,
                  ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            'Matching this photo',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppColors.ink80),
          ),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: controller.clearPickedSearchImage,
          child: const Padding(
            padding: EdgeInsets.all(AppSpacing.xs),
            child: Icon(Icons.close_rounded, size: 17, color: AppColors.ink48),
          ),
        ),
      ],
    );
  }
}

// A live listener on the text field, not just a GetX rebuild - typing
// doesn't call update(), so without this the button's enabled state would
// only refresh whenever something unrelated happened to rebuild the screen.
class _SearchSubmitButton extends StatelessWidget {
  const _SearchSubmitButton({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.searchTextController,
      builder: (context, _) {
        final enabled =
            controller.pickedSearchImageUri != null ||
            controller.searchTextController.text.trim().isNotEmpty;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? controller.runSearch : null,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: enabled ? AppColors.primary : AppColors.hairline,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.arrow_forward_rounded,
                size: 18,
                color: enabled ? AppColors.onPrimary : AppColors.ink48,
              ),
            ),
          ),
        );
      },
    );
  }
}

// Styled like a proper list row (icon, title, subtitle, chevron) rather
// than a small icon guess inside the search bar - the same visual language
// as a settings row, so it reads as tappable on sight instead of needing a
// caption to explain itself.
class _ImageSearchAction extends StatelessWidget {
  const _ImageSearchAction({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
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
              Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.photo_camera_rounded,
                  color: AppColors.onPrimary,
                  size: 16,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Search with a photo',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      'Find similar moments instead of describing one',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.ink48,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackgroundIndexingNote extends StatelessWidget {
  const _BackgroundIndexingNote({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.base),
      child: Row(
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Indexing continues in the background - ${controller.totalEmbeddings} indexed so far.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchIdlePrompt extends StatelessWidget {
  const _SearchIdlePrompt({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final hasIndex = controller.totalEmbeddings > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.parchment,
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: const Icon(
              Icons.search_rounded,
              color: AppColors.primary,
              size: 26,
            ),
          ),
          const SizedBox(height: AppSpacing.base),
          Text(
            hasIndex
                ? 'Describe a photo, place, or moment'
                : 'Nothing indexed yet',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            hasIndex
                ? 'Vector searches by meaning, not filenames.'
                : 'Head to the Library tab to index your phone or a folder first.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.ink48,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

// Appears once a text search has results: turns that search into a
// collection - name (pre-filled with the query), then Save.
class _SaveCollectionButton extends StatelessWidget {
  const _SaveCollectionButton({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final query = controller.lastTextQuery;
    final isImageSearch = controller.lastImageSeedUri != null;
    final hasTextSearch = query != null && query.isNotEmpty;
    if ((!hasTextSearch && !isImageSearch) ||
        controller.searchResults.isEmpty) {
      return const SizedBox.shrink();
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () =>
            isImageSearch ? _saveImageSearch(context) : _save(context, query!),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          child: const Icon(
            Icons.bookmark_add_outlined,
            size: 19,
            color: AppColors.primary,
          ),
        ),
      ),
    );
  }

  // An image search (a picked photo, "search with this image", a video frame)
  // saves as a photo-seeded collection: whatever looks like that photo.
  void _saveImageSearch(BuildContext context) {
    final collections = Get.find<CollectionsController>();
    final messenger = ScaffoldMessenger.of(context);

    showSaveCollectionSheet(
      context,
      initialName: 'Similar photos',
      initialQuery: 'photos that look like this one',
      onSave: (name, _) async {
        final created = await collections.saveImageSearchAsCollection(
          name: name,
        );
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              created == null
                  ? "Couldn't save that collection"
                  : 'Saved · ${created.name}',
            ),
            action: created == null
                ? null
                : SnackBarAction(
                    label: 'View',
                    onPressed: () {
                      if (context.mounted) {
                        openCollectionScreen(context, collections, created);
                        }
                    },
                  ),
          ),
        );
      },
    );
  }

  void _save(BuildContext context, String query) {
    final collections = Get.find<CollectionsController>();
    final messenger = ScaffoldMessenger.of(context);

    showSaveCollectionSheet(
      context,
      initialName: query,
      initialQuery: query,
      onSave: (name, _) async {
        final created = await collections.saveSearchAsCollection(name: name);
        if (created == null) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text('Saved · ${created.name}'),
            action: SnackBarAction(
              label: 'View',
              onPressed: () {
                if (context.mounted) {
                  openCollectionScreen(context, collections, created);
                  }
              },
            ),
          ),
        );
      },
    );
  }
}

// A few pinned collections on the empty Search screen - shortcuts, with the
// Collections tab as the real home for the full set.
class _CollectionChipRow extends StatelessWidget {
  const _CollectionChipRow({required this.onSeeAll});

  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    return GetBuilder<CollectionsController>(
      builder: (collections) {
        final pinned = collections.pinned;
        if (pinned.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.xs),
                    child: Text(
                      'COLLECTIONS',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.ink48,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: onSeeAll,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xs),
                      child: Text(
                        'See all',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                height: 38,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: pinned.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: AppSpacing.sm),
                  itemBuilder: (context, i) => CollectionChip(
                    collection: pinned[i],
                    count: collections.statsFor(pinned[i].id).count,
                    coverBytes: collections.coverFor(pinned[i].id),
                    onTap: () =>
                        openCollectionScreen(context, collections, pinned[i]),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// A few of the people found in the library, next to the collections on the
// empty Search screen: faces to tap straight into someone's photos, with the
// People tab as the home for everyone. Absent until there is someone to show.
class _PeopleRow extends StatelessWidget {
  const _PeopleRow({required this.onSeeAll});

  final VoidCallback onSeeAll;

  // Enough to fill and scroll a row without turning into the whole tab.
  static const int _maxShown = 12;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return GetBuilder<FacesController>(
      builder: (faces) {
        final people = faces.people.take(_maxShown).toList();
        if (people.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(top: AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.xs),
                    child: Text(
                      'PEOPLE',
                      style: textTheme.labelSmall?.copyWith(color: AppColors.ink48, letterSpacing: 0.5),
                    ),
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: onSeeAll,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xs),
                      child: Text(
                        'See all',
                        style: textTheme.labelSmall?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                height: 90,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: people.length,
                  separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
                  itemBuilder: (context, i) {
                    final person = people[i];
                    final named = person.name != null;
                    return InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => PersonScreen(person: person)),
                      ),
                      child: SizedBox(
                        width: 66,
                        child: Column(
                          children: [
                            FaceAvatar(faceId: person.coverFaceId, size: 60),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              named ? person.name! : 'Add name',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: named ? AppColors.ink80 : AppColors.ink48,
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
        );
      },
    );
  }
}
