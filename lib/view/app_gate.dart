import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/view/home_screen.dart';
import 'package:twentyonevision/view/model_download_screen.dart';

/// Shows the download screen until every model is on the device, then the app.
class AppGate extends StatelessWidget {
  const AppGate({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<NativeController>(
      builder: (controller) {
        if (controller.isCheckingModels) {
          return const Scaffold(
            backgroundColor: AppColors.canvas,
            body: Center(
              child: CircularProgressIndicator(
                color: AppColors.primary,
              ),
            ),
          );
        }

        // Both the search models and the face recognition model.
        if (!controller.allModelsReady) {
          return const ModelDownloadScreen();
        }

        return const HomeScreen();
      },
    );
  }
}
