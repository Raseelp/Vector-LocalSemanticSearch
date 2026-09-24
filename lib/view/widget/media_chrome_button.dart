import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// For the photo and video viewers, whose background is black: light
/// status/navigation icons (the app-wide style has dark ones for the light
/// theme), with the navigation bar painted black to match the viewers' background.
const SystemUiOverlayStyle kMediaOverlayStyle = SystemUiOverlayStyle(
  systemNavigationBarColor: Colors.black,
  systemNavigationBarDividerColor: Colors.black,
  systemNavigationBarContrastEnforced: false,
  systemNavigationBarIconBrightness: Brightness.light,
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
);

// Floating chrome over a photo or video - a frosted-glass circle (blurs
// whatever's directly behind it, then a faint white tint) rather than a
// flat translucent-black fill, so it reads as native photo/video-viewer
// chrome instead of a plain dark chip. Standard regardless of the app's
// light theme underneath (the media, not the app chrome, is what's on
// screen), so this stays outside the app's light-surface token language on
// purpose. Shared by the image and video viewers.
class MediaChromeButton extends StatelessWidget {
  const MediaChromeButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  // Long-press label (and what a screen reader says) - these are bare icons
  // next to each other, so which is which isn't obvious at a glance.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
          ),
          child: IconButton(
            icon: Icon(icon, color: Colors.white, size: 22),
            tooltip: tooltip,
            onPressed: onTap,
          ),
        ),
      ),
    );
  }
}
