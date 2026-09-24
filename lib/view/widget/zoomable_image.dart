import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';

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
  const ZoomableImage({super.key, required this.imageBytes, required this.onSingleTap});

  final Uint8List imageBytes;
  final VoidCallback onSingleTap;

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> with SingleTickerProviderStateMixin {
  final TransformationController _transformController = TransformationController();
  late final AnimationController _animController;
  Animation<Matrix4>? _zoomAnimation;

  double _currentScale = 1.0;
  bool _showZoomPill = false;
  Timer? _hidePillTimer;

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
            onTap: widget.onSingleTap,
            onDoubleTapDown: _handleDoubleTapDown,
            // Required alongside onDoubleTapDown for Flutter to actually
            // recognize the double tap - the position comes from the
            // onDoubleTapDown callback above, this one's body is unused.
            onDoubleTap: () {},
            child: InteractiveViewer(
              transformationController: _transformController,
              minScale: _minScale,
              maxScale: _maxScale,
              child: Image.memory(widget.imageBytes, fit: BoxFit.contain),
            ),
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
