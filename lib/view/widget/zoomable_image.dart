import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/photo_faces_layer.dart';

const double _minScale = 1.0;
const double _maxScale = 5.0;
const double _doubleTapScale = 3.0;

// Pinch-to-zoom (InteractiveViewer's own gesture handling) plus double-tap-
// to-zoom toward wherever was tapped (InteractiveViewer doesn't provide
// that on its own - built here the same way Flutter's own cookbook example
// does it, animating the transform matrix rather than snapping). A zoom-%
// pill fades in while zoomed and fades back out shortly after the gesture
// settles, and a light haptic tick marks crossing back to 1x or hitting the
// zoom ceiling.
class ZoomableImage extends StatefulWidget {
  const ZoomableImage({
    super.key,
    required this.imageBytes,
    required this.onSingleTap,
    this.faces = const [],
    this.onOpenPerson,
    this.captionInset = 0,
  });

  /// Extra room kept clear along the bottom for the "tap a face" line (the viewer's own buttons).
  final double captionInset;

  final Uint8List imageBytes;
  final VoidCallback onSingleTap;

  /// Recognised people in the photo: each can be tapped to reveal who it is.
  final List<PhotoFace> faces;
  final ValueChanged<Person>? onOpenPerson;

  @override
  State<ZoomableImage> createState() => ZoomableImageState();
}

/// Where a head is on screen right now (centre in global coordinates, and its radius).
class HeadOnScreen {
  const HeadOnScreen(this.center, this.radius);

  final Offset center;
  final double radius;
}

class ZoomableImageState extends State<ZoomableImage> with SingleTickerProviderStateMixin {
  final TransformationController _transformController = TransformationController();
  late final AnimationController _animController;
  Animation<Matrix4>? _zoomAnimation;

  double _currentScale = 1.0;
  bool _showZoomPill = false;
  Timer? _hidePillTimer;

  // When the photo is swapped for a sharper one (a thumbnail first, the real
  // thing a moment later), the old one stays underneath while the new one is
  // decoded and then fades in over it - so there is never a blank frame or a
  // jump between the two.
  Uint8List? _underlay;

  // The face currently picked (ring + name chip showing), if any.
  PhotoFace? _selectedFace;
  RingEntry? _ringEntry; // set when a face was picked from outside and a flight lands on it

  /// Brings the whole picture back into view (so every head is on screen); done when it has.
  Future<void> resetZoom() async {
    if (_transformController.value.getMaxScaleOnAxis() <= 1.02) return;
    _zoomAnimation = Matrix4Tween(
      begin: _transformController.value,
      end: Matrix4.identity(),
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic));
    await _animController.forward(from: 0).orCancel.then((_) {}, onError: (_) {});
  }

  /// Where [face]'s head is on screen now, following the zoom and pan.
  HeadOnScreen? headOnScreen(PhotoFace face) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final spot = headSpotFor(face, box.size);
    if (spot == null) return null;
    final m = _transformController.value;
    return HeadOnScreen(box.localToGlobal(MatrixUtils.transformPoint(m, spot.center)), spot.radius * m.getMaxScaleOnAxis());
  }

  /// Picks [face] from outside (the people panel): the outline draws in the band [entry] a flight
  /// is landing with.
  void pointAt(PhotoFace face, RingEntry entry) {
    setState(() {
      _ringEntry = entry;
      _selectedFace = face;
    });
  }

  @override
  void didUpdateWidget(covariant ZoomableImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.imageBytes, widget.imageBytes)) _underlay = oldWidget.imageBytes;

    // The people were looked up again: keep the same face picked, now with fresh details.
    if (!identical(oldWidget.faces, widget.faces) && _selectedFace != null) {
      final id = _selectedFace!.faceId;
      _selectedFace = widget.faces.where((f) => f.faceId == id).firstOrNull;
    }
  }

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )..addListener(() {
      final anim = _zoomAnimation;
      if (anim != null) _transformController.value = anim.value;
    });
    _transformController.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _hidePillTimer?.cancel();
    _transformController.removeListener(_onTransformChanged);
    _transformController.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final scale = _transformController.value.getMaxScaleOnAxis();
    final previous = _currentScale;
    if ((scale - previous).abs() < 0.01) return;

    final backToFit = scale <= 1.01 && previous > 1.01;
    final hitCeiling = scale >= _maxScale - 0.01 && previous < _maxScale - 0.01;
    if (backToFit || hitCeiling) {
      HapticFeedback.selectionClick();
    }

    setState(() {
      _currentScale = scale;
      _showZoomPill = scale > 1.05;
    });

    _hidePillTimer?.cancel();
    _hidePillTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showZoomPill = false);
    });
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    final position = details.localPosition;
    final isZoomedIn = _transformController.value.getMaxScaleOnAxis() > 1.5;
    final targetScale = isZoomedIn ? _minScale : _doubleTapScale;

    final target = targetScale == _minScale
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translate(-position.dx * (targetScale - 1), -position.dy * (targetScale - 1))
            ..scale(targetScale));

    _zoomAnimation = Matrix4Tween(
      begin: _transformController.value,
      end: target,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic));
    _animController.forward(from: 0);
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            // A tap on empty photo first puts away a picked face, then behaves as usual.
            onTap: () {
              if (_selectedFace != null) {
                setState(() {
                  _selectedFace = null;
                  _ringEntry = null;
                });
              } else {
                widget.onSingleTap();
              }
            },
            onDoubleTapDown: _handleDoubleTapDown,
            // Required alongside onDoubleTapDown for Flutter to actually
            // recognize the double tap - the position comes from the
            // onDoubleTapDown callback above, this one's body is unused.
            onDoubleTap: () {},
            child: InteractiveViewer(
              transformationController: _transformController,
              minScale: _minScale,
              maxScale: _maxScale,
              child: SizedBox.expand(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_underlay != null)
                      Image.memory(_underlay!, fit: BoxFit.contain, gaplessPlayback: true),
                    Image.memory(
                      widget.imageBytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      // Already in memory: show at once. Otherwise fade in when the
                      // first frame is ready (nothing shows until then, so the
                      // underlay stays visible).
                      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                        if (wasSynchronouslyLoaded || _underlay == null) return child;
                        return AnimatedOpacity(
                          opacity: frame == null ? 0 : 1,
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOut,
                          child: child,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (widget.faces.isNotEmpty && widget.onOpenPerson != null)
          Positioned.fill(
            child: PhotoFacesLayer(
              faces: widget.faces,
              transform: _transformController,
              selected: _selectedFace,
              onSelect: (face) => setState(() {
                _ringEntry = null;
                _selectedFace = face;
              }),
              onOpen: widget.onOpenPerson!,
              entry: _ringEntry,
              bottomInset: widget.captionInset,
            ),
          ),
        IgnorePointer(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
              child: AnimatedOpacity(
                opacity: _showZoomPill ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    '${(_currentScale * 100).round()}%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
