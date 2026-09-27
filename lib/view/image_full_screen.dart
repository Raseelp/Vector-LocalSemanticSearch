import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/meta_data_model.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/person_screen.dart';
import 'package:twentyonevision/view/widget/draggable_metadata_sheet.dart';
import 'package:twentyonevision/view/widget/match_strength_bars.dart';
import 'package:twentyonevision/view/widget/media_actions_sheet.dart';
import 'package:twentyonevision/view/widget/media_chrome_button.dart';
import 'package:twentyonevision/view/widget/media_info_widgets.dart';
import 'package:twentyonevision/view/widget/photo_faces_layer.dart';
import 'package:twentyonevision/view/widget/video_people_strip.dart';
import 'package:twentyonevision/view/widget/zoomable_image.dart';

class ImageViewScreen extends StatefulWidget {
  const ImageViewScreen({
    super.key,
    required this.imageBytes,
    required this.uri,
    this.loadFullRes = false,
  });

  /// What to show straight away (may be only a small thumbnail).
  final Uint8List imageBytes;
  final String uri;

  /// True when [imageBytes] is just a grid thumbnail: the viewer then loads
  /// the sharp version and swaps it in.
  final bool loadFullRes;

  @override
  State<ImageViewScreen> createState() => _ImageViewScreenState();
}

/// Coming back from a photo or video to the results, the search box was getting its
/// focus back and pulling the keyboard up. Nobody asked for that - drop it again.
void _dropSearchFocus() {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (Get.isRegistered<NativeController>()) {
      Get.find<NativeController>().searchFocusNode.unfocus();
    }
  });
}

class _ImageViewScreenState extends State<ImageViewScreen> with SingleTickerProviderStateMixin {
  late Uint8List imageBytes = widget.imageBytes;
  String get uri => widget.uri;

  // The recognised people in this photo (empty until looked up, or if there are none).
  List<PhotoFace> _faces = const [];

  // True while the photo's faces are being looked for and it takes a noticeable
  // moment (a photo the background scan hasn't reached): drives a subtle shimmer.
  bool _looking = false;
  String _scanMessage = 'Looking for faces';
  Timer? _poll;

  // Tells the phone which viewer is asking, so a scan queued for a viewer that has since
  // closed (flicking through unscanned photos) can be skipped.
  final int _token = DateTime.now().microsecondsSinceEpoch;

  // ---- the People button: everyone recognised in this photo, in a panel ----
  final GlobalKey<ZoomableImageState> _zoomKey = GlobalKey<ZoomableImageState>();
  bool _peopleOpen = false;
  int _peoplePulse = 0; // bumped to make the button draw the eye (a scan just found people)
  bool _sawGlow = false; // the scan took long enough to show the glow
  int? _pointedPerson;
  int _pointId = 0;
  FaceFlight? _flight;
  late final AnimationController _flightCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  /// The distinct people in the photo, biggest face first.
  List<VideoPerson> get _people {
    final sorted = [..._faces]..sort((a, b) => ((b.right - b.left) * (b.bottom - b.top)).compareTo((a.right - a.left) * (a.bottom - a.top)));
    final seen = <int>{};
    final out = <VideoPerson>[];
    for (final f in sorted) {
      if (seen.add(f.person.id)) out.add(VideoPerson(person: f.person, times: const []));
    }
    return out;
  }

  // A person picked in the panel: their face flies to their head in the picture and becomes the
  // outline - the same transition as in a video, without a seek to wait for.
  Future<void> _pointAtPerson(VideoPerson vp, Rect from) async {
    final zoom = _zoomKey.currentState;
    final face = _faces.where((f) => f.person.id == vp.person.id).firstOrNull;
    if (zoom == null || face == null) return;
    setState(() {
      _peopleOpen = false;
      _pointedPerson = vp.person.id;
    });
    final id = ++_pointId;
    // Zoomed in, the head may be out of view: bring the whole picture back first.
    await zoom.resetZoom();
    if (!mounted || id != _pointId) return;

    final entry = RingEntry.random();
    final head = zoom.headOnScreen(face);
    if (head == null) {
      zoom.pointAt(face, entry);
      return;
    }
    setState(() {
      _flight = FaceFlight(faceId: vp.person.coverFaceId, from: from.center, to: head.center, endRadius: head.radius, entry: entry);
    });
    _flightCtrl.value = 0;
    await _flightCtrl
        .animateTo(FaceFlightOverlay.landingAt, duration: const Duration(milliseconds: 620), curve: Curves.linear)
        .orCancel
        .then((_) {}, onError: (_) {});
    if (!mounted || id != _pointId) return;
    zoom.pointAt(face, entry);
    await _flightCtrl
        .animateTo(1.0, duration: const Duration(milliseconds: 160), curve: Curves.easeOut)
        .orCancel
        .then((_) {}, onError: (_) {});
    if (mounted && id == _pointId) setState(() => _flight = null);
  }

  @override
  void initState() {
    super.initState();
    if (widget.loadFullRes) _loadSharp();
    _loadFaces();
  }

  @override
  void dispose() {
    _flightCtrl.dispose();
    _poll?.cancel();
    NativeServices().cancelPhotoFaces(_token).catchError((_) {});
    _dropSearchFocus();
    super.dispose();
  }

  Future<void> _loadFaces() async {
    // Already-scanned photos answer at once; only show the shimmer if it drags on.
    final slow = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      setState(() {
        _looking = true;
        _sawGlow = true;
        _scanMessage = 'Looking for faces'; // not what the last scan ended on
      });
      // While it works, ask how far it has got and say so.
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(milliseconds: 250), (_) async {
        try {
          final status = await NativeServices().photoScanStatus(uri);
          if (mounted && _looking && status != null && status.message != _scanMessage) {
            setState(() => _scanMessage = status.message);
          }
        } catch (_) {}
      });
    });
    try {
      final found = await NativeServices().photoFaces(uri, token: _token);
      if (mounted && (found.isNotEmpty || _faces.isNotEmpty)) {
        final firstPeople = _faces.isEmpty && found.isNotEmpty;
        setState(() {
          _faces = found;
          // A scan just found people (it was long enough to show): point at where they are.
          if (firstPeople && _sawGlow) _peoplePulse++;
        });
      }
    } catch (_) {
      // No faces to tap - the photo is still fully usable.
    } finally {
      slow.cancel();
      _poll?.cancel();
      if (mounted && _looking) setState(() => _looking = false);
    }
  }

  Future<void> _openPerson(Person person) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => PersonScreen(person: person)));
    // Back from their page: they may have been renamed, merged or hidden there.
    if (mounted) _loadFaces();
  }

  Future<void> _loadSharp() async {
    try {
      final sharp = await NativeServices().loadImageBytes(
        uri: uri,
        isCompressed: true,
      );
      if (mounted) setState(() => imageBytes = sharp);
    } catch (_) {
      // Keep showing the thumbnail - blurry beats blank.
    }
  }

  @override
  Widget build(BuildContext context) {
    return GetBuilder<NativeController>(
      builder: (controller) {
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: kMediaOverlayStyle,
          // Leaving: make sure the search box doesn't get its focus (and keyboard) back.
          child: PopScope(
            onPopInvokedWithResult: (_, __) {
              if (Get.isRegistered<NativeController>()) {
                Get.find<NativeController>().searchFocusNode.unfocus();
              }
            },
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
                      key: _zoomKey,
                      imageBytes: imageBytes,
                      onSingleTap: () {
                        if (_peopleOpen) {
                          setState(() => _peopleOpen = false);
                        } else {
                          controller.hideMetadata();
                        }
                      },
                      faces: _faces,
                      onOpenPerson: _openPerson,
                      captionInset: _faces.isEmpty ? 0 : 44,
                    ),
                  ),

                  Positioned.fill(child: PhotoScanGlow(visible: _looking, message: _scanMessage)),

                  // The people in this photo (opens a panel above): out of the way while the details are up.
                  if (_faces.isNotEmpty && !controller.showMetadata) ...[
                    if (_peopleOpen)
                      Positioned(
                        left: AppSpacing.base,
                        right: AppSpacing.base,
                        bottom: MediaQuery.of(context).padding.bottom + 84,
                        child: VideoPeoplePanel(
                          people: _people,
                          focusedId: _pointedPerson,
                          onTap: _pointAtPerson,
                          noun: 'photo',
                        ),
                      ),
                    Positioned(
                      right: AppSpacing.base,
                      bottom: MediaQuery.of(context).padding.bottom + AppSpacing.xl,
                      child: PeopleChipButton(
                        count: _people.length,
                        pulse: _peoplePulse,
                        open: _peopleOpen,
                        onTap: () => setState(() => _peopleOpen = !_peopleOpen),
                      ),
                    ),
                  ],

                  // Their face, flying from the panel to their head.
                  if (_flight != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedBuilder(
                          animation: _flightCtrl,
                          builder: (context, _) => FaceFlightOverlay(flight: _flight!, t: _flightCtrl.value),
                        ),
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
                            colors: [
                              Colors.black.withValues(alpha: 0.45),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  Positioned(
                    top: MediaQuery.of(context).padding.top + AppSpacing.sm,
                    left: AppSpacing.sm,
                    child: MediaChromeButton(
                      icon: Icons.close,
                      tooltip: 'Close',
                      onTap: () => Get.back(),
                    ),
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
                            controller.searchWithImage(
                              uri: uri,
                              bytes: imageBytes,
                            );
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
                          icon: controller.showMetadata
                              ? Icons.info
                              : Icons.info_outline,
                          tooltip: 'Details',
                          active: controller.showMetadata,
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
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
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
                value: metadata.fileName.isNotEmpty
                    ? metadata.fileName
                    : 'Unknown',
              ),
              InfoRow(
                icon: Icons.folder_outlined,
                label: 'File path',
                value: metadata.imagePath.isNotEmpty
                    ? metadata.imagePath
                    : 'Unknown',
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
                if (metadata.cameraMake.isNotEmpty ||
                    metadata.cameraModel.isNotEmpty)
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
