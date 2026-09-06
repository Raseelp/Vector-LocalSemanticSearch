import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/meta_data_model.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';

class ImageViewScreen extends StatelessWidget {
  const ImageViewScreen({super.key, required this.imageBytes});
  final Uint8List imageBytes;

  @override
  Widget build(BuildContext context) {
    return GetBuilder<NativeController>(
      builder: (controller) {
        return Scaffold(
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
                child: GestureDetector(
                  onTap: () {
                    if (controller.showMetadata) {
                      controller.toggleMetadata();
                    }
                  },
                  child: Image.memory(imageBytes, fit: BoxFit.contain),
                ),
              ),

              Positioned(
                top: MediaQuery.of(context).padding.top + AppSpacing.sm,
                left: AppSpacing.sm,
                child: _ChromeButton(icon: Icons.close, onTap: () => Get.back()),
              ),

              Positioned(
                top: MediaQuery.of(context).padding.top + AppSpacing.sm,
                right: AppSpacing.sm,
                child: _ChromeButton(
                  icon: controller.showMetadata ? Icons.info : Icons.info_outline,
                  onTap: controller.toggleMetadata,
                ),
              ),

              MetadataBottomSheet(
                metadata: controller.selectedMetadata,
                isLoading: controller.isFetchingMetadata,
              ),
            ],
          ),
        );
      },
    );
  }
}

// Floating chrome over the photo itself - translucent black circle, white
// icon. Standard for a photo viewer's own controls regardless of the app's
// light theme underneath (the photo, not the app chrome, is what's on
// screen), so this stays outside the app's light-surface token language on
// purpose.
class _ChromeButton extends StatelessWidget {
  const _ChromeButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 26),
        onPressed: onTap,
      ),
    );
  }
}

class MetadataBottomSheet extends StatelessWidget {
  final ImageMetadata metadata;
  final bool isLoading;

  const MetadataBottomSheet({
    super.key,
    required this.metadata,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return GetBuilder<NativeController>(
      builder: (controller) {
        return AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          left: 0,
          right: 0,
          bottom: controller.showMetadata
              ? 0
              : -MediaQuery.of(context).size.height * 0.5,
          child: GestureDetector(
            onVerticalDragUpdate: (details) {
              if (details.delta.dy > 5) {
                controller.toggleMetadata();
              }
            },
            child: Container(
              height: MediaQuery.of(context).size.height * 0.5,
              decoration: const BoxDecoration(
                color: AppColors.canvas,
                borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: AppSpacing.sm),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.hairline,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Expanded(
                    child: isLoading
                        ? const Center(
                            child: CircularProgressIndicator(color: AppColors.primary),
                          )
                        : SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _InfoGroupLabel('File information'),
                                const SizedBox(height: AppSpacing.sm),
                                _InfoGroupCard(
                                  children: [
                                    _InfoRow(
                                      icon: Icons.image_outlined,
                                      label: 'File name',
                                      value: metadata.fileName.isNotEmpty
                                          ? metadata.fileName
                                          : 'Unknown',
                                    ),
                                    _InfoRow(
                                      icon: Icons.folder_outlined,
                                      label: 'File path',
                                      value: metadata.imagePath.isNotEmpty
                                          ? metadata.imagePath
                                          : 'Unknown',
                                    ),
                                    _InfoRow(
                                      icon: Icons.straighten_rounded,
                                      label: 'Dimensions',
                                      value: metadata.resolution,
                                    ),
                                    _InfoRow(
                                      icon: Icons.aspect_ratio_rounded,
                                      label: 'Aspect ratio',
                                      value: metadata.aspectRatio.toStringAsFixed(2),
                                    ),
                                    _InfoRow(
                                      icon: Icons.storage_rounded,
                                      label: 'File size',
                                      value: metadata.fileSizeFormatted,
                                    ),
                                    _InfoRow(
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
                                  const _InfoGroupLabel('Camera details'),
                                  const SizedBox(height: AppSpacing.sm),
                                  _InfoGroupCard(
                                    children: [
                                      if (metadata.dateTime.isNotEmpty)
                                        _InfoRow(
                                          icon: Icons.calendar_today_rounded,
                                          label: 'Date taken',
                                          value: _formatDateTime(metadata.dateTime),
                                        ),
                                      if (metadata.cameraMake.isNotEmpty ||
                                          metadata.cameraModel.isNotEmpty)
                                        _InfoRow(
                                          icon: Icons.camera_alt_outlined,
                                          label: 'Camera',
                                          value: metadata.cameraInfo,
                                        ),
                                    ],
                                  ),
                                ],

                                if (metadata.hasLocation) ...[
                                  const SizedBox(height: AppSpacing.xl),
                                  const _InfoGroupLabel('Location'),
                                  const SizedBox(height: AppSpacing.sm),
                                  _InfoGroupCard(
                                    children: [
                                      _InfoRow(
                                        icon: Icons.location_on_outlined,
                                        label: 'Coordinates',
                                        value:
                                            '${metadata.latitude!.toStringAsFixed(6)}, ${metadata.longitude!.toStringAsFixed(6)}',
                                      ),
                                    ],
                                  ),
                                ],

                                const SizedBox(height: AppSpacing.xl),
                                const _InfoGroupLabel('Technical'),
                                const SizedBox(height: AppSpacing.sm),
                                _InfoGroupCard(
                                  children: [
                                    _InfoRow(
                                      icon: Icons.rotate_90_degrees_ccw_rounded,
                                      label: 'Orientation',
                                      value: _getOrientationText(metadata.orientation),
                                    ),
                                  ],
                                ),

                                const SizedBox(height: AppSpacing.xxl),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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

// Same grouped-card grammar as Settings: a pearl-toned card, dividerSoft
// between rows, an uppercase muted caption above each group.
class _InfoGroupLabel extends StatelessWidget {
  const _InfoGroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: AppColors.ink48, letterSpacing: 0.5),
    );
  }
}

class _InfoGroupCard extends StatelessWidget {
  const _InfoGroupCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: ColoredBox(
        color: AppColors.pearl,
        child: Column(
          children: [
            for (int i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: AppColors.dividerSoft),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                ),
                const SizedBox(height: 1),
                Text(value, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
