import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:twentyonevision/controllers/collections_controller.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
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
        final modelBytes = controller.searchModelBytes;
        final modelsVerified = controller.searchModelsVerified;
        final hasEmbeddings =
            controller.totalEmbeddings > 0 ||
            controller.allIndexedFoldersList.isNotEmpty;
        // What a delete would free: the downloaded (search) models.
        final deletableBytes = controller.searchModelsVerified
            ? controller.searchModelBytes
            : 0;

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
                      const _GroupLabel('Models'),
                      _GroupCard(
                        children: [
                          _SettingsRow(
                            icon: modelsVerified
                                ? Icons.verified_outlined
                                : Icons.download_for_offline_outlined,
                            accentIcon: modelsVerified,
                            title: modelsVerified
                                ? 'Search model (CLIP)'
                                : 'Search model - not ready',
                            subtitle: modelsVerified
                                ? 'Finds photos by meaning  ·  ${ModelDownloadProgress.formatBytes(modelBytes)}  ·  verified'
                                : null,
                            trailing: modelsVerified
                                ? const Icon(
                                    Icons.check_circle_rounded,
                                    color: AppColors.primary,
                                    size: 18,
                                  )
                                : null,
                          ),
                          const _SettingsRow(
                            icon: Icons.verified_outlined,
                            accentIcon: true,
                            title: 'Face detector',
                            subtitle:
                                'Finds where faces are in photos and videos  ·  about 3 MB  ·  built in',
                            trailing: Icon(
                              Icons.check_circle_rounded,
                              color: AppColors.primary,
                              size: 18,
                            ),
                          ),
                          const _SettingsRow(
                            icon: Icons.verified_outlined,
                            accentIcon: true,
                            title: 'Face recognition',
                            subtitle:
                                'Groups photos by person  ·  about 13 MB  ·  built in',
                            trailing: Icon(
                              Icons.check_circle_rounded,
                              color: AppColors.primary,
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.xs,
                          AppSpacing.sm,
                          AppSpacing.xs,
                          0,
                        ),
                        child: Text(
                          'All the models run only on this device. Your photos, faces and names are never uploaded, '
                          'and nothing needs the internet once they are downloaded.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppColors.ink48, height: 1.4),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      const _GroupLabel('Permissions'),
                      _PermissionsCard(controller: controller),
                      const SizedBox(height: AppSpacing.xl),
                      const _GroupLabel('Collections'),
                      GetBuilder<CollectionsController>(
                        builder: (collections) => _GroupCard(
                          children: [
                            _TapRow(
                              icon: Icons.sync_rounded,
                              title: 'Resync collections',
                              subtitle: collections.isScoring
                                  ? 'Working on it...'
                                  : 'Recompute every collection from scratch',
                              onTap: collections.isScoring
                                  ? null
                                  : collections.resyncAll,
                            ),
                            _TapRow(
                              icon: Icons.restart_alt_rounded,
                              title: 'Restore default collections',
                              subtitle: collections.hasCustomizedBuiltIns
                                  ? 'Bring back deleted or hidden ones and undo edits'
                                  : 'Nothing to restore',
                              onTap: collections.hasCustomizedBuiltIns
                                  ? collections.restoreDefaults
                                  : null,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      const _GroupLabel('Diagnostics'),
                      _GroupCard(
                        children: [
                          _SettingsRow(
                            icon: Icons.speed_rounded,
                            title: 'Performance logs',
                            subtitle:
                                'Prints how long indexing and finding faces take, for tracking down what is slow. '
                                'Read them with: adb logcat -s VectorBench',
                            trailing: Switch(
                              value: controller.benchLogsEnabled,
                              onChanged: controller.setBenchLogsEnabled,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      const _GroupLabel('Danger zone'),
                      _GroupCard(
                        children: [
                          if (deletableBytes > 0 || modelsVerified)
                            _DangerRow(
                              title: 'Delete AI models',
                              subtitle:
                                  'Frees ~${ModelDownloadProgress.formatBytes(deletableBytes)} - the search model',
                              onTap: () => showConfirmDialog(
                                context,
                                title: 'Delete AI models?',
                                message:
                                    'Search and indexing stop working until you download the search model again - you will be taken back to the setup screen. Your photos, the search index and the people already found are kept.',
                                confirmLabel: 'Delete',
                                onConfirm: () {
                                  controller.deleteModels().then((_) {
                                    // Back to the root: the app gate now shows the setup screen.
                                    if (context.mounted) {
                                      Navigator.of(
                                        context,
                                      ).popUntil((route) => route.isFirst);
                                    }
                                  });
                                },
                              ),
                            ),
                          // Greyed out once there is nothing left to clear.
                          _DangerRow(
                            title: 'Clear all embeddings',
                            subtitle: hasEmbeddings
                                ? 'Forgets everything indexed for search'
                                : 'Nothing indexed yet',
                            onTap: !hasEmbeddings
                                ? null
                                : () => showConfirmDialog(
                                    context,
                                    title: 'Clear all embeddings?',
                                    message:
                                        'This removes every generated search embedding and forgets all indexed folders. You will need to re-scan to search again. The people already found are kept - see "Clear face data" for those.',
                                    confirmLabel: 'Clear',
                                    onConfirm: controller.clearAllEmbeddings,
                                  ),
                          ),
                          GetBuilder<FacesController>(
                            builder: (faces) {
                              final st = faces.status;
                              final hasFaceData =
                                  st.faces > 0 ||
                                  st.people > 0 ||
                                  st.processed > 0;
                              return _DangerRow(
                                title: 'Clear face data',
                                subtitle: hasFaceData
                                    ? 'Forgets every group and name, then finds faces again'
                                    : 'No face data yet',
                                onTap: !hasFaceData
                                    ? null
                                    : () => showConfirmDialog(
                                        context,
                                        title: 'Clear face data?',
                                        message:
                                            'All groups and the names you gave will be removed, and every indexed photo is searched for faces again.',
                                        confirmLabel: 'Clear',
                                        onConfirm: faces.rescanEverything,
                                      ),
                              );
                            },
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
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        AppSpacing.xs,
        AppSpacing.xl,
        0,
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 18,
              color: AppColors.ink,
            ),
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
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        0,
        AppSpacing.xs,
        AppSpacing.sm,
      ),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: AppColors.ink48,
          letterSpacing: 0.5,
        ),
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
          crossAxisAlignment: CrossAxisAlignment.start,
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.md,
      ),
      child: Row(
        // Long text wraps to more lines instead of being cut off.
        children: [
          Icon(
            icon,
            size: 18,
            color: accentIcon ? AppColors.primary : AppColors.ink48,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: accentIcon ? AppColors.primary : null,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle!,
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

class _DangerRow extends StatelessWidget {
  const _DangerRow({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;

  /// Null greys the row out: there is nothing for it to do.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.base,
            vertical: AppSpacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: AppColors.danger),
              ),
              const SizedBox(height: 1),
              Text(
                subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Only ever checked once at startup before - this screen is reached by a
// normal push now (not kept alive under an IndexedStack), so a fresh check
// in initState is enough on its own; the lifecycle observer still catches
// granting/revoking from system Settings while this screen is open.
// Every permission the app ever asks for should have a row here - this is
// meant to be the one place a user (or us, reviewing it) can see the
// app's complete permission footprint at a glance. Whenever a new one is
// added anywhere else in the app, add its row here too:
//  - Photos/Videos: storage access, requested in NativeController.
//    requestMediaPermission - required, the app can't scan without it.
//  - Notifications: "keep this going in the background" - requested by
//    NativeController.requestBackgroundScanPermission (see its doc),
//    tracked in backgroundNotificationsGranted, refreshed automatically
//    on every app resume by NativeController's own WidgetsBindingObserver -
//    optional, scanning works without it, it just won't show a progress
//    notification.
class _PermissionsCard extends StatefulWidget {
  const _PermissionsCard({required this.controller});

  final NativeController controller;

  @override
  State<_PermissionsCard> createState() => _PermissionsCardState();
}

class _PermissionsCardState extends State<_PermissionsCard>
    with WidgetsBindingObserver {
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
    final controller = widget.controller;

    // Always shows every status row, granted or not - hiding the whole
    // card once granted left the "Permissions" label sitting above
    // nothing, which reads as broken rather than as good news.
    final needsStorageGrant =
        _photosGranted == false || _videosGranted == false;
    final needsNotificationGrant = !controller.backgroundNotificationsGranted;

    return _GroupCard(
      children: [
        _PermissionRow(label: 'Photos', granted: _photosGranted),
        _PermissionRow(label: 'Videos', granted: _videosGranted),
        if (needsStorageGrant)
          _GrantAccessRow(
            onTap: () async {
              await [Permission.photos, Permission.videos].request();
              await _refresh();
            },
          ),
        const Divider(height: 1, color: AppColors.hairline),
        _PermissionRow(
          label: 'Notifications',
          granted: controller.backgroundNotificationsGranted,
        ),
        if (needsNotificationGrant)
          _GrantAccessRow(onTap: controller.requestBackgroundScanPermission),
      ],
    );
  }
}

class _GrantAccessRow extends StatelessWidget {
  const _GrantAccessRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          Icon(
            granted == null
                ? Icons.hourglass_empty_rounded
                : (isGranted
                      ? Icons.check_circle_rounded
                      : Icons.cancel_outlined),
            size: 16,
            color: color,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.titleSmall),
          ),
          Text(
            granted == null
                ? 'Checking...'
                : (isGranted ? 'Granted' : 'Not granted'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

// A settings row that does something when tapped - dimmed and inert when
// [onTap] is null.
class _TapRow extends StatelessWidget {
  const _TapRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: _SettingsRow(icon: icon, title: title, subtitle: subtitle),
      ),
    );
  }
}
