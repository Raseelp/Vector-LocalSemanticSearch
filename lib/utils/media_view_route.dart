import 'package:flutter/material.dart';

// A single, cheap transition for opening/closing the photo and video
// viewers (search results, a person's photos, a collection, and the
// "Similar to this" strip inside the viewers themselves) - a plain
// PageRouteBuilder rather than a Hero.
//
// A Hero flight was tried first: growing the tapped tile's own rect into
// the full-screen view. On a real (modestly-powered) device it fought with
// everything else already happening on that same frame - the bento grid's
// own tile animations, a video player's native initialization, a staged
// "chrome fades in after the flight" sequence - and the result was
// flickering and a flight that barely played before snapping to its end
// state, worse than not animating at all.
//
// This is deliberately much less for Flutter to compute per frame: no rect
// tweening between two different widget trees, no per-tile tag bookkeeping,
// nothing to keep hidden-then-reveal in step with a flight's completion.
// The whole destination screen (photo/video *and* its buttons together)
// fades in while scaling up very slightly from its final size, which still
// reads as a deliberate "this is arriving," not a plain instant cut, and
// PageRouteBuilder reverses the exact same animation automatically on pop -
// so closing settles back down and fades out with no extra code.
Route<T> mediaViewRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}
