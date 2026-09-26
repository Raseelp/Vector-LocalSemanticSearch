import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/collections_controller.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/utils/floating_bar.dart';
import 'package:twentyonevision/view/people_filter_screen.dart';
import 'package:twentyonevision/view/settings_screen.dart';
import 'package:twentyonevision/view/widget/collections_tab.dart';
import 'package:twentyonevision/view/widget/faces_tab.dart';
import 'package:twentyonevision/view/widget/library_tab.dart';
import 'package:twentyonevision/view/widget/search_tab.dart';

// NativeController.homeTab values.
const int _tabSearch = 0;
const int _tabCollections = 1;
const int _tabLibrary = 2;
const int _tabFaces = 3;

// Proportions measured off Google Photos' floating bar on a ~411dp-wide
// phone: a 58dp fully-rounded pill, a 42dp selected chip inset 8dp inside
// it, a round search button the same 58dp tall, and the bar sitting ~20dp
// above the system navigation with wide side margins.
const double _barHeight = kFloatingBarHeight;
const double _barInset = 8;
const double _chipHeight = _barHeight - 2 * _barInset;

/// The app's four front-page destinations behind one floating bar: Library,
/// Collections and Faces as tabs in a pill, and Search as its own round
/// button beside it - which still switches the body like a tab does, it just
/// isn't part of the pill. Indexing lives entirely in the Library tab (that's
/// where it's triggered from); a small pulsing dot on that tab signals it's
/// active even while you're looking at something else.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // True while the user is scrolling down a list: the bar shrinks and settles
  // lower (see _FloatingNavBar). Scrolling back up, or reaching the top,
  // restores it.
  bool _shrunk = false;

  void _setShrunk(bool value) {
    if (_shrunk != value) setState(() => _shrunk = value);
  }

  bool _onScroll(ScrollNotification n) {
    // Only the tabs' own vertical lists - not the horizontal chip rows.
    if (n.metrics.axis != Axis.vertical || n.depth != 0) return false;

    if (n is UserScrollNotification) {
      if (n.direction == ScrollDirection.reverse) {
        _setShrunk(true);
      } else if (n.direction == ScrollDirection.forward) {
        _setShrunk(false);
      }
    } else if (n is ScrollUpdateNotification &&
        n.metrics.pixels <= n.metrics.minScrollExtent + 4) {
      _setShrunk(false);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return GetBuilder<NativeController>(
      builder: (controller) {
        final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

        // Back from another tab returns to Search (where the app opens)
        // instead of leaving the app; back on Search leaves as usual.
        return PopScope(
          canPop: controller.homeTab == _tabSearch,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            // Choosing people: back first cancels that, and stays on the tab.
            if (Get.isRegistered<FacesController>()) {
              final faces = Get.find<FacesController>();
              if (faces.selecting) {
                faces.stopSelecting();
                return;
              }
            }
            controller.setHomeTab(_tabSearch);
          },
          child: Scaffold(
            backgroundColor: AppColors.canvas,
            // bottom: false + a Stack: the tabs run the full height and scroll
            // *under* the floating bar (each ends with floatingBarClearance so the
            // last item can still be brought clear of it), instead of being cut
            // off in a strip above it.
            body: SafeArea(
              bottom: false,
              child: Stack(
                children: [
                  Column(
                    children: [
                      const _HomeTopBar(),
                      const SizedBox(height: AppSpacing.sm),
                      Expanded(
                        child: NotificationListener<ScrollNotification>(
                          onNotification: _onScroll,
                          child: IndexedStack(
                            index: controller.homeTab,
                            children: [
                              SearchTab(
                                controller: controller,
                                onSeeAllCollections: () =>
                                    controller.setHomeTab(_tabCollections),
                              ),
                              GetBuilder<CollectionsController>(
                                builder: (collections) => CollectionsTab(
                                  controller: collections,
                                  native: controller,
                                ),
                              ),
                              LibraryTab(controller: controller),
                              const FacesTab(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Out of the way while typing - it would otherwise ride up on
                  // top of the keyboard. Stays mounted so it can animate both
                  // ways; while hidden it can't be tapped or read out.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _KeyboardHide(
                      hidden: keyboardOpen,
                      // Rebuilds with the People tab's "choose people" state: while that is
                      // on, the bar turns into the button that goes on to the photos.
                      child: GetBuilder<FacesController>(
                        builder: (faces) => _FloatingNavBar(
                          selection:
                              faces.selecting && controller.homeTab == _tabFaces
                              ? _BarSelection(
                                  chosen: faces.selectedPeople.length,
                                  onCancel: faces.stopSelecting,
                                  onFind: () {
                                    final people = faces.selectedPeople;
                                    if (people.isEmpty) return;
                                    faces.stopSelecting();
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            PeopleFilterScreen(people: people),
                                      ),
                                    );
                                  },
                                )
                              : null,
                          index: controller.homeTab,
                          shrunk: _shrunk,
                          showActivityDot: controller.isScanning,
                          onChanged: (i) {
                            if (i != controller.homeTab) {
                              HapticFeedback.selectionClick();
                              // A newly shown tab is at rest, so the bar is full size.
                              _shrunk = false;
                            }
                            controller.setHomeTab(i);
                            // Choosing people belongs to the People tab: leaving it ends that.
                            if (i != _tabFaces &&
                                Get.isRegistered<FacesController>()) {
                              final faces = Get.find<FacesController>();
                              if (faces.selecting) faces.stopSelecting();
                            }
                            // Opening Faces: refresh, and make sure the scan is going.
                            if (i == _tabFaces) {
                              final faces = Get.find<FacesController>();
                              faces.refreshAll();
                              faces.startScan();
                            }
                            // Search opens ready to type - once the tab is
                            // actually showing (it's offstage until then).
                            if (i == _tabSearch) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                controller.searchFocusNode.requestFocus();
                              });
                            }
                          },
                        ),
                      ),
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

// Tucks the bar away when the keyboard opens: it sinks and shrinks a little
// while fading, quickly and with an ease-in so it's gone before the keyboard
// is; coming back, it rises and settles with a small spring overshoot so it
// lands softly rather than just appearing.
class _KeyboardHide extends StatelessWidget {
  const _KeyboardHide({required this.hidden, required this.child});

  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = Duration(milliseconds: hidden ? 200 : 460);
    final curve = hidden ? Curves.easeInCubic : Curves.easeOutBack;

    return IgnorePointer(
      ignoring: hidden,
      child: ExcludeSemantics(
        excluding: hidden,
        child: AnimatedSlide(
          duration: duration,
          curve: curve,
          offset: Offset(0, hidden ? 0.7 : 0),
          child: AnimatedScale(
            duration: duration,
            curve: curve,
            scale: hidden ? 0.9 : 1,
            alignment: Alignment.bottomCenter,
            // Opacity can't overshoot 0..1, so it gets its own plain curve.
            child: AnimatedOpacity(
              duration: Duration(milliseconds: hidden ? 160 : 260),
              curve: hidden ? Curves.easeIn : Curves.easeOut,
              opacity: hidden ? 0 : 1,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeTopBar extends StatelessWidget {
  const _HomeTopBar();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Vector', style: Theme.of(context).textTheme.titleLarge),
          IconButton(
            icon: const Icon(
              Icons.settings_outlined,
              color: AppColors.ink,
              size: 22,
            ),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
    );
  }
}

class _NavTab {
  const _NavTab(this.value, this.label, this.icon, this.selectedIcon);

  final int value;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const _navTabs = [
  _NavTab(
    _tabLibrary,
    'Library',
    Icons.photo_library_outlined,
    Icons.photo_library_rounded,
  ),
  _NavTab(
    _tabCollections,
    'Collections',
    Icons.collections_bookmark_outlined,
    Icons.collections_bookmark_rounded,
  ),
  _NavTab(
    _tabFaces,
    'Faces',
    Icons.face_retouching_natural_outlined,
    Icons.face_retouching_natural,
  ),
];

// A pill holding the three tabs - only the selected one shows its icon and
// sits in a teal chip, the others are just a label - with Search as its own
// round button next to it. Search selects the body the same way a tab does,
// so while it's active the pill has nothing selected and the button takes
// over the highlight. Tonal like the rest of the app (parchment on canvas,
// primary for "on"), not a dark slab.
/// While choosing people in the People tab: how many are ticked and what the
/// bar's two actions do.
class _BarSelection {
  const _BarSelection({
    required this.chosen,
    required this.onCancel,
    required this.onFind,
  });

  final int chosen;
  final VoidCallback onCancel;
  final VoidCallback onFind;
}

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({
    required this.index,
    required this.onChanged,
    required this.showActivityDot,
    required this.shrunk,
    this.selection,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final bool showActivityDot;
  final bool shrunk;

  // Non-null while choosing people: the bar becomes the "find photos" button.
  final _BarSelection? selection;

  @override
  Widget build(BuildContext context) {
    // Margins are kept modest so the pill has room for the selected tab's icon
    // and label at full size - the text never has to shrink to fit. Only on a
    // very narrow screen do the tabs tighten their padding.
    final width = MediaQuery.of(context).size.width;
    final margin = width >= 400 ? 20.0 : 16.0;
    final compact = width < 380;
    final selection = this.selection;
    final choosing = selection != null;
    final ready = choosing && selection.chosen > 0;

    // Scrolling down shrinks the whole bar toward its bottom edge and lets it
    // settle lower into the gap beneath it, so it recedes from the content;
    // scrolling back up restores it. Scale and slide are transforms, so
    // nothing relayouts mid-scroll.
    return AnimatedSlide(
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
      offset: Offset(0, shrunk ? 0.08 : 0),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 340),
        curve: Curves.easeOutCubic,
        scale: shrunk ? 0.93 : 1,
        alignment: Alignment.bottomCenter,
        child: Padding(
          // Bottom includes the system inset now that the body runs behind it.
          padding: EdgeInsets.fromLTRB(
            margin,
            AppSpacing.sm,
            margin,
            kFloatingBarBottomGap + MediaQuery.of(context).padding.bottom,
          ),
          child: Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  // Translucent frosted glass: content scrolls visibly behind
                  // it, a touch more see-through while it's out of the way.
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    // The same pill either way: only its colour and contents change, so it
                    // reads as the bar itself turning into the button (and back).
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 340),
                      curve: Curves.easeOutCubic,
                      height: _barHeight,
                      padding: const EdgeInsets.all(_barInset),
                      decoration: BoxDecoration(
                        color: ready
                            ? AppColors.primary
                            : AppColors.parchment.withValues(
                                alpha: shrunk ? 0.55 : 0.72,
                              ),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        border: Border.all(
                          color: ready ? AppColors.primary : AppColors.hairline,
                        ),
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 260),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        layoutBuilder: (current, previous) => Stack(
                          fit: StackFit.expand,
                          children: [...previous, if (current != null) current],
                        ),
                        child: choosing
                            ? _SelectionContent(
                                key: const ValueKey('choose'),
                                selection: selection,
                              )
                            : Row(
                                key: const ValueKey('tabs'),
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  for (final tab in _navTabs)
                                    _NavItem(
                                      tab: tab,
                                      selected: index == tab.value,
                                      showDot:
                                          tab.value == _tabLibrary &&
                                          showActivityDot,
                                      compact: compact,
                                      onTap: () => onChanged(tab.value),
                                    ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              // The round Search button slides away while choosing (the pill grows into
              // the space), and comes back after. Kept mounted, just folded to zero width.
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: choosing ? 0 : 1),
                duration: const Duration(milliseconds: 340),
                curve: Curves.easeOutCubic,
                builder: (context, t, child) => ClipRect(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: t,
                    child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
                  ),
                ),
                child: IgnorePointer(
                  ignoring: choosing,
                  child: Row(
                    children: [
                      const SizedBox(width: AppSpacing.sm),
                      _SearchButton(
                        active: index == _tabSearch,
                        shrunk: shrunk,
                        onTap: () => onChanged(_tabSearch),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// What the pill shows while choosing people: a close button on the left, and the
// action across the middle - "Choose people" until someone is ticked, then the
// button to see their photos.
class _SelectionContent extends StatelessWidget {
  const _SelectionContent({super.key, required this.selection});

  final _BarSelection selection;

  @override
  Widget build(BuildContext context) {
    final ready = selection.chosen > 0;
    final foreground = ready ? AppColors.onPrimary : AppColors.ink;
    final label = selection.chosen == 0
        ? 'Choose people'
        : (selection.chosen == 1
              ? 'See their photos'
              : 'Find photos with these ${selection.chosen}');

    return Row(
      children: [
        Semantics(
          button: true,
          label: 'Cancel',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: selection.onCancel,
            child: Container(
              width: _chipHeight,
              height: _chipHeight,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: foreground.withValues(alpha: ready ? 0.18 : 0.08),
              ),
              child: Icon(Icons.close_rounded, size: 20, color: foreground),
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: ready ? selection.onFind : null,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Row(
                  key: ValueKey(label),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (ready) ...[
                      Icon(
                        Icons.photo_library_outlined,
                        size: 18,
                        color: foreground,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: ready ? foreground : AppColors.ink48,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Same width as the close button, so the label is centred in the pill.
        const SizedBox(width: _chipHeight),
      ],
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.tab,
    required this.selected,
    required this.showDot,
    required this.compact,
    required this.onTap,
  });

  final _NavTab tab;
  final bool compact;
  final bool selected;
  final bool showDot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Sized by its own content, not Flexible: three Flexibles split the pill
    // into equal thirds, which is smaller than the selected tab needs (icon +
    // "Collections") and clipped its label. The pill has room for all three
    // at natural width.
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          height: _chipHeight,
          padding: EdgeInsets.symmetric(
            horizontal: selected ? 12 : (compact ? 10 : 14),
          ),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerLeft,
            // No FittedBox: the label and icon are always the same size, selected
            // or not - the pill has the room, so nothing scales down to fit.
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Icon(tab.selectedIcon, size: 18, color: AppColors.onPrimary),
                  const SizedBox(width: 7),
                ],
                Text(
                  tab.label,
                  maxLines: 1,
                  softWrap: false,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: selected ? AppColors.onPrimary : AppColors.ink80,
                  ),
                ),
                if (showDot) ...[
                  const SizedBox(width: 5),
                  _ActivityDot(
                    color: selected ? AppColors.onPrimary : AppColors.primary,
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

// Search as its own round button. Inactive it's a plain tonal circle; when
// Search is the screen showing, it comes alive - fills teal, the magnifier
// gives a little tilt-and-bounce, and a ring ripples out once from it - so
// it reads as a switched-on control rather than a shortcut.
class _SearchButton extends StatefulWidget {
  const _SearchButton({
    required this.active,
    required this.shrunk,
    required this.onTap,
  });

  final bool active;
  final bool shrunk;
  final VoidCallback onTap;

  @override
  State<_SearchButton> createState() => _SearchButtonState();
}

class _SearchButtonState extends State<_SearchButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    // Already on when the app opens (it launches on Search) - show it
    // settled rather than playing the ripple on every launch.
    if (widget.active) _burst.value = 1;
  }

  @override
  void didUpdateWidget(covariant _SearchButton old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _burst.forward(from: 0);
    } else if (!widget.active && old.active) {
      _burst.value = 0;
    }
  }

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: widget.active,
      label: 'Search',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _burst,
          builder: (context, _) {
            final t = _burst.value;
            // Overshoots and settles: a tilt that swings past and back.
            final tilt = widget.active
                ? math.sin(t * math.pi * 2) * 0.35 * (1 - t)
                : 0.0;
            final pop = widget.active ? 1 + 0.18 * math.sin(t * math.pi) : 1.0;

            return SizedBox(
              width: _barHeight,
              height: _barHeight,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  if (widget.active && t > 0 && t < 1)
                    Container(
                      width: _barHeight + 26 * t,
                      height: _barHeight + 26 * t,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.primary.withValues(
                            alpha: 0.45 * (1 - t),
                          ),
                          width: 2,
                        ),
                      ),
                    ),
                  ClipOval(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 340),
                        curve: Curves.easeOutCubic,
                        width: _barHeight,
                        height: _barHeight,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.active
                              ? AppColors.primary.withValues(
                                  alpha: widget.shrunk ? 0.72 : 0.85,
                                )
                              : AppColors.parchment.withValues(
                                  alpha: widget.shrunk ? 0.55 : 0.72,
                                ),
                          border: Border.all(
                            color: widget.active
                                ? AppColors.primary
                                : AppColors.hairline,
                          ),
                        ),
                        child: Transform.rotate(
                          angle: tilt,
                          child: Transform.scale(
                            scale: pop,
                            child: Icon(
                              Icons.search_rounded,
                              color: widget.active
                                  ? AppColors.onPrimary
                                  : AppColors.ink,
                              size: 26,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// A quiet pulse rather than a static badge - it needs to read as "something
// ongoing", not "something needs your attention".
class _ActivityDot extends StatefulWidget {
  const _ActivityDot({required this.color});

  final Color color;

  @override
  State<_ActivityDot> createState() => _ActivityDotState();
}

class _ActivityDotState extends State<_ActivityDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.35,
        end: 1,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
