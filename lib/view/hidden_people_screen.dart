import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';

/// People you've hidden, with a way to bring each back.
class HiddenPeopleScreen extends StatelessWidget {
  const HiddenPeopleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.canvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('Hidden people', style: textTheme.titleMedium),
      ),
      body: SafeArea(
        child: GetBuilder<FacesController>(
          builder: (faces) {
            final hidden = faces.hiddenPeople;
            if (hidden.isEmpty) {
              return Center(
                child: Text(
                  'Nobody is hidden.',
                  style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              itemCount: hidden.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.dividerSoft),
              itemBuilder: (context, i) {
                final person = hidden[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Row(
                    children: [
                      FaceAvatar(faceId: person.coverFaceId, size: 48),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(person.name ?? 'Unnamed', style: textTheme.bodyMedium),
                            Text(
                              person.photoCount == 1 ? '1 photo' : '${person.photoCount} photos',
                              style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => faces.setHidden(person, false),
                        child: const Text('Show'),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
