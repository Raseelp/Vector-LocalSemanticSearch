import 'package:flutter/material.dart';
import 'package:get/route_manager.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:twentyonevision/bindings/init_bindings.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/view/app_gate.dart';

void main() {
  runApp(const TwentyOneVision());
}

class TwentyOneVision extends StatelessWidget {
  const TwentyOneVision({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.primary,
      secondary: AppColors.primary,
      surface: AppColors.canvas,
      error: AppColors.danger,
    );

    // Material's default text theme reaches for weight 500 on titles and
    // labels - the one weight this app never uses. Every role below is
    // pinned to 400 (body), 600 (labels/emphasis), or 700 (headlines).
    final baseText = GoogleFonts.spaceGroteskTextTheme();
    final textTheme = baseText.copyWith(
      displayLarge: baseText.displayLarge?.copyWith(fontWeight: FontWeight.w700),
      displayMedium: baseText.displayMedium?.copyWith(fontWeight: FontWeight.w700),
      displaySmall: baseText.displaySmall?.copyWith(fontWeight: FontWeight.w700),
      headlineLarge: baseText.headlineLarge?.copyWith(fontWeight: FontWeight.w700),
      headlineMedium: baseText.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
      headlineSmall: baseText.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      titleLarge: baseText.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: baseText.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: baseText.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: baseText.bodyLarge?.copyWith(fontWeight: FontWeight.w400),
      bodyMedium: baseText.bodyMedium?.copyWith(fontWeight: FontWeight.w400),
      bodySmall: baseText.bodySmall?.copyWith(fontWeight: FontWeight.w400),
      labelLarge: baseText.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      labelMedium: baseText.labelMedium?.copyWith(fontWeight: FontWeight.w600),
      labelSmall: baseText.labelSmall?.copyWith(fontWeight: FontWeight.w600),
    ).apply(bodyColor: AppColors.ink, displayColor: AppColors.ink);

    return GetMaterialApp(
      initialBinding: InitBindings(),
      home: const AppGate(),
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.canvas,
        colorScheme: colorScheme,
        textTheme: textTheme,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
          foregroundColor: AppColors.ink,
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: AppColors.primary,
          inactiveTrackColor: AppColors.hairline,
          thumbColor: AppColors.primary,
          overlayColor: AppColors.primary.withValues(alpha: 0.12),
          trackHeight: 4,
        ),
      ),
    );
  }
}
