
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/meta_data_model.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/draggable_metadata_sheet.dart';
import 'package:twentyonevision/view/widget/match_strength_bars.dart';
import 'package:twentyonevision/view/widget/media_actions_sheet.dart';
import 'package:twentyonevision/view/widget/media_chrome_button.dart';
import 'package:twentyonevision/view/widget/media_info_widgets.dart';
import 'package:twentyonevision/view/widget/zoomable_image.dart';

class ImageViewScreen extends StatelessWidget {
  const ImageViewScreen({super.key, required this.imageBytes, required this.uri});

  final Uint8List imageBytes;
  final String uri;

  @override
  Widget build(BuildContext context) {
    return GetBuilder<NativeController>(
      builder: (controller) {
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: kMediaOverlayStyle,
          child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                top: 0,
                left: 0,
                right: 0,
                bottom: controller.showMetadata
                    ? MediaQuery.of(context).size.height * 0.5
                    : 0,
                child: ZoomableImage(
                  imageBytes: imageBytes,
                  onSingleTap: controller.hideMetadata,
                ),
              ),

              // A soft scrim behind the top chrome, not just translucent
              // buttons on their own - keeps the icons legible over a
              // bright sky or a white wall, not just over typical photo
              // midtones.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: MediaQuery.of(context).padding.top + 72,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black.withValues(alpha: 0.45), Colors.transparent],
                      ),
                    ),
                  ),
                ),
              ),

              Positioned(
                top: MediaQuery.of(context).padding.top + AppSpacing.sm,
                left: AppSpacing.sm,
                child: MediaChromeButton(icon: Icons.close, tooltip: 'Close', onTap: () => Get.back()),
              ),

              Positioned(
                top: MediaQuery.of(context).padding.top + AppSpacing.sm,
                right: AppSpacing.sm,
                child: Row(
                  children: [
                    MediaChromeButton(
                      icon: Icons.image_search_rounded,
                      tooltip: 'Search with this image',
                      onTap: () {
                        // All the way back to the home screen (this may have been
                        // opened from inside a collection, not straight from
                        // the results), on the Search tab, then search - not
                        // awaited, the results grid shows its own loading state.
                        Get.until((route) => route.isFirst);
                        controller.searchWithImage(uri: uri, bytes: imageBytes);
                      },
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    MediaChromeButton(
                      icon: Icons.ios_share_rounded,
                      tooltip: 'Share and save',
                      onTap: () => showMediaActionsSheet(
                        context,
                        uri: uri,
                        isVideo: false,
                        controller: controller,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    MediaChromeButton(
                      icon: controller.showMetadata ? Icons.info : Icons.info_outline,
                      tooltip: 'Details',
                      onTap: controller.toggleMetadata,
                    ),
                  ],
                ),
              ),

              DraggableMetadataSheet(
                visible: controller.showMetadata,
                onDismissed: controller.hideMetadata,
                heightFactor: 0.5,
                child: _MetadataContent(
                  metadata: controller.selectedMetadata,
                  isLoading: controller.isFetchingMetadata,
                  matchExplanation: controller.matchExplanation,
                ),
              ),
            ],
          ),
        ),
        );
      },
    );
  }
}

// The sheet's actual content - DraggableMetadataSheet handles the
// container/handle/drag physics around this, so this is just what goes
// inside it (loading state, "why this matched", file info).
class _MetadataContent extends StatelessWidget {
  const _MetadataContent({
    required this.metadata,
    required this.isLoading,
    required this.matchExplanation,
  });

  final ImageMetadata metadata;
  final bool isLoading;
  final List<MapEntry<String, double>> matchExplanation;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Absent (not a disabled/empty state) unless this was actually
          // opened from a text search result - see loadMatchExplanation's
          // doc for exactly when that's true.
          if (matchExplanation.isNotEmpty) ...[
            const InfoGroupLabel('Why this matched'),
            const SizedBox(height: AppSpacing.sm),
            MatchStrengthBars(entries: matchExplanation),
            const SizedBox(height: AppSpacing.xl),
          ],
          const InfoGroupLabel('File information'),
          const SizedBox(height: AppSpacing.sm),
          InfoGroupCard(
            children: [
              InfoRow(
                icon: Icons.image_outlined,
                label: 'File name',
                value: metadata.fileName.isNotEmpty ? metadata.fileName : 'Unknown',
              ),
              InfoRow(
                icon: Icons.folder_outlined,
                label: 'File path',
                value: metadata.imagePath.isNotEmpty ? metadata.imagePath : 'Unknown',
              ),
              InfoRow(
                icon: Icons.straighten_rounded,
                label: 'Dimensions',
                value: metadata.resolution,
              ),
              InfoRow(
                icon: Icons.aspect_ratio_rounded,
                label: 'Aspect ratio',
                value: metadata.aspectRatio.toStringAsFixed(2),
              ),
              InfoRow(
                icon: Icons.storage_rounded,
                label: 'File size',
                value: metadata.fileSizeFormatted,
              ),
              InfoRow(
                icon: Icons.type_specimen_outlined,
                label: 'Format',
                value: metadata.mimeType.split('/').last.toUpperCase(),
              ),
            ],
          ),

          if (metadata.dateTime.isNotEmpty ||
              metadata.cameraMake.isNotEmpty ||
              metadata.cameraModel.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            const InfoGroupLabel('Camera details'),
            const SizedBox(height: AppSpacing.sm),
            InfoGroupCard(
              children: [
                if (metadata.dateTime.isNotEmpty)
                  InfoRow(
                    icon: Icons.calendar_today_rounded,
                    label: 'Date taken',
                    value: _formatDateTime(metadata.dateTime),
                  ),
                if (metadata.cameraMake.isNotEmpty || metadata.cameraModel.isNotEmpty)
                  InfoRow(
                    icon: Icons.camera_alt_outlined,
                    label: 'Camera',
                    value: metadata.cameraInfo,
                  ),
              ],
            ),
          ],

          if (metadata.hasLocation) ...[
            const SizedBox(height: AppSpacing.xl),
            const InfoGroupLabel('Location'),
            const SizedBox(height: AppSpacing.sm),
            InfoGroupCard(
              children: [
                InfoRow(
                  icon: Icons.location_on_outlined,
                  label: 'Coordinates',
                  value:
                      '${metadata.latitude!.toStringAsFixed(6)}, ${metadata.longitude!.toStringAsFixed(6)}',
                ),
              ],
            ),
          ],

          const SizedBox(height: AppSpacing.xl),
          const InfoGroupLabel('Technical'),
          const SizedBox(height: AppSpacing.sm),
          InfoGroupCard(
            children: [
              InfoRow(
                icon: Icons.rotate_90_degrees_ccw_rounded,
                label: 'Orientation',
                value: _getOrientationText(metadata.orientation),
              ),
            ],
          ),

          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }

  String _formatDateTime(String dateTime) {
    if (dateTime.isEmpty) return 'Unknown';
    try {
      final parts = dateTime.split(' ');
      if (parts.length >= 2) {
        final dateParts = parts[0].split(':');
        if (dateParts.length == 3) {
          return '${dateParts[0]}-${dateParts[1]}-${dateParts[2]} ${parts[1]}';
        }
      }
      return dateTime;
    } catch (e) {
      return dateTime;
    }
  }

  String _getOrientationText(int orientation) {
    switch (orientation) {
      case 1:
        return 'Normal';
      case 3:
        return 'Rotate 180°';
      case 6:
        return 'Rotate 90° CW';
      case 8:
        return 'Rotate 90° CCW';
      default:
        return 'Unknown';
    }
  }
}
