import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/image_full_screen.dart';
import 'package:twentyonevision/view/video_full_screen.dart';

class SearchResultsGrid extends StatelessWidget {
  const SearchResultsGrid({super.key, required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.isSearching) {
      return const _CenterNote(
        spinner: true,
        title: 'Searching',
        subtitle: 'Finding the best matches on this device...',
      );
    }

    if (controller.error.isNotEmpty) {
      return _CenterNote(
        icon: Icons.error_outline_rounded,
        title: 'Something went wrong',
        subtitle: controller.error,
      );
    }

    if (controller.searchResults.isEmpty) {
      return _CenterNote(
        icon: Icons.search_rounded,
        title: 'Search your media',
        subtitle: controller.totalEmbeddings == 0
            ? 'Index a folder or your phone first, then come back to search.'
            : 'Describe a photo, place, or moment above.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.xs),
                child: Text(
                  '${controller.searchResults.length} results',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: AppColors.ink48, letterSpacing: 0.5),
                ),
              ),
              const Spacer(),
              _LayoutPickerButton(controller: controller),
            ],
          ),
        ),
        _ResultsBody(controller: controller),
      ],
    );
  }
}

class _ResultsBody extends StatelessWidget {
  const _ResultsBody({required this.controller});

  final NativeController controller;

  int get _crossAxisCount {
    switch (controller.resultsLayout) {
      case ResultsLayout.list:
        return 1;
      case ResultsLayout.grid2:
        return 2;
      case ResultsLayout.grid3:
        return 3;
      case ResultsLayout.grid4:
        return 4;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isList = controller.resultsLayout == ResultsLayout.list;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _crossAxisCount,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
        childAspectRatio: isList ? 1.7 : 0.86,
      ),
      itemCount: controller.searchResults.length,
      itemBuilder: (context, index) {
        final item = controller.searchResults[index];
        final uri = item['path'] as String;
        final isVideo = item['isVideo'] as bool? ?? false;
        final timestampMs = (item['timestampMs'] as num?)?.toInt() ?? 0;
        final cacheKey = controller.cacheKeyForResult(item);
        final bytes = controller.imageCache[cacheKey];

        if (bytes == null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: ColoredBox(
              color: AppColors.parchment,
              child: const Center(
                child: Icon(Icons.image_not_supported_outlined, color: AppColors.ink48),
              ),
            ),
          );
        }

        return _ResultTile(
          bytes: bytes,
          isVideo: isVideo,
          onTap: () {
            if (isVideo) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => VideoViewScreen(
                    videoUri: uri,
                    timestampMs: timestampMs,
                    thumbnailBytes: bytes,
                  ),
                ),
              );
            } else {
              controller.loadMetaDataByUri(uri: uri);
              Get.to(() => ImageViewScreen(imageBytes: bytes));
            }
          },
        );
      },
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.bytes, required this.isVideo, required this.onTap});

  final Uint8List bytes;
  final bool isVideo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(bytes, fit: BoxFit.cover),
              if (isVideo)
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 13),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// Same bordered-pill-plus-chevron treatment as the scan-scope control, and
// the same sheet-with-options pattern for picking - one consistent "this is
// how pickers look and behave" language instead of inventing a new one here.
class _LayoutPickerButton extends StatelessWidget {
  const _LayoutPickerButton({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: () => _showLayoutPicker(context, controller),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            color: AppColors.canvas,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_layoutIcon(controller.resultsLayout), size: 14, color: AppColors.ink80),
              const SizedBox(width: AppSpacing.xxs),
              const Icon(Icons.expand_more_rounded, size: 14, color: AppColors.ink48),
            ],
          ),
        ),
      ),
    );
  }
}

void _showLayoutPicker(BuildContext context, NativeController controller) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _LayoutSheet(controller: controller),
  );
}

class _LayoutSheet extends StatelessWidget {
  const _LayoutSheet({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.canvas,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.base),
                child: Text(
                  'How should results be laid out?',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const Divider(height: 1, color: AppColors.hairline),
              for (final layout in ResultsLayout.values) ...[
                if (layout != ResultsLayout.values.first)
                  const Divider(height: 1, color: AppColors.dividerSoft),
                _LayoutOption(
                  layout: layout,
                  selected: controller.resultsLayout == layout,
                  onTap: () {
                    controller.setResultsLayout(layout);
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LayoutOption extends StatelessWidget {
  const _LayoutOption({required this.layout, required this.selected, required this.onTap});

  final ResultsLayout layout;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.md),
        child: Row(
          children: [
            Icon(
              _layoutIcon(layout),
              size: 18,
              color: selected ? AppColors.primary : AppColors.ink48,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                _layoutLabel(layout),
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: selected ? AppColors.primary : AppColors.ink),
              ),
            ),
            if (selected) const Icon(Icons.check_rounded, size: 18, color: AppColors.primary),
          ],
        ),
      ),
    );
  }
}

IconData _layoutIcon(ResultsLayout layout) {
  switch (layout) {
    case ResultsLayout.list:
      return Icons.view_agenda_outlined;
    case ResultsLayout.grid2:
      return Icons.grid_view_rounded;
    case ResultsLayout.grid3:
      return Icons.view_module_rounded;
    case ResultsLayout.grid4:
      return Icons.apps_rounded;
  }
}

String _layoutLabel(ResultsLayout layout) {
  switch (layout) {
    case ResultsLayout.list:
      return 'List - one large preview per row';
    case ResultsLayout.grid2:
      return 'Grid - 2 across';
    case ResultsLayout.grid3:
      return 'Grid - 3 across';
    case ResultsLayout.grid4:
      return 'Grid - 4 across';
  }
}

class _CenterNote extends StatelessWidget {
  const _CenterNote({this.icon, this.spinner = false, required this.title, required this.subtitle});

  final IconData? icon;
  final bool spinner;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.huge),
      child: Column(
        children: [
          if (spinner)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.primary),
            )
          else if (icon != null)
            Icon(icon, size: 32, color: AppColors.ink48),
          const SizedBox(height: AppSpacing.base),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.ink48, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
