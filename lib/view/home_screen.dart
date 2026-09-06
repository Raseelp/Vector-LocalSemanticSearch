import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/indexed_folder_model.dart';
import 'package:twentyonevision/models/model_status.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/view/widget/indexed_folders_list.dart';
import 'package:twentyonevision/view/widget/search_results.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 1;

  @override
  Widget build(BuildContext context) {
    return GetBuilder<NativeController>(
      builder: (controller) {
        return Scaffold(
          backgroundColor: AppColors.backGroundColor,
          body: DecoratedBox(
            decoration: const BoxDecoration(gradient: AppColors.screenGradient),
            child: Stack(
              children: [
                const Positioned(
                  top: -30,
                  right: -24,
                  child: _BackgroundOrb(size: 170, color: AppColors.accentSoft),
                ),
                const Positioned(
                  top: 180,
                  left: -40,
                  child: _BackgroundOrb(
                    size: 140,
                    color: AppColors.surfaceAccent,
                  ),
                ),
                SafeArea(
                  child: IndexedStack(
                    index: _selectedIndex,
                    children: [
                      _SearchTabContent(controller: controller),
                      _HomeTabContent(controller: controller),
                      _SettingsTabContent(controller: controller),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            height: 78,
            selectedIndex: _selectedIndex,
            backgroundColor: AppColors.surfaceColor.withValues(alpha: 0.96),
            indicatorColor: AppColors.surfaceAccent,
            surfaceTintColor: Colors.transparent,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: (index) {
              setState(() {
                _selectedIndex = index;
              });
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.search_rounded),
                selectedIcon: Icon(Icons.search_rounded),
                label: 'Search',
              ),
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings_rounded),
                label: 'Settings',
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HomeTabContent extends StatelessWidget {
  const _HomeTabContent({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const PageStorageKey('home-tab'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HeroCard(
            totalEmbeddings: controller.totalEmbeddings,
            indexedFolders: controller.allIndexedFoldersList.length,
            isScanning: controller.isScanning,
            scanResult: controller.scanResult,
            elapsedText: controller.formatDuration(
              milliseconds: controller.scanResult.elapsedMs,
            ),
            embeddingsPerSecond: controller.recentEmbeddingsPerSecond,
            etaText: controller.scanEtaText,
            onIndexDevice: () async {
              final NativeController nativeController = Get.find();
              final granted = await nativeController.requestMediaPermission(
                contentMode: controller.selectedContentMode,
              );

              if (!granted) {
                if (kDebugMode) {
                  print('Permission denied');
                }
                return;
              }
              controller.pickAndScanFolders(isScanEntirePhone: true);
            },
            onChooseFolder: () {
              controller.pickAndScanFolders(isScanEntirePhone: false);
            },
            onStopScanning: () {
              controller.stopScanning();
            },
          ),
          const SizedBox(height: 12),
          const IndexedFoldersList(compact: true, maxVisibleItems: 2),
        ],
      ),
    );
  }
}

class _SearchTabContent extends StatelessWidget {
  const _SearchTabContent({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const PageStorageKey('search-tab'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SearchComposer(controller: controller),
          if (controller.isScanning) ...[
            const SizedBox(height: 18),
            _ScanningHintBanner(totalEmbeddings: controller.totalEmbeddings),
          ],
          if (controller.error.isNotEmpty) ...[
            const SizedBox(height: 18),
            _ErrorBanner(message: controller.error),
          ],
          const SizedBox(height: 22),
          const SearchResultsView(),
        ],
      ),
    );
  }
}

// Search used to just sit queued behind a scan - now it runs concurrently,
// but nobody knows that unless we say so, and people who already sat
// through a big model download aren't likely to also wait out an hour-long
// scan on faith alone.
class _ScanningHintBanner extends StatelessWidget {
  const _ScanningHintBanner({required this.totalEmbeddings});

  final int totalEmbeddings;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceAccent,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.search_rounded,
            color: AppColors.primarybuttonColor,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              totalEmbeddings > 0
                  ? 'Search works right now — $totalEmbeddings indexed so far while the rest finishes.'
                  : 'Search will start returning results as soon as the first files are indexed.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.primarybuttonColor,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchComposer extends StatelessWidget {
  const _SearchComposer({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeading(
            title: 'Search your media',
            subtitle:
                'Describe a moment, use an image reference, and choose the media scope from one focused search area.',
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final useSideBySide = constraints.maxWidth >= 720;

              if (useSideBySide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _SearchInputBar(controller: controller)),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 270,
                      child: _CompactScopeSelector(controller: controller),
                    ),
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SearchInputBar(controller: controller),
                  const SizedBox(height: 12),
                  _CompactScopeSelector(controller: controller),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SearchInputBar extends StatelessWidget {
  const _SearchInputBar({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useCompactActions = constraints.maxWidth < 390;

        return Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          decoration: BoxDecoration(
            color: AppColors.backGroundColor,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: AppColors.borderColor.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  onTapOutside: (event) {
                    FocusScope.of(context).unfocus();
                  },
                  onSubmitted: (_) {
                    controller.searchUsingText(isSearchUsingImage: false);
                  },
                  controller: controller.searchTextController,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(
                    hintText: 'Describe a photo, place, or moment',
                    hintStyle: TextStyle(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                    border: InputBorder.none,
                    isCollapsed: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _SearchBarAction(
                tooltip: 'Search by image instead',
                icon: Icons.image_search_rounded,
                backgroundColor: AppColors.surfaceAccent,
                foregroundColor: AppColors.primarybuttonColor,
                onTap: () {
                  controller.searchUsingText(isSearchUsingImage: true);
                },
              ),
              const SizedBox(width: 8),
              _TextSearchAction(
                showLabel: !useCompactActions,
                resultLimit: controller.sliderValue.round(),
                onTap: () {
                  controller.searchUsingText(isSearchUsingImage: false);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SearchBarAction extends StatelessWidget {
  const _SearchBarAction({
    required this.tooltip,
    required this.icon,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: foregroundColor, size: 22),
          ),
        ),
      ),
    );
  }
}

class _TextSearchAction extends StatelessWidget {
  const _TextSearchAction({
    required this.showLabel,
    required this.resultLimit,
    required this.onTap,
  });

  final bool showLabel;
  final int resultLimit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Search text. Top $resultLimit matches.',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            width: showLabel ? null : 44,
            height: 44,
            padding: showLabel
                ? const EdgeInsets.symmetric(horizontal: 14)
                : EdgeInsets.zero,
            decoration: BoxDecoration(
              color: AppColors.primarybuttonColor,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primarybuttonColor.withValues(alpha: 0.22),
                  blurRadius: 14,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.search_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                if (showLabel) ...[
                  const SizedBox(width: 8),
                  const Text(
                    'Search',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactScopeSelector extends StatelessWidget {
  const _CompactScopeSelector({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: AppColors.surfaceAccent.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.borderColor.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ScopeSegment(
              label: 'Images',
              icon: Icons.image_outlined,
              isSelected: controller.selectedContentMode == ContentMode.images,
              onTap: () {
                controller.toggleSelectedContentMode(
                  contentMode: ContentMode.images,
                );
              },
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: _ScopeSegment(
              label: 'Both',
              icon: Icons.auto_awesome_mosaic_outlined,
              isSelected: controller.selectedContentMode == ContentMode.both,
              onTap: () {
                controller.toggleSelectedContentMode(
                  contentMode: ContentMode.both,
                );
              },
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: _ScopeSegment(
              label: 'Videos',
              icon: Icons.videocam_outlined,
              isSelected: controller.selectedContentMode == ContentMode.videos,
              onTap: () {
                controller.toggleSelectedContentMode(
                  contentMode: ContentMode.videos,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ScopeSegment extends StatelessWidget {
  const _ScopeSegment({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foregroundColor = isSelected ? Colors.white : AppColors.textPrimary;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        gradient: isSelected ? AppColors.heroGradient : null,
        borderRadius: BorderRadius.circular(16),
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: AppColors.primarybuttonColor.withValues(alpha: 0.2),
                  blurRadius: 14,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: foregroundColor),
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected
                        ? foregroundColor
                        : AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsTabContent extends StatelessWidget {
  const _SettingsTabContent({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final modelBytes = controller.modelStatuses.fold<int>(
      0,
      (sum, m) => sum + m.sizeBytes,
    );
    final modelsVerified =
        controller.modelStatuses.isNotEmpty &&
        controller.modelStatuses.every((m) => m.verified);

    return SingleChildScrollView(
      key: const PageStorageKey('settings-tab'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeading(
            title: 'Settings',
            subtitle:
                'Manage the on-device AI models, your indexed folders, and permissions.',
          ),
          const SizedBox(height: 18),
          _ModelStatusCard(controller: controller),
          const SizedBox(height: 18),
          _SurfaceCard(
            padding: const EdgeInsets.all(20),
            child: const IndexedFoldersList(compact: false),
          ),
          const SizedBox(height: 18),
          _SurfaceCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionHeading(
                  title: 'Search preferences',
                  subtitle: 'How many matches to return per search.',
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: controller.sliderValue,
                        min: 10,
                        max: 100,
                        divisions: 90,
                        label: controller.sliderValue.round().toString(),
                        onChanged: controller.setSliderValue,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.elevatedSurface,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        controller.sliderValue.round().toString(),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const _PermissionsCard(),
          const SizedBox(height: 18),
          _SurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                  child: _SectionHeading(
                    title: 'Danger zone',
                    subtitle: 'These actions cannot be undone.',
                  ),
                ),
                if (modelsVerified)
                  _DangerActionRow(
                    label: 'Delete models',
                    caption:
                        'Frees ~${ModelDownloadProgress.formatBytes(modelBytes)}. Search and indexing stop working until you download again.',
                    icon: Icons.download_for_offline_outlined,
                    onTap: () => _confirmAndRun(
                      context: context,
                      title: 'Delete AI models?',
                      message:
                          'This frees ~${ModelDownloadProgress.formatBytes(modelBytes)} of storage. Search and indexing will be unavailable until you download them again.',
                      confirmLabel: 'Delete',
                      onConfirm: controller.deleteModels,
                    ),
                  ),
                _DangerActionRow(
                  label: 'Clear all embeddings',
                  caption:
                      'Remove every generated embedding and reset saved folders',
                  icon: Icons.delete_sweep_outlined,
                  onTap: () => _confirmAndRun(
                    context: context,
                    title: 'Clear all embeddings?',
                    message:
                        'This removes every generated embedding and forgets all indexed folders. You will need to re-scan to search again.',
                    confirmLabel: 'Clear',
                    onConfirm: controller.clearAllEmbeddings,
                  ),
                  isLast: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DangerActionRow extends StatelessWidget {
  const _DangerActionRow({
    required this.label,
    required this.caption,
    required this.icon,
    required this.onTap,
    this.isLast = false,
  });

  final String label;
  final String caption;
  final IconData icon;
  final VoidCallback onTap;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 10,
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.accentSoft,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: AppColors.dangerColor, size: 19),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.dangerColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          caption,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.dangerColor.withValues(
                              alpha: 0.75,
                            ),
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!isLast)
          Divider(
            height: 1,
            color: AppColors.borderColor.withValues(alpha: 0.08),
          ),
      ],
    );
  }
}

class _ModelStatusCard extends StatelessWidget {
  const _ModelStatusCard({required this.controller});

  final NativeController controller;

  @override
  Widget build(BuildContext context) {
    final statuses = controller.modelStatuses;
    final totalBytes = statuses.fold<int>(0, (sum, m) => sum + m.sizeBytes);
    final allVerified = statuses.isNotEmpty && statuses.every((m) => m.verified);

    return _SurfaceCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.surfaceAccent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  allVerified
                      ? Icons.verified_outlined
                      : Icons.download_for_offline_outlined,
                  color: AppColors.primarybuttonColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI models',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      allVerified
                          ? '${ModelDownloadProgress.formatBytes(totalBytes)} on this device'
                          : 'Not ready',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (statuses.isNotEmpty) ...[
            const SizedBox(height: 16),
            ...statuses.map(
              (m) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      m.verified
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 16,
                      color: m.verified
                          ? AppColors.primarybuttonColor
                          : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        m.fileName,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      ModelDownloadProgress.formatBytes(m.sizeBytes),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PermissionsCard extends StatefulWidget {
  const _PermissionsCard();

  @override
  State<_PermissionsCard> createState() => _PermissionsCardState();
}

class _PermissionsCardState extends State<_PermissionsCard> {
  bool? _photosGranted;
  bool? _videosGranted;

  @override
  void initState() {
    super.initState();
    _refresh();
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
    final needsGrant = _photosGranted == false || _videosGranted == false;

    if (_photosGranted == true && _videosGranted == true) {
      return const SizedBox.shrink();
    }

    return _SurfaceCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeading(
            title: 'Permissions',
            subtitle: 'Needed to read your photos and videos for indexing.',
          ),
          const SizedBox(height: 14),
          _PermissionRow(label: 'Photos', granted: _photosGranted),
          const SizedBox(height: 8),
          _PermissionRow(label: 'Videos', granted: _videosGranted),
          if (needsGrant) ...[
            const SizedBox(height: 14),
            _ActionButton(
              label: 'Grant access',
              caption: 'Opens the system permission prompt',
              icon: Icons.lock_open_outlined,
              color: AppColors.secondoryButtonColor,
              foregroundColor: AppColors.textPrimary,
              onTap: () async {
                await [Permission.photos, Permission.videos].request();
                await _refresh();
              },
            ),
          ],
        ],
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
        ? AppColors.textSecondary
        : (isGranted ? AppColors.primarybuttonColor : AppColors.dangerColor);

    return Row(
      children: [
        Icon(
          granted == null
              ? Icons.hourglass_empty_rounded
              : (isGranted ? Icons.check_circle_rounded : Icons.cancel_outlined),
          size: 16,
          color: color,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        Text(
          granted == null ? 'Checking...' : (isGranted ? 'Granted' : 'Not granted'),
          style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

Future<void> _confirmAndRun({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  required VoidCallback onConfirm,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surfaceColor,
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            confirmLabel,
            style: const TextStyle(color: AppColors.dangerColor),
          ),
        ),
      ],
    ),
  );
  if (confirmed == true) onConfirm();
}

class _BackgroundOrb extends StatelessWidget {
  const _BackgroundOrb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.55),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.4),
              blurRadius: 50,
              spreadRadius: 8,
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.totalEmbeddings,
    required this.indexedFolders,
    required this.isScanning,
    required this.scanResult,
    required this.elapsedText,
    required this.embeddingsPerSecond,
    required this.etaText,
    required this.onIndexDevice,
    required this.onChooseFolder,
    required this.onStopScanning,
  });

  final int totalEmbeddings;
  final int indexedFolders;
  final bool isScanning;
  final IndexedFolder scanResult;
  final String elapsedText;
  final double embeddingsPerSecond;
  final String? etaText;
  final VoidCallback onIndexDevice;
  final VoidCallback onChooseFolder;
  final VoidCallback onStopScanning;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.heroGradient,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: AppColors.primarybuttonColor.withValues(alpha: 0.2),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 18),
          _HeroTrustStrip(totalEmbeddings: totalEmbeddings),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 18),
            child: Column(
              children: [
                _HeroStatsRow(
                  totalEmbeddings: totalEmbeddings,
                  indexedFolders: indexedFolders,
                ),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxWidth < 420;
                    if (isScanning) {
                      return _HeroScanningActions(
                        isCompact: isCompact,
                        scanResult: scanResult,
                        elapsedText: elapsedText,
                        embeddingsPerSecond: embeddingsPerSecond,
                        etaText: etaText,
                        onStopScanning: onStopScanning,
                      );
                    }

                    final indexDeviceButton = _CompactHeroAction(
                      label: 'Index phone',
                      caption: 'Build local search',
                      icon: Icons.travel_explore_rounded,
                      color: AppColors.primarybuttonColor,
                      foregroundColor: Colors.white,
                      onTap: onIndexDevice,
                    );
                    final chooseFolderButton = _CompactHeroAction(
                      label: 'Choose folder',
                      caption: 'Add one place',
                      icon: Icons.create_new_folder_outlined,
                      color: Colors.white.withValues(alpha: 0.16),
                      foregroundColor: Colors.white,
                      onTap: onChooseFolder,
                    );

                    if (isCompact) {
                      return Column(
                        children: [
                          indexDeviceButton,
                          const SizedBox(height: 8),
                          chooseFolderButton,
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(flex: 3, child: indexDeviceButton),
                        const SizedBox(width: 8),
                        Expanded(flex: 2, child: chooseFolderButton),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroTrustStrip extends StatelessWidget {
  const _HeroTrustStrip({required this.totalEmbeddings});

  final int totalEmbeddings;

  @override
  Widget build(BuildContext context) {
    final status = totalEmbeddings == 0 ? 'Not indexed yet' : 'Ready';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.lock_outline_rounded,
                color: Colors.white,
                size: 17,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Runs fully on this device — nothing you index is ever uploaded.',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.88),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: AppColors.secondoryButtonColor,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                status,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroStatsRow extends StatelessWidget {
  const _HeroStatsRow({
    required this.totalEmbeddings,
    required this.indexedFolders,
  });

  final int totalEmbeddings;
  final int indexedFolders;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Expanded(
            child: _HeroMetric(
              label: 'Embeddings',
              value: '$totalEmbeddings',
              icon: Icons.hub_outlined,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _HeroMetric(
              label: 'Folders',
              value: '$indexedFolders',
              icon: Icons.folder_copy_outlined,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroMetric extends StatelessWidget {
  const _HeroMetric({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white.withValues(alpha: 0.9), size: 17),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.74),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroScanningActions extends StatelessWidget {
  const _HeroScanningActions({
    required this.isCompact,
    required this.scanResult,
    required this.elapsedText,
    required this.embeddingsPerSecond,
    required this.etaText,
    required this.onStopScanning,
  });

  final bool isCompact;
  final IndexedFolder scanResult;
  final String elapsedText;
  final double embeddingsPerSecond;
  final String? etaText;
  final VoidCallback onStopScanning;

  @override
  Widget build(BuildContext context) {
    final progress = scanResult.total == 0
        ? 0.0
        : (scanResult.processed / scanResult.total).clamp(0.0, 1.0).toDouble();
    final progressPercent = (progress * 100).round();
    final path = scanResult.path.isEmpty
        ? 'Preparing your media scan...'
        : scanResult.path;
    final processedLabel = scanResult.total == 0
        ? 'Preparing files'
        : '${scanResult.processed}/${scanResult.total} processed';

    final progressPanel = _HeroProgressPanel(
      progress: progress,
      progressPercent: progressPercent,
      path: path,
      processedLabel: processedLabel,
      embedded: scanResult.embedded,
      skipped: scanResult.skipped,
      embeddingsPerSecond: embeddingsPerSecond,
      etaText: etaText,
    );
    final controlPanel = _HeroScanControlPanel(
      elapsedText: elapsedText.isEmpty ? '0 Seconds' : elapsedText,
      onStopScanning: onStopScanning,
    );

    if (isCompact) {
      return Column(
        children: [progressPanel, const SizedBox(height: 8), controlPanel],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 3, child: progressPanel),
        const SizedBox(width: 8),
        Expanded(flex: 2, child: controlPanel),
      ],
    );
  }
}

class _HeroProgressPanel extends StatelessWidget {
  const _HeroProgressPanel({
    required this.progress,
    required this.progressPercent,
    required this.path,
    required this.processedLabel,
    required this.embedded,
    required this.skipped,
    required this.embeddingsPerSecond,
    required this.etaText,
  });

  final double progress;
  final int progressPercent;
  final String path;
  final double embeddingsPerSecond;
  final String? etaText;
  final String processedLabel;
  final int embedded;
  final int skipped;

  String get _speedLabel {
    if (embeddingsPerSecond <= 0) return 'measuring speed...';
    if (embeddingsPerSecond >= 1) {
      return '${embeddingsPerSecond.toStringAsFixed(1)}/sec';
    }
    final msPerItem = (1000 / embeddingsPerSecond).round();
    return '${msPerItem}ms/item';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.secondoryButtonColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.textPrimary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.sync_rounded,
                  size: 19,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Indexing media',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '$progressPercent%',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textPrimary.withValues(alpha: 0.78),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: progress,
              backgroundColor: Colors.white.withValues(alpha: 0.38),
              valueColor: const AlwaysStoppedAnimation<Color>(
                AppColors.primarybuttonColor,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _HeroProgressPill(
                icon: Icons.analytics_outlined,
                label: processedLabel,
              ),
              _HeroProgressPill(
                icon: Icons.auto_awesome_mosaic_outlined,
                label: '$embedded embedded',
              ),
              _HeroProgressPill(
                icon: Icons.skip_next_outlined,
                label: '$skipped skipped',
              ),
              _HeroProgressPill(
                icon: Icons.speed_rounded,
                label: _speedLabel,
              ),
              if (etaText != null)
                _HeroProgressPill(
                  icon: Icons.hourglass_bottom_rounded,
                  label: '$etaText left',
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'One-time step — search stays instant once this finishes.',
            style: TextStyle(
              color: AppColors.textPrimary.withValues(alpha: 0.6),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroScanControlPanel extends StatelessWidget {
  const _HeroScanControlPanel({
    required this.elapsedText,
    required this.onStopScanning,
  });

  final String elapsedText;
  final VoidCallback onStopScanning;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.dangerColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.schedule_outlined,
                  size: 19,
                  color: AppColors.dangerColor,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Scanning now',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      elapsedText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary.withValues(alpha: 0.64),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Index actions are paused until this scan finishes.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              height: 1.3,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onStopScanning,
              borderRadius: BorderRadius.circular(14),
              child: Ink(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.dangerColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.stop_circle_outlined,
                      size: 18,
                      color: Colors.white,
                    ),
                    SizedBox(width: 7),
                    Text(
                      'Stop scan',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroProgressPill extends StatelessWidget {
  const _HeroProgressPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.textPrimary),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactHeroAction extends StatelessWidget {
  const _CompactHeroAction({
    required this.label,
    required this.caption,
    required this.icon,
    required this.color,
    required this.foregroundColor,
    required this.onTap,
  });

  final String label;
  final String caption;
  final IconData icon;
  final Color color;
  final Color foregroundColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: foregroundColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 19, color: foregroundColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foregroundColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foregroundColor.withValues(alpha: 0.76),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: AppColors.textSecondary,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({required this.child, required this.padding});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surfaceColor.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: AppColors.borderColor.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadowColor.withValues(alpha: 0.46),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.caption,
    required this.icon,
    required this.color,
    required this.foregroundColor,
    required this.onTap,
  });

  final String label;
  final String caption;
  final IconData icon;
  final Color color;
  final Color foregroundColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.28),
                blurRadius: 20,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: foregroundColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: foregroundColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: foregroundColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      caption,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: foregroundColor.withValues(alpha: 0.78),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: AppColors.dangerColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.dangerColor,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
