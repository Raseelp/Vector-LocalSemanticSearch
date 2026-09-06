import 'package:flutter/material.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/search_results.dart';

class SearchTab extends StatelessWidget {
  const SearchTab({super.key, required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final showResults =
        controller.isSearching ||
        controller.searchResults.isNotEmpty ||
        controller.error.isNotEmpty;
    final hasImage = controller.pickedSearchImageUri != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SearchPill(controller: controller),
          if (!hasImage) ...[
            const SizedBox(height: AppSpacing.sm),
            _ImageSearchAction(onTap: controller.pickSearchImage),
          ],
          const SizedBox(height: AppSpacing.lg),
          if (controller.isScanning) _BackgroundIndexingNote(controller: controller),
          if (showResults)
            SearchResultsGrid(controller: controller)
          else
            _SearchIdlePrompt(controller: controller),
        ],
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.xxs),
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
          _SearchSubmitButton(controller: controller),
        ],
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
                : Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 64, cacheHeight: 64),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            'Matching this photo',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.ink80),
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
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.parchment,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                child: const Icon(Icons.photo_camera_rounded, color: AppColors.onPrimary, size: 16),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Search with a photo', style: Theme.of(context).textTheme.titleSmall),
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
              const Icon(Icons.chevron_right_rounded, color: AppColors.ink48, size: 20),
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
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Indexing continues in the background - ${controller.totalEmbeddings} indexed so far.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
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
            child: const Icon(Icons.search_rounded, color: AppColors.primary, size: 26),
          ),
          const SizedBox(height: AppSpacing.base),
          Text(
            hasIndex ? 'Describe a photo, place, or moment' : 'Nothing indexed yet',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            hasIndex
                ? 'Vector searches by meaning, not filenames.'
                : 'Head to the Library tab to index your phone or a folder first.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.45),
          ),
        ],
      ),
    );
  }
}
