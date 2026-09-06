import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/meta_data_model.dart';
import 'package:twentyonevision/utils/app_colors.dart';

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
                top: MediaQuery.of(context).padding.top + 8,
                left: 8,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 28,
                    ),
                    onPressed: () => Get.back(),
                  ),
                ),
              ),

              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 8,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: Icon(
                      controller.showMetadata
                          ? Icons.info
                          : Icons.info_outline,
                      color: Colors.white,
                      size: 28,
                    ),
                    onPressed: controller.toggleMetadata,
                  ),
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
                color: Color(0xFF1C1C1E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[600],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: isLoading
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: Colors.white54,
                            ),
                          )
                        : SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SectionHeader(title: 'File Information'),
                          const SizedBox(height: 12),
                          _InfoCard(
                            children: [
                              _InfoRow(
                                icon: Icons.image_outlined,
                                label: 'File Name',
                                value: metadata.fileName.isNotEmpty
                                    ? metadata.fileName
                                    : 'Unknown',
                              ),
                              const _Divider(),
                              _InfoRow(
                                icon: Icons.image_outlined,
                                label: 'File Path',
                                value: metadata.imagePath.isNotEmpty
                                    ? metadata.imagePath
                                    : 'Unknown',
                              ),
                              const _Divider(),
                              _InfoRow(
                                icon: Icons.straighten,
                                label: 'Dimensions',
                                value: metadata.resolution,
                              ),
                              const _Divider(),
                              _InfoRow(
                                icon: Icons.aspect_ratio,
                                label: 'Aspect Ratio',
                                value: metadata.aspectRatio.toStringAsFixed(2),
                              ),
                              const _Divider(),
                              _InfoRow(
                                icon: Icons.storage,
                                label: 'File Size',
                                value: metadata.fileSizeFormatted,
                              ),
                              const _Divider(),
                              _InfoRow(
                                icon: Icons.type_specimen,
                                label: 'Format',
                                value: metadata.mimeType
                                    .split('/')
                                    .last
                                    .toUpperCase(),
                              ),
                            ],
                          ),

                          if (metadata.dateTime.isNotEmpty ||
                              metadata.cameraMake.isNotEmpty ||
                              metadata.cameraModel.isNotEmpty) ...[
                            const SizedBox(height: 24),
                            _SectionHeader(title: 'Camera Details'),
                            const SizedBox(height: 12),
                            _InfoCard(
                              children: [
                                if (metadata.dateTime.isNotEmpty) ...[
                                  _InfoRow(
                                    icon: Icons.calendar_today,
                                    label: 'Date Taken',
                                    value: _formatDateTime(metadata.dateTime),
                                  ),
                                  if (metadata.cameraMake.isNotEmpty ||
                                      metadata.cameraModel.isNotEmpty)
                                    const _Divider(),
                                ],
                                if (metadata.cameraMake.isNotEmpty ||
                                    metadata.cameraModel.isNotEmpty)
                                  _InfoRow(
                                    icon: Icons.camera_alt,
                                    label: 'Camera',
                                    value: metadata.cameraInfo,
                                  ),
                              ],
                            ),
                          ],

                          if (metadata.hasLocation) ...[
                            const SizedBox(height: 24),
                            _SectionHeader(title: 'Location'),
                            const SizedBox(height: 12),
                            _InfoCard(
                              children: [
                                _InfoRow(
                                  icon: Icons.location_on,
                                  label: 'Coordinates',
                                  value:
                                      '${metadata.latitude!.toStringAsFixed(6)}, ${metadata.longitude!.toStringAsFixed(6)}',
                                ),
                              ],
                            ),
                          ],

                          const SizedBox(height: 24),
                          _SectionHeader(title: 'Technical'),
                          const SizedBox(height: 12),
                          _InfoCard(
                            children: [
                              _InfoRow(
                                icon: Icons.rotate_90_degrees_ccw,
                                label: 'Orientation',
                                value: _getOrientationText(
                                  metadata.orientation,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 32),
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

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final List<Widget> children;

  const _InfoCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(children: children),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: AppColors.primary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      height: 1,
      color: Colors.grey[800],
    );
  }
}
