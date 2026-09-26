import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';

// The colours of the selection outline: the app's teal (lightened so it glows on a
// photo) flowing into cool blue, violet, pink and warm gold, and back to teal.
const List<Color> _ringColors = [
  Color(0xFF5FE0CF),
  Color(0xFF7AD7FF),
  Color(0xFFB388FF),
  Color(0xFFFF8AD8),
  Color(0xFFFFC46B),
  Color(0xFF5FE0CF),
];

// Everything below is drawn WITHOUT blur filters and with the transparency baked into the
// colours themselves: a blurred, gradient-shaded stroke can render as a hard rectangle on
// some GPUs (the flash of squares), and a paint's own alpha is not reliably applied on top
// of a gradient. A soft glow is built from a few widening, fainter strokes instead.

Shader _sweepShader(Offset centre, double radius, double rotation, int tint, double alpha) {
  final colours = [..._ringColors.skip(tint), ..._ringColors.take(tint + 1)]
      .map((c) => c.withValues(alpha: alpha))
      .toList();
  return SweepGradient(colors: colours, transform: GradientRotation(rotation))
      .createShader(Rect.fromCircle(center: centre, radius: radius));
}

/// [path] as a glowing line: soft wide strokes underneath, a crisp thin one on top.
void _glowStroke(Canvas canvas, Path path, Offset centre, double radius, double rotation, int tint,
    {required double alpha, double line = 2.4, double glow = 1.0, bool soft = true}) {
  const layers = [
    [15.0, 0.07],
    [10.0, 0.11],
    [6.0, 0.17],
  ];
  // A crowded photo gets one soft layer instead of three: same look at a glance, a third of the work.
  final used = soft ? layers : const [[9.0, 0.15]];
  final rect = radius * 1.2;
  for (final l in used) {
    canvas.drawPath(
      path,
      Paint()
        ..shader = _sweepShader(centre, rect, rotation, tint, alpha * l[1] * glow)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = l[0],
    );
  }
  canvas.drawPath(
    path,
    Paint()
      ..shader = _sweepShader(centre, rect, rotation, tint, alpha * 0.9)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = line,
  );
}

/// A small soft light (a radial fade, not a blur).
void _light(Canvas canvas, Offset at, double radius, Color colour, double alpha) {
  canvas.drawCircle(
    at,
    radius,
    Paint()
      ..shader = RadialGradient(
        colors: [colour.withValues(alpha: alpha), colour.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: at, radius: radius)),
  );
}

/// A living outline: a circle whose edge swells and dips in a few slow waves, so it
/// reads as a small amoeba rather than a ring. [phase] runs 0..1 and the motion
/// loops seamlessly (every wave turns a whole number of times per loop);
/// [wobble] > 0 exaggerates it (used while the outline settles in).
double _blobRadius(double angle, double radius, double phase, double wobble, [double offset = 0]) {
  final t = phase * 2 * math.pi + offset;
  final wave = 0.055 * math.sin(2 * angle + t) +
      0.045 * math.sin(3 * angle - 2 * t + 1.3) +
      0.030 * math.sin(5 * angle + t + 2.6) +
      0.022 * math.sin(4 * angle - t + 0.7);
  return radius * (1 + wave * (1 + 1.6 * wobble));
}

Path _blobPath(Offset center, double radius, double phase, double wobble,
    {double offset = 0, double start = -math.pi / 2, int steps = 140}) {
  final path = Path();
  for (var i = 0; i <= steps; i++) {
    final a = start + i / steps * 2 * math.pi;
    final r = _blobRadius(a, radius, phase, wobble, offset);
    final point = center + Offset(math.cos(a), math.sin(a)) * r;
    if (i == 0) {
      path.moveTo(point.dx, point.dy);
    } else {
      path.lineTo(point.dx, point.dy);
    }
  }
  return path..close();
}

/// The dice for one showing of an effect, so no two look the same: where the outline
/// starts, which way it turns, what shape the waves begin in, where the sparkle lands.
class _Roll {
  _Roll(math.Random r)
      : offset = r.nextDouble() * 2 * math.pi,
        start = r.nextDouble() * 2 * math.pi,
        dir = r.nextBool() ? 1.0 : -1.0,
        sparkleAngle = (r.nextBool() ? -1 : 1) * (0.25 + r.nextDouble() * 1.2) - (r.nextBool() ? 0 : math.pi),
        tint = r.nextInt(_ringColors.length - 1),
        lag = r.nextDouble() * 0.12;

  final double offset;
  final double start;
  final double dir;
  final double sparkleAngle;
  final int tint; // which colour the outline starts on
  final double lag; // fraction of the hint's length this face waits before starting
}

/// Paints whatever [draw] does, and repaints whenever [repaint] fires - so an animation
/// can redraw every frame without its widget tree being rebuilt.
class _LivePainter extends CustomPainter {
  _LivePainter({required Listenable repaint, required this.draw}) : super(repaint: repaint);

  final void Function(Canvas canvas, Size size) draw;

  @override
  void paint(Canvas canvas, Size size) => draw(canvas, size);

  @override
  bool shouldRepaint(covariant _LivePainter old) => true;
}

/// Where a face sits on screen right now: the centre and radius of a circle
/// around the whole head, following the photo as it is zoomed and panned.
class _Head {
  const _Head(this.center, this.radius);

  final Offset center;
  final double radius;
}

/// Lets you tap the people in a photo. Every recognised face is a tap target;
/// tapping one dims the rest of the photo, draws a glowing ring around the head
/// that sweeps round it, and pops up that person's picture - tap it to go to
/// their page. A brief ripple on first showing hints that faces can be tapped.
///
/// It sits over the zoomable photo and follows its transform, so it stays on the
/// head while pinching and panning (and the ring keeps its thickness at any zoom).
class PhotoFacesLayer extends StatefulWidget {
  const PhotoFacesLayer({
    super.key,
    required this.faces,
    required this.transform,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
  });

  final List<PhotoFace> faces;
  final TransformationController transform;
  final PhotoFace? selected;
  final ValueChanged<PhotoFace?> onSelect;
  final ValueChanged<Person> onOpen;

  @override
  State<PhotoFacesLayer> createState() => _PhotoFacesLayerState();
}

class _PhotoFacesLayerState extends State<PhotoFacesLayer> with TickerProviderStateMixin {
  late final AnimationController _enter =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 720));
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 7000));
  late final AnimationController _hint =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));

  // What is drawn: kept while the ring animates out after a deselect.
  PhotoFace? _shown;

  final math.Random _rng = math.Random();
  _Roll _selRoll = _Roll(math.Random());
  List<_Roll> _hintRolls = const [];

  @override
  void initState() {
    super.initState();
    // Once the photo has settled, the faces are faintly traced and each gets a small
    // sparkle - the sign that it can be tapped - and a line says what it means.
    // Different every time, and gone again within a few seconds.
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted || widget.selected != null) return;
      _hintRolls = List.generate(widget.faces.length, (_) => _Roll(_rng));
      _hint.forward();
    });
  }

  @override
  void didUpdateWidget(covariant PhotoFacesLayer old) {
    super.didUpdateWidget(old);
    final now = widget.selected;
    if (identical(now, old.selected)) return;
    // The same face with refreshed details (a rename): update in place, no new animation.
    if (now != null && old.selected != null && now.faceId == old.selected!.faceId) {
      _shown = now;
      return;
    }
    if (now != null) {
      _shown = now;
      _selRoll = _Roll(_rng);
      _hint.stop();
      _hint.value = 1; // the ripple is done once you've found it
      _enter.forward(from: 0);
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _enter.reverse().whenComplete(() {
        if (!mounted || widget.selected != null) return;
        _spin.stop();
        setState(() => _shown = null);
      });
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _spin.dispose();
    _hint.dispose();
    super.dispose();
  }

  // The latest details of a person (a rename made elsewhere shows at once): the
  // Faces list is kept up to date; someone not listed there keeps what was looked up.
  Person _live(Person p) {
    final faces = Get.find<FacesController>();
    for (final listed in faces.people) {
      if (listed.id == p.id) return listed;
    }
    return p;
  }

  _Head? _headOf(PhotoFace f, Size size) {
    if (f.photoW <= 0 || f.photoH <= 0) return null;

    // Where the photo sits inside the viewer (it is shown "contain"-fitted).
    final aspect = f.photoW / f.photoH;
    final double w, h;
    if (size.width / size.height > aspect) {
      h = size.height;
      w = h * aspect;
    } else {
      w = size.width;
      h = w / aspect;
    }
    final origin = Offset((size.width - w) / 2, (size.height - h) / 2);

    final faceW = (f.right - f.left) * w;
    final faceH = (f.bottom - f.top) * h;
    // Around the whole head rather than the face box: a little bigger, a little higher.
    final scene = origin + Offset((f.left + f.right) / 2 * w, (f.top + f.bottom) / 2 * h - faceH * 0.06);
    final sceneRadius = math.max(faceW, faceH) * 0.5 * 1.4;

    final m = widget.transform.value;
    return _Head(MatrixUtils.transformPoint(m, scene), sceneRadius * m.getMaxScaleOnAxis());
  }

  // Where every face is right now.
  Map<PhotoFace, _Head> _headsFor(Size size) {
    final heads = <PhotoFace, _Head>{};
    for (final f in widget.faces) {
      final head = _headOf(f, size);
      if (head != null) heads[f] = head;
    }
    return heads;
  }

  // The things that animate every frame (the hint, the ring) are painted by painters that
  // repaint themselves; the widgets around them are not rebuilt per frame. That matters in a
  // big group photo, where rebuilding dozens of tap targets sixty times a second is what
  // used to make the moment the outlines appear stutter.
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final shown = _shown;

        return Stack(
          fit: StackFit.expand,
          children: [
            // The hint: outlines and sparkles on every face, for a moment.
            if (widget.selected == null)
              IgnorePointer(
                child: CustomPaint(
                  painter: _LivePainter(
                    repaint: Listenable.merge([_hint, widget.transform]),
                    draw: (canvas, size) {
                      if (!_hint.isAnimating) return;
                      _HintPainter(_headsFor(size).values.toList(), _hintRolls, _hint.value).paint(canvas, size);
                    },
                  ),
                ),
              ),

            // Dimmed photo with a hole around the head, and the ring.
            if (shown != null)
              IgnorePointer(
                child: CustomPaint(
                  painter: _LivePainter(
                    repaint: Listenable.merge([_enter, _spin, widget.transform]),
                    draw: (canvas, size) {
                      final head = _headOf(shown, size);
                      if (head == null) return;
                      _RingPainter(
                        center: head.center,
                        radius: head.radius,
                        progress: _enter.value,
                        spin: _spin.value * 2 * math.pi,
                        roll: _selRoll,
                      ).paint(canvas, size);
                    },
                  ),
                ),
              ),

            // Tap targets (at least a fingertip wide): they only move with the photo.
            AnimatedBuilder(
              animation: widget.transform,
              builder: (context, _) {
                final heads = _headsFor(size);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final entry in heads.entries)
                      Positioned(
                        left: entry.value.center.dx - math.max(entry.value.radius, 26),
                        top: entry.value.center.dy - math.max(entry.value.radius, 26),
                        width: math.max(entry.value.radius, 26) * 2,
                        height: math.max(entry.value.radius, 26) * 2,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: () {
                            if (identical(widget.selected, entry.key)) {
                              widget.onOpen(_live(entry.key.person));
                            } else {
                              HapticFeedback.selectionClick();
                              widget.onSelect(entry.key);
                            }
                          },
                        ),
                      ),
                  ],
                );
              },
            ),

            // (Positioned widgets must sit directly in a Stack, hence the fill + inner Stack.)
            if (widget.selected == null)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _hint,
                  builder: (context, _) => Stack(children: [_captionPill()]),
                ),
              ),

            if (shown != null)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_enter, widget.transform]),
                  builder: (context, _) {
                    final head = _headOf(shown, size);
                    return Stack(children: [if (head != null) _chip(shown, head, size)]);
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  // "Tap a face to see who": fades in and out with the hint, low on the screen, in the
  // same frosted glass as the viewer's other floating controls.
  Widget _captionPill() {
    final p = _hint.value;
    final opacity = (Interval(0.08, 0.22).transform(p) * (1 - Interval(0.78, 0.95).transform(p))).clamp(0.0, 1.0);
    if (opacity <= 0) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.of(context).padding.bottom + AppSpacing.xxl,
      child: IgnorePointer(
        child: Center(
          child: Opacity(
            opacity: opacity,
            child: Transform.translate(
              offset: Offset(0, AppSpacing.xs * (1 - opacity)),
              child: const _FlowText(
                'Tap a face to see who',
                leading: Icon(Icons.face_outlined, size: 20, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // The person's picture and name, under the head (above it near the bottom).
  Widget _chip(PhotoFace face, _Head head, Size size) {
    const chipHeight = 64.0;
    var y = head.center.dy + head.radius + 14;
    if (y + chipHeight > size.height - 28) y = head.center.dy - head.radius - 14 - chipHeight;
    y = y.clamp(76.0, math.max(76.0, size.height - chipHeight - 28));

    // Centred under the head, but never off the screen.
    final x = (head.center.dx / size.width * 2 - 1).clamp(-1.0, 1.0);

    final t = Curves.easeOutBack.transform(Interval(0.3, 1.0).transform(_enter.value));
    final opacity = Interval(0.3, 0.75, curve: Curves.easeOut).transform(_enter.value);

    return Positioned(
      left: 12,
      right: 12,
      top: y,
      child: Align(
        alignment: Alignment(x, -1),
        child: Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: 0.7 + 0.3 * t,
            alignment: Alignment.topCenter,
            child: GetBuilder<FacesController>(
              builder: (_) {
                final person = _live(face.person);
                return _PersonChip(person: person, onTap: () => widget.onOpen(person));
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The floating pill surface for this feature's text and name chip: a soft dark tint
/// with a hairline edge, in the viewer's pill shape. (No backdrop blur: these fade and
/// scale in and out, and a blur inside a fading layer can render as garbage on some phones.)
class _Glass extends StatelessWidget {
  const _Glass({required this.child, required this.padding});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: child,
    );
  }
}

/// A slide for a gradient: moves it sideways by [shift] of its own width.
class _Slide extends GradientTransform {
  const _Slide(this.shift);

  final double shift;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(shift * bounds.width, 0, 0);
}

/// The line of text under the photo ("Tap a face to see who", "Found 12 faces · identifying").
/// No box around it: the words themselves carry the effect. A soft highlight in the
/// app's colours keeps drifting through the letters, and whenever the words change the new
/// ones rise into place letter by letter. It stays legible over any photo through a
/// gentle shadow, not a container.
class _FlowText extends StatefulWidget {
  const _FlowText(this.text, {this.leading});

  final String text;
  final Widget? leading;

  @override
  State<_FlowText> createState() => _FlowTextState();
}

class _FlowTextState extends State<_FlowText> with TickerProviderStateMixin {
  late final AnimationController _shine = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..repeat();
  late final AnimationController _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 750))..forward();

  @override
  void didUpdateWidget(covariant _FlowText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _in.forward(from: 0);
  }

  @override
  void dispose() {
    _shine.dispose();
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.labelLarge;
    final size = (base?.fontSize ?? 14) + 1;
    // The text itself (tinted by the moving highlight) and, beneath it, the same letters
    // in nothing but a soft shadow - a shadow put on the tinted text would be tinted too.
    final fill = base?.copyWith(color: Colors.white, fontSize: size, fontWeight: FontWeight.w600);
    final shade = base?.copyWith(
      color: Colors.transparent,
      fontSize: size,
      fontWeight: FontWeight.w600,
      shadows: [
        Shadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 9),
        Shadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 2, offset: const Offset(0, 1)),
      ],
    );
    final letters = widget.text.split('');

    Widget row(TextStyle? style) {
      final n = letters.length;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var k = 0; k < n; k++)
            () {
              // Each letter starts a little after the one before it.
              final start = n <= 1 ? 0.0 : k / (n - 1) * 0.55;
              final o = Curves.easeOut.transform(Interval(start, start + 0.45).transform(_in.value));
              return Opacity(
                opacity: o,
                child: Transform.translate(offset: Offset(0, 8 * (1 - o)), child: Text(letters[k], style: style)),
              );
            }(),
        ],
      );
    }

    // The letters are rebuilt only while the words are rising in; afterwards just the
    // highlight moves (it re-shades the same letters), instead of ~80 widgets a frame.
    return AnimatedBuilder(
      animation: _in,
      builder: (context, _) {
        final shadeRow = row(shade);
        final fillRow = row(fill);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.leading != null) ...[widget.leading!, const SizedBox(width: AppSpacing.sm + 2)],
            Stack(
              children: [
                shadeRow,
                AnimatedBuilder(
                  animation: _shine,
                  child: fillRow,
                  builder: (context, child) => ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (rect) => LinearGradient(
                      colors: const [
                        Color(0xC8FFFFFF),
                        Color(0xC8FFFFFF),
                        Color(0xFF9FF0E4),
                        Color(0xFFFFFFFF),
                        Color(0xFFFFD0F0),
                        Color(0xC8FFFFFF),
                        Color(0xC8FFFFFF),
                      ],
                      stops: const [0.0, 0.3, 0.42, 0.5, 0.58, 0.7, 1.0],
                      // From fully off the left edge to fully off the right, once per loop.
                      transform: _Slide(_shine.value * 2 - 1),
                    ).createShader(rect),
                    child: child,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// A small four-point star that twinkles and slowly turns, in the colours of the rest.
class _TwinkleStar extends StatefulWidget {
  const _TwinkleStar();

  @override
  State<_TwinkleStar> createState() => _TwinkleStarState();
}

class _TwinkleStarState extends State<_TwinkleStar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3000))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 22,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(painter: _TwinkleStarPainter(_c.value)),
      ),
    );
  }
}

class _TwinkleStarPainter extends CustomPainter {
  _TwinkleStarPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final a = t * 2 * math.pi;
    final pulse = 0.78 + 0.22 * math.sin(2 * a); // breathes twice a loop
    final r = 8.5 * pulse;

    Path star(double radius, double turn) {
      final path = Path();
      for (var i = 0; i < 8; i++) {
        final ang = -math.pi / 2 + turn + i * math.pi / 4;
        final rr = i.isEven ? radius : radius * 0.27;
        final p = c + Offset(math.cos(ang), math.sin(ang)) * rr;
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      return path..close();
    }

    // Its colour drifts through the palette; a smaller, paler star turns the other way inside it.
    final f = t * (_ringColors.length - 1);
    final i0 = f.floor() % (_ringColors.length - 1);
    final colour = Color.lerp(_ringColors[i0], _ringColors[i0 + 1], f - f.floor())!;
    _light(canvas, c, 11, colour, 0.55);
    canvas.drawPath(star(r, a * 0.5), Paint()..color = colour.withValues(alpha: 0.95));
    canvas.drawPath(star(r * 0.55, -a * 0.8 + math.pi / 4), Paint()..color = Colors.white.withValues(alpha: 0.95));
  }

  @override
  bool shouldRepaint(covariant _TwinkleStarPainter old) => old.t != t;
}

class _PersonChip extends StatelessWidget {
  const _PersonChip({required this.person, required this.onTap});

  final Person person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final photos = person.photoCount;
    return GestureDetector(
      onTap: onTap,
      child: _Glass(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xs + 2, AppSpacing.xs + 2, AppSpacing.md, AppSpacing.xs + 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FaceAvatar(faceId: person.coverFaceId, size: 40),
            const SizedBox(width: AppSpacing.md - 2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.name ?? 'Unnamed',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleSmall?.copyWith(color: Colors.white),
                  ),
                  Text(
                    photos == 1 ? '1 photo' : '$photos photos',
                    style: textTheme.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.72)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Icon(Icons.chevron_right_rounded, size: 22, color: Colors.white.withValues(alpha: 0.8)),
          ],
        ),
      ),
    );
  }
}

/// The dimmed photo (with the head left clear) and a glowing outline that draws
/// itself round the head, then keeps turning slowly - starting and turning differently
/// each time ([roll]).
class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.center,
    required this.radius,
    required this.progress,
    required this.spin,
    required this.roll,
  });

  final Offset center;
  final double radius;
  final double progress; // 0 -> 1 as it appears
  final double spin; // radians
  final _Roll roll;

  @override
  void paint(Canvas canvas, Size size) {
    final t = Curves.easeOutCubic.transform(progress.clamp(0.0, 1.0));
    if (t <= 0) return;

    final loop = spin / (2 * math.pi);
    final phase = roll.dir > 0 ? loop : 1 - loop;
    final wobble = 1 - t; // wobbles most while it settles in

    final hole = _blobPath(center, radius * 1.06, phase, wobble, offset: roll.offset, start: roll.start);
    final everything = Path()..addRect(Offset.zero & size);
    canvas.drawPath(
      Path.combine(PathOperation.difference, everything, hole),
      Paint()..color = Colors.black.withValues(alpha: 0.5 * t),
    );

    // The outline settles in from a little wider.
    final r = radius * (1 + 0.14 * (1 - t));
    final outline = _blobPath(center, r, phase, wobble, offset: roll.offset, start: roll.start);

    // It draws itself round the head.
    Path drawn = outline;
    if (t < 1) {
      drawn = Path();
      for (final metric in outline.computeMetrics()) {
        drawn.addPath(metric.extractPath(0, metric.length * t), Offset.zero);
      }
    }
    _glowStroke(canvas, drawn, center, r, roll.start + roll.dir * spin * 1.5, roll.tint,
        alpha: t, line: 2.8, glow: 1.3);

    // Three tiny lights drifting along the edge.
    for (var k = 0; k < 3; k++) {
      final a = roll.start + roll.dir * spin * 1.6 + k * 2 * math.pi / 3;
      final p = center + Offset(math.cos(a), math.sin(a)) * _blobRadius(a, r, phase, wobble, roll.offset);
      _light(canvas, p, 9, Colors.white, 0.5 * t);
      canvas.drawCircle(p, 1.7, Paint()..color = Colors.white.withValues(alpha: t));
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.center != center || old.radius != radius || old.progress != progress || old.spin != spin;
}

/// The hint that faces can be tapped: every face's outline is faintly traced (each
/// starting at its own point, in its own time), then a small sparkle twinkles at the head
/// (on a different side each time); everything is gone by the end. [progress] 0..1.
class _HintPainter extends CustomPainter {
  _HintPainter(this.heads, this.rolls, this.progress);

  final List<_Head> heads;
  final List<_Roll> rolls;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    // Many faces at once (a big group): every one gets a lighter version, so the moment
    // they appear costs the same as a small photo.
    final crowded = heads.length > 8;
    for (var i = 0; i < heads.length; i++) {
      final h = heads[i];
      final roll = i < rolls.length ? rolls[i] : null;
      if (roll == null) continue;

      // Each face runs a touch behind or ahead of the others.
      final p = ((progress - roll.lag) / (1 - 0.12)).clamp(0.0, 1.0);
      final trace = Curves.easeOutCubic.transform(Interval(0.0, 0.4).transform(p));
      final glow = Interval(0.0, 0.18).transform(p) * (1 - Interval(0.62, 0.9).transform(p));
      final sparkleIn = Curves.elasticOut.transform(Interval(0.3, 0.55).transform(p));
      final sparkleOut = 1 - Interval(0.72, 0.95).transform(p);

      if (glow > 0) {
        // Small faces need few points to look round.
        final steps = (h.radius * 0.9).clamp(28.0, crowded ? 48.0 : 96.0).round();
        final outline = _blobPath(h.center, h.radius, p * 2, 0.25, offset: roll.offset, start: roll.start, steps: steps);
        var drawn = outline;
        if (trace < 1) {
          drawn = Path();
          for (final metric in outline.computeMetrics()) {
            drawn.addPath(metric.extractPath(0, metric.length * trace), Offset.zero);
          }
        }
        _glowStroke(canvas, drawn, h.center, h.radius, roll.start + roll.dir * p * math.pi * 2, roll.tint,
            alpha: glow * 0.8, line: 1.8, glow: 0.8, soft: !crowded);
      }

      if (sparkleIn > 0 && sparkleOut > 0) {
        final at = h.center + Offset(math.cos(roll.sparkleAngle), math.sin(roll.sparkleAngle)) * (h.radius * 1.02);
        final star = (9 + math.min(h.radius * 0.12, 6)) * sparkleIn;
        final twinkle = 1 + 0.12 * math.sin(p * math.pi * 6);
        _sparkle(canvas, at, star * twinkle, sparkleOut, p * 0.9 * roll.dir);
      }
    }
  }

  // A four-point star with a soft glow.
  void _sparkle(Canvas canvas, Offset c, double r, double opacity, double turn) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final a = -math.pi / 2 + turn + i * math.pi / 4;
      final rr = i.isEven ? r : r * 0.26;
      final pt = c + Offset(math.cos(a), math.sin(a)) * rr;
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    path.close();
    _light(canvas, c, r * 2.2, const Color(0xFF9FF0E4), 0.55 * opacity);
    canvas.drawPath(path, Paint()..color = Colors.white.withValues(alpha: 0.95 * opacity));
  }

  @override
  bool shouldRepaint(covariant _HintPainter old) => old.progress != progress || old.heads != heads;
}

/// Shown while a photo's faces are being looked for right now (it hadn't been scanned
/// yet). In the spirit of the assistant "thinking" glows on phones: soft pools of colour
/// drift around the edges of the screen, over the photo, and breathe; a line at the bottom
/// says what the scan is doing and how far it has got. The mix of colours, where
/// they start, how fast and which way they go are rolled fresh each time. When the search
/// ends it fades away and the faces it found take over.
class PhotoScanGlow extends StatefulWidget {
  const PhotoScanGlow({super.key, required this.visible, required this.message});

  final bool visible;

  /// What the scan is doing right now, in a few words ("Found 12 faces · identifying").
  final String message;

  @override
  State<PhotoScanGlow> createState() => _PhotoScanGlowState();
}

class _Orb {
  _Orb(math.Random r, this.color)
      : phase = r.nextDouble(),
        turns = (r.nextBool() ? 1 : -1) * (3 + r.nextInt(3)), // whole turns per minute: 3..5, either way
        breathPhase = r.nextDouble() * 2 * math.pi,
        breathTurns = 5 + r.nextInt(4),
        size = 0.34 + r.nextDouble() * 0.12;

  final Color color;
  final double phase; // where round the edge it starts
  final int turns; // whole turns per loop, so the loop is seamless
  final double breathPhase;
  final int breathTurns;
  final double size; // radius as a fraction of the screen's short side
}

class _PhotoScanGlowState extends State<PhotoScanGlow> with TickerProviderStateMixin {
  static const _palette = [
    Color(0xFF5FE0CF),
    Color(0xFF7AD7FF),
    Color(0xFFB388FF),
    Color(0xFFFF8AD8),
    Color(0xFFFFC46B),
  ];

  // One long loop; every orb turns a whole number of times in it.
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 60));
  // How much of the glow shows (0..1), applied inside the painter: fading a whole
  // screen-sized layer instead is what produced the blocky garbage on some phones.
  late final AnimationController _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  final math.Random _rng = math.Random();
  late List<_Orb> _orbs = _roll();
  bool _pillOn = false;

  List<_Orb> _roll() {
    final colours = List<Color>.from(_palette)..shuffle(_rng);
    return [for (var i = 0; i < 3; i++) _Orb(_rng, colours[i])];
  }

  void _start() {
    _orbs = _roll(); // a new search gets a new look
    _pillOn = true;
    _c.repeat();
    _fade.forward();
  }

  @override
  void initState() {
    super.initState();
    if (widget.visible) _start();
  }

  @override
  void didUpdateWidget(covariant PhotoScanGlow old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) {
      _start();
    } else if (!widget.visible && old.visible) {
      // Keep it going while it fades out; stop only once it can't be seen.
      _fade.reverse().whenComplete(() {
        if (mounted && !widget.visible) _c.stop();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: Listenable.merge([_c, _fade]),
              builder: (context, _) => CustomPaint(
                painter: _EdgeGlowPainter(_c.value, _orbs, Curves.easeInOut.transform(_fade.value)),
                size: Size.infinite,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).padding.bottom + AppSpacing.xxl,
            child: TickerMode(
              enabled: _pillOn,
              child: AnimatedOpacity(
                opacity: widget.visible ? 1 : 0,
                // Quick out, so it has gone before "Tap a face to see who" arrives in the same place.
                duration: Duration(milliseconds: widget.visible ? 500 : 350),
                curve: Curves.easeOut,
                onEnd: () {
                  if (!widget.visible && mounted) setState(() => _pillOn = false);
                },
                child: Center(
                  child: _FlowText(widget.message, leading: const _TwinkleStar()),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EdgeGlowPainter extends CustomPainter {
  _EdgeGlowPainter(this.t, this.orbs, this.fade);

  final double t; // 0..1 around the loop
  final List<_Orb> orbs;
  final double fade; // 0..1, how much is showing

  // A point on the screen's edge, [u] (0..1) of the way round.
  static Offset _onEdge(double u, Size s) {
    final total = 2 * (s.width + s.height);
    var d = (u % 1) * total;
    if (d < s.width) return Offset(d, 0);
    d -= s.width;
    if (d < s.height) return Offset(s.width, d);
    d -= s.height;
    if (d < s.width) return Offset(s.width - d, s.height);
    d -= s.width;
    return Offset(0, s.height - d);
  }

  // Rings per pool: each a plain, faint circle, so together they fall off smoothly with
  // no gradient shader at all (a big gradient rendered as coarse blocks on some phones).
  static const _rings = 26;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || fade <= 0) return;
    final short = math.min(size.width, size.height);
    for (final orb in orbs) {
      final centre = _onEdge(orb.phase + orb.turns * t, size);
      // Breathes slowly between fainter and stronger.
      final breath = 0.5 + 0.5 * math.sin(orb.breathPhase + 2 * math.pi * orb.breathTurns * t);
      final peak = (0.26 + 0.12 * breath) * fade; // strength at the very middle
      final radius = short * orb.size * (0.94 + 0.12 * breath);
      // Per-ring transparency chosen so the stack adds up to [peak] in the middle.
      final each = 1 - math.pow(1 - peak, 1 / _rings).toDouble();
      final paint = Paint()..color = orb.color.withValues(alpha: each);
      for (var i = 0; i < _rings; i++) {
        canvas.drawCircle(centre, radius * (i + 1) / _rings, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EdgeGlowPainter old) => old.t != t || old.orbs != orbs || old.fade != fade;
}
