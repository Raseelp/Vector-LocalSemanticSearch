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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm, left: AppSpacing.xs),
          child: Text(
            '${controller.searchResults.length} results',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: AppColors.ink48, letterSpacing: 0.5),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final crossAxisCount = width >= 700 ? 4 : (width >= 460 ? 3 : 2);

            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: AppSpacing.sm,
                mainAxisSpacing: AppSpacing.sm,
                childAspectRatio: 0.86,
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
          },
        ),
      ],
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
