import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/face_review_screen.dart';
import 'package:twentyonevision/view/split_person_screen.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';

/// Everything you can do with one person, in one menu - opened by holding a face in
/// the People tab. (Their own page shows these as [PersonHeadActions] instead - the
/// same five actions, floating round their head rather than hidden behind a tap.)
void showPersonMenu(
  BuildContext context,
  FacesController faces,
  Person person,
) {
  showFacesSheet<void>(
    context,
    title: person.name ?? 'This person',
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SheetRow(
          icon: Icons.edit_outlined,
          label: person.name == null ? 'Add a name' : 'Rename',
          onTap: () async {
            Navigator.of(sheet).pop();
            final name = await showRenamePersonDialog(context, person.name);
            if (name != null) faces.rename(person, name);
          },
        ),
        const Divider(height: 1, color: AppColors.dividerSoft),
        SheetRow(
          icon: Icons.groups_rounded,
          label: 'Find photos with someone else',
          subtitle: 'Together, or just the two of them',
          onTap: () {
            Navigator.of(sheet).pop();
            // To the People tab, in "choose people" mode with this one ticked
            // (from a person's own page that means going back to it first).
            Navigator.of(context).popUntil((route) => route.isFirst);
            Get.find<NativeController>().setHomeTab(3);
            faces.startSelecting(person);
          },
        ),
        const Divider(height: 1, color: AppColors.dividerSoft),
        SheetRow(
          icon: Icons.merge_type_rounded,
          label: 'Same person as someone else',
          subtitle: 'Merge with another person',
          onTap: () {
            Navigator.of(sheet).pop();
            showMergePicker(context, faces, person);
          },
        ),
        const Divider(height: 1, color: AppColors.dividerSoft),
        SheetRow(
          icon: Icons.call_split_rounded,
          label: 'Split into two people',
          subtitle: 'If two different people were mixed up',
          onTap: () {
            Navigator.of(sheet).pop();
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SplitPersonScreen(person: person)),
            );
          },
        ),
        const Divider(height: 1, color: AppColors.dividerSoft),
        SheetRow(
          icon: Icons.grid_view_rounded,
          label: 'Review faces',
          subtitle: 'Take out faces that are someone else',
          onTap: () {
            Navigator.of(sheet).pop();
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => FaceReviewScreen(person: person),
              ),
            );
          },
        ),
        const Divider(height: 1, color: AppColors.dividerSoft),
        SheetRow(
          icon: Icons.visibility_off_outlined,
          label: 'Hide this person',
          onTap: () {
            Navigator.of(sheet).pop();
            faces.setHidden(person, true);
          },
        ),
      ],
    ),
  );
}

/// Everyone else, the likeliest matches first; tapping one asks to confirm the merge.
void showMergePicker(
  BuildContext context,
  FacesController faces,
  Person person,
) {
  final others = faces.people.where((p) => p.id != person.id).toList()
    ..sort((x, y) {
      final sx = faces.suggestionScoreFor(person, x) ?? -1;
      final sy = faces.suggestionScoreFor(person, y) ?? -1;
      if (sx != sy) return sy.compareTo(sx);
      return y.photoCount.compareTo(x.photoCount);
    });

  showFacesSheet<void>(
    context,
    title: 'Merge ${person.name ?? 'this person'} with...',
    builder: (sheet) => others.isEmpty
        ? const Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: Text('There is nobody else to merge with yet.'),
          )
        : ListView.separated(
            shrinkWrap: true,
            itemCount: others.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: AppColors.dividerSoft),
            itemBuilder: (_, i) {
              final other = others[i];
              final suggested = faces.suggestionScoreFor(person, other) != null;
              return InkWell(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                onTap: () {
                  Navigator.of(sheet).pop();
                  confirmMerge(context, faces, keep: person, other: other);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.base,
                    vertical: AppSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      FaceAvatar(faceId: other.coverFaceId, size: 44),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Text(
                          other.name ??
                              'Unnamed  ·  ${other.photoCount} photos',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
      if (suggested)
                        Text(
                          'Looks similar',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppColors.primary),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
  );
}

/// The five everyday actions (everything but rename, which sits under the name with its
/// own pencil icon) as small round buttons floating around the person's photo instead of
/// behind a "⋯" tap - the dots were too easy to miss. Same actions, same calls, as
/// [showPersonMenu]. They pop in with a light, staggered bounce the moment the page opens,
/// so there's nothing to discover - they're just there.
class PersonHeadActions extends StatefulWidget {
  const PersonHeadActions({super.key, required this.faces, required this.person, this.size = 104});

  final FacesController faces;
  final Person person;
  final double size;

  @override
  State<PersonHeadActions> createState() => _PersonHeadActionsState();
}

class _Orbit {
  const _Orbit({
    required this.icon,
    required this.label,
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label; // the short caption under the button
  final String title; // the confirm dialog's heading
  final String message; // what it does, and when you'd want it
  final String confirmLabel; // the confirm dialog's action button
  final VoidCallback onTap;
  final bool danger;
}

class _PersonHeadActionsState extends State<PersonHeadActions> with TickerProviderStateMixin {
  // Not forward()'d here - see initState. Slower than it was (620ms), too: at that speed and
  // starting the instant this widget existed, it was mostly done before the page's own push
  // transition had even settled, so it came and went before anyone was looking at it.
  late final AnimationController _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));

  @override
  void initState() {
    super.initState();
    // Waits out the page's own transition first, so the pop-in plays on a screen that's already
    // sitting still in front of the user rather than racing their arrival.
    Future.delayed(const Duration(milliseconds: 380), () {
      if (mounted) _in.forward();
    });
  }

  // The button that was tapped, waiting to be confirmed. Null: showing the orbit as normal.
  // The whole sequence is three animations played one after another:
  //   1. _burst (0->1): the other four buttons are pulled in toward the tapped one and fade
  //      out, while it turns into a solid glowing badge and pulses - gathering everything
  //      into one point.
  //   2. _travel (0->1): that badge then flies from its spot in the orbit to the middle,
  //      growing as it goes, until it's sitting where the photo was.
  //   3. the explanation opens as a speech bubble underneath it, floating in its own overlay
  //      (see _bubbleEntry) rather than as another widget in this column - so it can appear
  //      and disappear without ever resizing this page's scroll content, which would jostle
  //      the photo grid below every time.
  // Cancelling or confirming folds the bubble away, then reverses 2 and 1 to bring
  // everything back (skipped on confirm, since the page is about to leave anyway).
  _Orbit? _pending;
  int _pendingIndex = 0;
  late final AnimationController _burst = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  late final AnimationController _travel = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));

  // Anchors the floating bubble to wherever the badge ends up, so it tracks it with no
  // layout coupling at all between the two.
  final LayerLink _badgeLink = LayerLink();
  OverlayEntry? _bubbleEntry;
  late final AnimationController _bubbleFade = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));

  // Gap between the badge's edge and the bubble's tail - half the badge's biggest size,
  // plus a little breathing room.
  static const _bubbleGap = _bigBadge / 2 + 8;

  void _ask(int index, _Orbit action) {
    HapticFeedback.selectionClick();
    setState(() {
      _pending = action;
      _pendingIndex = index;
    });
    _burst.forward(from: 0).whenComplete(() {
      if (!mounted || _pending != action) return;
      HapticFeedback.selectionClick();
      _travel.forward(from: 0).whenComplete(() {
        if (mounted && _pending == action) _showBubbleOverlay();
      });
    });
  }

  void _showBubbleOverlay() {
    final action = _pending;
    if (action == null) return;
    _removeBubbleOverlay();
    _bubbleEntry = OverlayEntry(
      builder: (overlayContext) {
        final bubbleWidth = math.min(MediaQuery.sizeOf(overlayContext).width - AppSpacing.xxxl, 320.0);
        return CompositedTransformFollower(
          link: _badgeLink,
          showWhenUnlinked: false,
          // Between the badge and the photos below it, tail pointing up at the badge.
          targetAnchor: Alignment.center,
          followerAnchor: Alignment.topCenter,
          offset: const Offset(0, _bubbleGap),
          // The Overlay always hands its top-level entries a full-screen-sized box to fill,
          // same as it would a route's page. Without this, the bubble's Stack (and its
          // Positioned.fill background) would inherit that full height instead of shrinking
          // to its own content - UnconstrainedBox is what lets it ignore that and size (and
          // paint) itself only as large as it actually needs to be.
          child: UnconstrainedBox(
            alignment: Alignment.topCenter,
            child: Material(
              type: MaterialType.transparency,
              child: AnimatedBuilder(
                animation: _bubbleFade,
                builder: (context, child) => Opacity(
                  opacity: _bubbleFade.value,
                  child: Transform.translate(offset: Offset(0, (1 - _bubbleFade.value) * -8), child: child),
                ),
                child: _Bubble(width: bubbleWidth, action: action, onCancel: _close, onConfirm: _confirm),
              ),
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(_bubbleEntry!);
    _bubbleFade.forward(from: 0);
  }

  void _removeBubbleOverlay() {
    final entry = _bubbleEntry;
    if (entry == null) return;
    _bubbleEntry = null;
    entry.remove();
  }

  void _close() {
    // The bubble fading away, the badge setting off on its way back, and the orbit
    // reassembling all start together - one fold-away motion, not one thing waiting on
    // another.
    _bubbleFade.reverse().whenComplete(_removeBubbleOverlay);
    _travel.reverse().whenComplete(() {
      if (!mounted || _pending == null) return;
      _burst.reverse().whenComplete(() {
        if (mounted) setState(() => _pending = null);
      });
    });
  }

  // The bubble stays visible (fading out) for a beat after this runs - see the 140ms delay
  // below - so a fast double-tap on Confirm could otherwise land twice and run the action
  // twice (pushing Split/Review's screen twice, for instance). _confirming guards against
  // that without touching the timing anything else here relies on.
  bool _confirming = false;

  void _confirm() {
    if (_confirming) return;
    _confirming = true;
    final action = _pending!;
    _bubbleFade.reverse().whenComplete(_removeBubbleOverlay);
    // Snappy on purpose: the page is about to leave (or another sheet is about to open) -
    // watching everything fly back first would just be a delay.
    Future.delayed(const Duration(milliseconds: 140), () {
      if (!mounted) return;
      setState(() => _pending = null);
      action.onTap();
    });
  }

  @override
  void dispose() {
    _removeBubbleOverlay();
    _in.dispose();
    _burst.dispose();
    _travel.dispose();
    _bubbleFade.dispose();
    super.dispose();
  }

  List<_Orbit> _actions(BuildContext context) {
    final name = widget.person.name ?? 'this person';
    return [
      _Orbit(
        icon: Icons.groups_rounded,
        label: 'Together',
        title: 'Find photos with someone else?',
        message: 'Pick another person to see photos with $name - together with them, or just the '
            'two of them alone.',
        confirmLabel: 'Choose someone',
        onTap: () {
          // To the People tab, in "choose people" mode with this one ticked.
          Navigator.of(context).popUntil((route) => route.isFirst);
          Get.find<NativeController>().setHomeTab(3);
          widget.faces.startSelecting(widget.person);
        },
      ),
      _Orbit(
        icon: Icons.merge_type_rounded,
        label: 'Merge',
        title: 'Same person as someone else?',
        message: 'Use this if $name shows up as two separate people by mistake. Merging joins '
            'them into one, keeping every photo of both.',
        confirmLabel: 'Choose who',
        onTap: () => showMergePicker(context, widget.faces, widget.person),
      ),
      _Orbit(
        icon: Icons.call_split_rounded,
        label: 'Split',
        title: 'Split into two people?',
        message: "You'd only need this if two different people were merged into $name by "
            'mistake. Vector will show the two groups it can tell apart, for you to separate.',
        confirmLabel: 'Continue',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => SplitPersonScreen(person: widget.person)),
        ),
      ),
      _Orbit(
        icon: Icons.grid_view_rounded,
        label: 'Review',
        title: 'Review faces?',
        message: 'Go through every face used to recognise $name, and take out any that are '
            'actually someone else.',
        confirmLabel: 'Review',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => FaceReviewScreen(person: widget.person)),
        ),
      ),
      _Orbit(
        icon: Icons.visibility_off_outlined,
        label: 'Hide',
        title: 'Hide $name?',
        message: 'Moved out of the Faces tab into Hidden people. Nothing is deleted, and you can '
            'bring them back anytime from Face options.',
        confirmLabel: 'Hide',
        danger: true,
        onTap: () => widget.faces.setHidden(widget.person, true),
      ),
    ];
  }

  // Degrees, 0 = straight up, clockwise. Spread over the top 240° so nothing sits behind
  // the name that shows right under the photo.
  static const _angles = [-120.0, -60.0, 0.0, 60.0, 120.0];

  // Each button lives in a box this big, centred on its orbit point - a fixed size (not
  // whatever its icon+label happen to measure) so its tap target is exactly where it's
  // drawn, with no ambiguity for Stack/Positioned to get wrong.
  static const _slot = 72.0;

  // How big the badge gets once it's finished travelling to the photo's spot.
  static const _bigBadge = 88.0;

  Widget _headStack(BuildContext context, List<_Orbit> actions) {
    final avatarRadius = widget.size / 2;
    const iconSize = 40.0;
    final orbitRadius = avatarRadius + iconSize / 2 + 10;
    // Generous enough that no button, or the badge at its biggest, ever clips.
    final boxSize = math.max(orbitRadius * 2 + iconSize + 36, _bigBadge + 40);
    final center = boxSize / 2;

    final pendingIndex = _pending == null ? null : _pendingIndex;
    Offset offsetOf(int i) {
      final angle = _angles[i] * math.pi / 180;
      return Offset(orbitRadius * math.sin(angle), -orbitRadius * math.cos(angle));
    }

    final tappedOffset = pendingIndex == null ? Offset.zero : offsetOf(pendingIndex);

    final stack = Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: center - avatarRadius,
              top: center - avatarRadius,
              width: widget.size,
              height: widget.size,
              // Fades out as the badge arrives and takes its place.
              child: AnimatedBuilder(
                animation: _travel,
                builder: (context, child) => Opacity(opacity: 1 - _travel.value, child: child),
                child: FaceAvatar(faceId: widget.person.coverFaceId, size: widget.size),
              ),
            ),
            for (var i = 0; i < actions.length; i++)
              if (pendingIndex != i)
                Builder(
                  builder: (context) {
                    final ownOffset = offsetOf(i);
                    // Each button starts a little after the one before it, then eases out
                    // with a small overshoot - it pops into place rather than just appearing.
                    final start = i / actions.length * 0.35;
                    return Positioned(
                      left: center + ownOffset.dx - _slot / 2,
                      top: center + ownOffset.dy - _slot / 2,
                      width: _slot,
                      height: _slot,
                      child: AnimatedBuilder(
                        animation: Listenable.merge([_in, _burst]),
                        builder: (context, child) {
                          final entrance = Curves.easeOutBack.transform(
                            Interval(start, start + 0.55, curve: Curves.linear).transform(_in.value),
                          );
                          final burstT = pendingIndex == null ? 0.0 : Curves.easeInOutCubic.transform(_burst.value);
                          // Pulled in toward wherever the tapped button is, and faded out -
                          // as though being gathered up into it.
                          final delta = (tappedOffset - ownOffset) * burstT;
                          final opacity = (1.0 - burstT) * entrance.clamp(0.0, 1.0);
                          final scale = (1.0 - 0.55 * burstT) * entrance.clamp(0.0, 1.4);
                          return Transform.translate(
                            offset: delta,
                            child: Opacity(
                              opacity: opacity.clamp(0.0, 1.0),
                              child: Transform.scale(scale: scale.clamp(0.0, 1.4), child: child),
                            ),
                          );
                        },
                        child: Center(
                          child: _OrbitButton(
                            action: actions[i],
                            onTap: _pending == null ? () => _ask(i, actions[i]) : null,
                          ),
                        ),
                      ),
                    );
                  },
                ),
            // The tapped button: a solid glowing badge from the moment it's tapped, that
            // then travels from its orbit spot to the middle and grows, ending up sitting
            // where the photo was.
            if (pendingIndex != null)
              Builder(
                builder: (context) {
                  final accent = actions[pendingIndex].danger ? AppColors.danger : AppColors.primary;
                  return AnimatedBuilder(
                    animation: Listenable.merge([_burst, _travel]),
                    builder: (context, _) {
                      final burstT = Curves.easeInOutCubic.transform(_burst.value);
                      final travelT = Curves.easeInOutCubic.transform(_travel.value);
                      final pos = Offset.lerp(tappedOffset, Offset.zero, travelT)!;
                      final pulse = 1.0 + 0.18 * math.sin(burstT * math.pi) * (1 - travelT);
                      final diameter = (iconSize + (_bigBadge - iconSize) * travelT) * pulse;
                      return Positioned(
                        left: center + pos.dx - diameter / 2,
                        top: center + pos.dy - diameter / 2,
                        width: diameter,
                        height: diameter,
                        child: _TravelBadge(icon: actions[pendingIndex].icon, color: accent),
                      );
                    },
                  );
                },
              ),
            // The glow the badge gathers as everyone converges into it, fading away once
            // it sets off on its journey.
            if (pendingIndex != null)
              Positioned(
                left: center + tappedOffset.dx - 45,
                top: center + tappedOffset.dy - 45,
                width: 90,
                height: 90,
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_burst, _travel]),
                    builder: (context, _) => Opacity(
                      opacity: (1 - _travel.value).clamp(0.0, 1.0),
                      child: CustomPaint(
                        painter: _BurstPainter(
                          _burst.value,
                          actions[pendingIndex].danger ? AppColors.danger : AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );

    // A fixed size, always - this box's footprint in the page's scroll content never
    // changes, no matter what's happening inside it (badge growing, bubble opening and
    // closing). The bubble floats in its own overlay instead of living in this layout, so
    // none of that ever pushes the photo grid below around.
    return RepaintBoundary(
      child: CompositedTransformTarget(
        link: _badgeLink,
        child: SizedBox(width: boxSize, height: boxSize, child: stack),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _headStack(context, _actions(context));
}

class _OrbitButton extends StatelessWidget {
  const _OrbitButton({required this.action, required this.onTap});

  final _Orbit action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = action.danger ? AppColors.danger : AppColors.ink80;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.pearl,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.hairline),
                boxShadow: [
                  BoxShadow(color: AppColors.ink.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 3)),
                ],
              ),
              child: Icon(action.icon, size: 18, color: color),
            ),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          action.label,
          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: action.danger ? AppColors.danger : AppColors.ink48),
        ),
      ],
    );
  }
}

/// The pulse the tapped button gathers while the others converge into it: a soft glow at
/// its centre, and a couple of rings spreading outward and fading - the same "something is
/// happening here" language the rest of the app uses (the People button's pulse, the glow
/// around a recognised face), so this reads as one visual system rather than a one-off.
class _BurstPainter extends CustomPainter {
  _BurstPainter(this.t, this.color);

  final double t; // 0..1
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0) return;
    final center = size.center(Offset.zero);
    final glow = Curves.easeOut.transform(t);
    canvas.drawCircle(
      center,
      26,
      Paint()
        ..shader = RadialGradient(colors: [color.withValues(alpha: 0.38 * glow), color.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: center, radius: 26)),
    );
    for (var k = 0; k < 2; k++) {
      final p = ((t - k * 0.24) / 0.6).clamp(0.0, 1.0);
      if (p <= 0 || p >= 1) continue;
      final radius = 8 + 28 * Curves.easeOutCubic.transform(p);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: (1 - p) * 0.6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BurstPainter old) => old.t != t || old.color != color;
}

/// What the tapped orbit button becomes: a solid, glowing circle carrying just its icon -
/// no label, since by the time it's grown large it's sitting where the photo was and
/// speaks for itself.
class _TravelBadge extends StatelessWidget {
  const _TravelBadge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 18, spreadRadius: -2),
          BoxShadow(color: AppColors.ink.withValues(alpha: 0.12), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: FittedBox(
        fit: BoxFit.none,
        child: Icon(icon, color: AppColors.onPrimary, size: 22),
      ),
    );
  }
}

/// The explanation, as a speech bubble opening underneath the badge once it's arrived -
/// the badge is "speaking" it, rather than a boxy alert appearing out of nowhere. Cancel
/// sends the badge back on its way to the orbit; confirming runs the action once it's gone.
///
/// No Center wrapper here - this widget is sized by a CompositedTransformFollower, which
/// gives it the full overlay's loose-but-finite constraints; Center/Align would expand to
/// fill those rather than shrink to content the way they would inside a Column. A plain
/// SizedBox(width: ...) with no height set lets the Stack below size itself to its content.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.width, required this.action, required this.onCancel, required this.onConfirm});

  final double width;
  final _Orbit action;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  static const _tailHeight = 10.0;
  static const _tailWidth = 20.0;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final accent = action.danger ? AppColors.danger : AppColors.primary;

    return SizedBox(
      width: width,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _BubbleShapePainter(radius: AppRadius.xl, tailHeight: _tailHeight, tailWidth: _tailWidth),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, _tailHeight + AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(action.title, textAlign: TextAlign.center, style: textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  action.message,
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall?.copyWith(color: AppColors.ink80, height: 1.4),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: [
                    Expanded(child: _BubbleButton(label: 'Cancel', color: AppColors.ink48, onTap: onCancel)),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: _BubbleButton(label: action.confirmLabel, color: accent, filled: true, onTap: onConfirm),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The bubble's background: a rounded rectangle with a small triangular notch at the top,
/// centre, pointing up at the badge it belongs to - one shape, one shadow, so the notch
/// never looks stuck on.
class _BubbleShapePainter extends CustomPainter {
  _BubbleShapePainter({required this.radius, required this.tailHeight, required this.tailWidth});

  final double radius;
  final double tailHeight;
  final double tailWidth;

  Path _shape(Size size) {
    final path = Path()
      ..addRRect(RRect.fromLTRBR(0, tailHeight, size.width, size.height, Radius.circular(radius)));
    final cx = size.width / 2;
    path
      ..moveTo(cx - tailWidth / 2, tailHeight)
      ..lineTo(cx, 0)
      ..lineTo(cx + tailWidth / 2, tailHeight)
      ..close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _shape(size);
    canvas.drawShadow(path, AppColors.ink.withValues(alpha: 0.18), 8, false);
    canvas.drawPath(path, Paint()..color = AppColors.parchment);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = AppColors.hairline,
    );
  }

  @override
  bool shouldRepaint(covariant _BubbleShapePainter old) => false;
}

class _BubbleButton extends StatelessWidget {
  const _BubbleButton({required this.label, required this.color, required this.onTap, this.filled = false});

  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled ? color : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          decoration: filled
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(color: AppColors.hairline),
                ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: filled ? AppColors.onPrimary : color),
          ),
        ),
      ),
    );
  }
}
