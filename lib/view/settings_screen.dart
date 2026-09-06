import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/model_status.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/confirm_dialog.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<NativeController>(
      builder: (controller) {
        final modelBytes = controller.modelStatuses.fold<int>(
          0,
          (sum, m) => sum + m.sizeBytes,
        );
        final modelsVerified =
            controller.modelStatuses.isNotEmpty &&
            controller.modelStatuses.every((m) => m.verified);

        return Scaffold(
          backgroundColor: AppColors.canvas,
          body: SafeArea(
            child: Column(
              children: [
                _SettingsTopBar(),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.xl,
                      0,
                      AppSpacing.xl,
                      AppSpacing.xxl,
                    ),
                    children: [
                      const _GroupLabel('Model'),
                      _GroupCard(
                        children: [
                          _SettingsRow(
                            icon: modelsVerified
                                ? Icons.verified_outlined
                                : Icons.download_for_offline_outlined,
                            accentIcon: modelsVerified,
                            title: modelsVerified ? 'CLIP, on this device' : 'Not ready',
                            subtitle: modelsVerified
                                ? '${ModelDownloadProgress.formatBytes(modelBytes)} - verified'
                                : null,
                            trailing: modelsVerified
                                ? const Icon(
                                    Icons.check_circle_rounded,
                                    color: AppColors.primary,
                                    size: 18,
                                  )
                                : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      const _GroupLabel('Search'),
                      _GroupCard(children: [_ResultsSlider(controller: controller)]),
                      const SizedBox(height: AppSpacing.xl),
                      const _GroupLabel('Permissions'),
                      const _PermissionsCard(),
                      const SizedBox(height: AppSpacing.xl),
                      const _GroupLabel('Danger zone'),
                      _GroupCard(
                        children: [
                          if (modelsVerified)
                            _DangerRow(
                              title: 'Delete AI models',
                              subtitle:
                                  'Frees ~${ModelDownloadProgress.formatBytes(modelBytes)}',
                              onTap: () => showConfirmDialog(
                                context,
                                title: 'Delete AI models?',
                                message:
                                    'Search and indexing stop working until you download them again.',
                                confirmLabel: 'Delete',
                                onConfirm: controller.deleteModels,
                              ),
                            ),
                          _DangerRow(
                            title: 'Clear all embeddings',
                            subtitle: 'Forgets everything indexed',
                            onTap: () => showConfirmDialog(
                              context,
                              title: 'Clear all embeddings?',
                              message:
                                  'This removes every generated embedding and forgets all indexed folders. You will need to re-scan to search again.',
                              confirmLabel: 'Clear',
                              onConfirm: controller.clearAllEmbeddings,
                            ),
                          ),
                        ],
                      ),
                    ],
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

class _SettingsTopBar extends StatelessWidget {
  const _SettingsTopBar();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.xs, AppSpacing.xl, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: AppColors.ink),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Text('Settings', style: Theme.of(context).textTheme.titleLarge),
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xs, 0, AppSpacing.xs, AppSpacing.sm),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: AppColors.ink48, letterSpacing: 0.5),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.children});

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

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.accentIcon = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool accentIcon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.md),
      child: Row(
        children: [
          Icon(icon, size: 18, color: accentIcon ? AppColors.primary : AppColors.ink48),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(color: accentIcon ? AppColors.primary : null),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) const SizedBox(width: AppSpacing.sm),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _ResultsSlider extends StatelessWidget {
  const _ResultsSlider({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Results per search', style: Theme.of(context).textTheme.titleSmall),
              Text(
                '${controller.sliderValue.round()}',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: AppColors.primary),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: controller.sliderValue,
              min: 10,
              max: 100,
              divisions: 90,
              onChanged: controller.setSliderValue,
            ),
          ),
        ],
      ),
    );
  }
}

class _DangerRow extends StatelessWidget {
  const _DangerRow({required this.title, required this.subtitle, required this.onTap});

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: AppColors.danger),
            ),
            const SizedBox(height: 1),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
            ),
          ],
        ),
      ),
    );
  }
}

// Only ever checked once at startup before - this screen is reached by a
// normal push now (not kept alive under an IndexedStack), so a fresh check
// in initState is enough on its own; the lifecycle observer still catches
// granting/revoking from system Settings while this screen is open.
class _PermissionsCard extends StatefulWidget {
  const _PermissionsCard();

  @override
  State<_PermissionsCard> createState() => _PermissionsCardState();
}

class _PermissionsCardState extends State<_PermissionsCard> with WidgetsBindingObserver {
  bool? _photosGranted;
  bool? _videosGranted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final photos = await Permission.photos.isGranted;
    final videos = await Permission.videos.isGranted;
    if (!mounted) return;
    setState(() {
      _photosGranted = photos;
      _videosGranted = videos;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Always shows the two status rows, granted or not - hiding the whole
    // card once granted left the "Permissions" label sitting above nothing,
    // which reads as broken rather than as good news.
    final needsGrant = _photosGranted == false || _videosGranted == false;

    return _GroupCard(
      children: [
        _PermissionRow(label: 'Photos', granted: _photosGranted),
        _PermissionRow(label: 'Videos', granted: _videosGranted),
        if (needsGrant)
          InkWell(
            onTap: () async {
              await [Permission.photos, Permission.videos].request();
              await _refresh();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.base,
                vertical: AppSpacing.md,
              ),
              child: Text(
                'Grant access',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: AppColors.primary),
              ),
            ),
          ),
      ],
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.label, required this.granted});

  final String label;
  final bool? granted;

  @override
  Widget build(BuildContext context) {
    final isGranted = granted == true;
    final color = granted == null
        ? AppColors.ink48
        : (isGranted ? AppColors.primary : AppColors.danger);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.md),
      child: Row(
        children: [
          Icon(
            granted == null
                ? Icons.hourglass_empty_rounded
                : (isGranted ? Icons.check_circle_rounded : Icons.cancel_outlined),
            size: 16,
            color: color,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(label, style: Theme.of(context).textTheme.titleSmall)),
          Text(
            granted == null ? 'Checking...' : (isGranted ? 'Granted' : 'Not granted'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
