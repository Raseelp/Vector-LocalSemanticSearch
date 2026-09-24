import 'package:flutter/material.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';

// A bottom sheet that tracks the finger while dragging its handle and
// flings open/closed based on release velocity - the Instagram-comments
// feel, instead of a hard binary toggle. The old version wrapped its
// *entire* content (including the scrollable metadata list) in one
// onVerticalDragUpdate, which the inner SingleChildScrollView's own
// vertical-drag recognizer almost always won against in Flutter's gesture
// arena - which is why it "couldn't drag down." Restricting the drag
// recognizer to just the handle bar removes that conflict entirely.
//
// [visible] is the source of truth for open/closed from outside (e.g. an
// info button); dragging the handle can also close it, reported back
// through [onDismissed] so the caller's own state stays in sync.
class DraggableMetadataSheet extends StatefulWidget {
  const DraggableMetadataSheet({
    super.key,
    required this.visible,
    required this.onDismissed,
    required this.heightFactor,
    required this.child,
  });

  final bool visible;
  final VoidCallback onDismissed;
  final double heightFactor;
  final Widget child;

  @override
  State<DraggableMetadataSheet> createState() => _DraggableMetadataSheetState();
}

class _DraggableMetadataSheetState extends State<DraggableMetadataSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant DraggableMetadataSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _controller.animateTo(1, curve: Curves.easeOutCubic);
    } else {
      _controller.animateTo(0, curve: Curves.easeIn);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details, double sheetHeight) {
    final delta = details.primaryDelta ?? 0;
    _controller.value = (_controller.value - delta / sheetHeight).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    // A decisive flick wins regardless of how far it's travelled yet;
    // otherwise whichever side of halfway it landed on.
    final shouldOpen = velocity < -300
        ? true
        : velocity > 300
        ? false
        : _controller.value > 0.5;

    if (shouldOpen) {
      _controller.animateTo(1, curve: Curves.easeOutCubic);
    } else {
      _controller.animateTo(0, curve: Curves.easeIn).whenComplete(widget.onDismissed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sheetHeight = MediaQuery.of(context).size.height * widget.heightFactor;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Positioned(
          left: 0,
          right: 0,
          bottom: -sheetHeight * (1 - _controller.value),
          child: Container(
            height: sheetHeight,
            decoration: const BoxDecoration(
              color: AppColors.canvas,
              borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
            ),
            child: Column(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (d) => _onDragUpdate(d, sheetHeight),
                  onVerticalDragEnd: _onDragEnd,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    child: Center(child: _DragHandle()),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                // Only mounted while there's any visibility, torn down
                // once fully closed - so an entrance animation inside
                // `child` (like the match-strength bars) replays every
                // time the sheet opens, instead of only playing once on
                // first build (invisibly, before the sheet ever slid into
                // view, back when it stayed permanently mounted offscreen).
                Expanded(child: _controller.value > 0 ? widget.child : const SizedBox.shrink()),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: AppColors.hairline,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
    );
  }
}
