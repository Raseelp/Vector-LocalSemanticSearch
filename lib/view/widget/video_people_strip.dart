import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';

/// The small button in the video's controls: a face and how many people are in the video.
/// Tapping it opens the [VideoPeoplePanel]. When [pulse] changes (a scan just finished, or
/// someone new turned up) it draws the eye to itself - the button grows a touch and two soft
/// rings spread out from it - so nobody misses that the people are there.
class PeopleChipButton extends StatefulWidget {
  const PeopleChipButton({super.key, required this.count, required this.open, required this.onTap, this.pulse = 0});

  final int count;
  final bool open;
  final VoidCallback onTap;
  final int pulse;

  @override
  State<PeopleChipButton> createState() => _PeopleChipButtonState();
}

class _PeopleChipButtonState extends State<PeopleChipButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));

  @override
  void didUpdateWidget(covariant PeopleChipButton old) {
    super.didUpdateWidget(old);
    if (widget.pulse != old.pulse) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = widget.open;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final v = _c.value;
        // A soft swell at the start, then it settles.
        final swell = v < 0.3 ? math.sin(math.pi * (v / 0.3)) : 0.0;
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            if (_c.isAnimating)
              Positioned.fill(
                child: IgnorePointer(child: CustomPaint(painter: _PulsePainter(v))),
              ),
            Transform.scale(scale: 1 + 0.08 * swell, child: child),
          ],
        );
      },
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: open ? 0.62 : 0.46),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: open ? const Color(0xFF5FE0CF).withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.2),
              width: open ? 1.6 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.face_retouching_natural, size: 18, color: open ? const Color(0xFF9FF0E4) : Colors.white),
              const SizedBox(width: AppSpacing.xs + 2),
              Text(
                '${widget.count}',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 2),
              Icon(open ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded, size: 18, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}

// Two rings, one after the other, spreading out from the button's edge and fading.
class _PulsePainter extends CustomPainter {
  _PulsePainter(this.v);

  final double v;

  @override
  void paint(Canvas canvas, Size size) {
    for (var k = 0; k < 2; k++) {
      final p = ((v - k * 0.26) / 0.62).clamp(0.0, 1.0);
      if (p <= 0 || p >= 1) continue;
      final spread = 2 + 16 * Curves.easeOutCubic.transform(p);
      final alpha = 0.7 * (1 - Curves.easeIn.transform(p));
      final box = RRect.fromRectAndRadius(
        (Offset.zero & size).inflate(spread),
        Radius.circular(size.height / 2 + spread),
      );
      canvas.drawRRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFF5FE0CF).withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PulsePainter old) => old.v != v;
}

/// The people found in a video, opened from the [PeopleChipButton]: a row of big faces with
/// their names, scrolling sideways when there are many. Tapping one jumps to where they appear
/// (and shows their moments on the bar); tapping the same face again goes to their next
/// appearance. It closes after a pick, so it only covers the picture for a moment.
class VideoPeoplePanel extends StatelessWidget {
  const VideoPeoplePanel({
    super.key,
    required this.people,
    required this.focusedId,
    required this.onTap,
    this.noun = 'video',
  });

  /// What the people are in: 'video' or 'photo'.
  final String noun;

  final List<VideoPerson> people;
  final int? focusedId;

  /// The person picked, and where their face was on screen (the transition starts there).
  final void Function(VideoPerson person, Rect faceOnScreen) onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(0, AppSpacing.md, 0, AppSpacing.md),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: const Color(0xFF5FE0CF).withValues(alpha: 0.28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
              child: Text(
                people.length == 1 ? 'In this $noun' : '${people.length} people in this $noun',
                style: textTheme.labelMedium?.copyWith(color: Colors.white.withValues(alpha: 0.75)),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              height: 98,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
                itemCount: people.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.md),
                itemBuilder: (context, i) {
                  final p = people[i];
                  return _PanelFace(person: p, focused: p.person.id == focusedId, onTap: (rect) => onTap(p, rect));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelFace extends StatelessWidget {
  const _PanelFace({required this.person, required this.focused, required this.onTap});

  final VideoPerson person;
  final bool focused;
  final void Function(Rect faceOnScreen) onTap;

  static const double _size = 58;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final name = person.person.name ?? 'Unnamed';

    return SizedBox(
      width: 72,
      child: Column(
        children: [
          Builder(
            builder: (avatarContext) => GestureDetector(
              onTap: () {
                final box = avatarContext.findRenderObject() as RenderBox?;
                if (box == null || !box.hasSize) return;
                onTap(box.localToGlobal(Offset.zero) & box.size);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.all(2.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: focused ? const Color(0xFF5FE0CF) : Colors.white.withValues(alpha: 0.18),
                    width: focused ? 2.5 : 1.2,
                  ),
                ),
                child: FaceAvatar(faceId: person.person.coverFaceId, size: _size),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: textTheme.labelSmall?.copyWith(
              color: focused ? Colors.white : Colors.white.withValues(alpha: 0.78),
              fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small dots on the playback bar at each moment the picked person shows up.
class SightingMarkersPainter extends CustomPainter {
  SightingMarkersPainter({required this.times, required this.durationMs});

  final List<int> times;
  final int durationMs;

  @override
  void paint(Canvas canvas, Size size) {
    if (durationMs <= 0 || times.isEmpty) return;
    final y = size.height / 2;
    for (final t in times) {
      final x = (t / durationMs).clamp(0.0, 1.0) * size.width;
      final at = Offset(math.min(math.max(x, 3.0), size.width - 3.0), y);
      canvas.drawCircle(at, 4.6, Paint()..color = Colors.black.withValues(alpha: 0.55));
      canvas.drawCircle(at, 3.2, Paint()..color = const Color(0xFF5FE0CF));
    }
  }

  @override
  bool shouldRepaint(covariant SightingMarkersPainter old) => old.times != times || old.durationMs != durationMs;
}
