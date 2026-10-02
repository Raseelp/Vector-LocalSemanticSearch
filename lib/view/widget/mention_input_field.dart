import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';
import 'package:twentyonevision/view/widget/mention_text_controller.dart';

// A reusable version of the search box's own "@name" autocomplete (see
// MentionTextEditingController and search_tab.dart's _SearchPill, which
// uses the same MentionDropdown below directly since it anchors its own
// field rather than this one) - typing "@" opens a dropdown of matching
// people anchored right below the field; picking one inserts their name as
// a recognised mention, same as typing a name plainly. Anywhere this app
// lets someone describe "who's in it" alongside free text should use this
// rather than a plain TextField, so the two ways of recognising a person
// stay consistent everywhere - not just in search, but wherever a query
// gets typed (a collection's own "+ New"/"Edit" sheet, for instance).
class MentionInputField extends StatefulWidget {
  const MentionInputField({
    super.key,
    required this.controller,
    this.focusNode,
    this.decoration,
    this.style,
    this.autofocus = false,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
  });

  final MentionTextEditingController controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextStyle? style;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  /// Called on every keystroke, mention pick or recognition change - not
  /// just submission. Useful for a caller that needs to react live (e.g.
  /// enabling a Save button once there's something to save).
  final VoidCallback? onChanged;

  @override
  State<MentionInputField> createState() => _MentionInputFieldState();
}

class _MentionInputFieldState extends State<MentionInputField> {
  final LayerLink _mentionLink = LayerLink();
  OverlayEntry? _mentionEntry;
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode => widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _removeMentionOverlay();
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    widget.onChanged?.call();
    if (widget.controller.activeMentionQuery == null) {
      _removeMentionOverlay();
    } else if (_mentionEntry == null) {
      _mentionEntry = OverlayEntry(
        builder: (_) => MentionDropdown(
          link: _mentionLink,
          controller: widget.controller,
          focusNode: _focusNode,
        ),
      );
      Overlay.of(context).insert(_mentionEntry!);
    }
    // No explicit rebuild of an already-inserted entry needed:
    // _MentionDropdown listens to the same controller itself and refilters
    // on every keystroke on its own.
  }

  void _removeMentionOverlay() {
    final entry = _mentionEntry;
    if (entry == null) return;
    _mentionEntry = null;
    entry.remove();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _mentionLink,
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        textInputAction: widget.textInputAction,
        onSubmitted: widget.onSubmitted,
        style: widget.style,
        decoration: widget.decoration ?? const InputDecoration(),
      ),
    );
  }
}

// The "@" autocomplete dropdown - named people matching whatever's typed
// after the "@", anchored to the field above via [link] so it tracks it
// regardless of scrolling. Picking one confirms that exact person - see
// MentionTextEditingController.selectMention for why that's never
// ambiguous even when a live plain-text match would have to stay silent.
//
// Public (not the field's own private State) because the search box's
// _SearchPill anchors this to itself directly, rather than going through
// MentionInputField - both places should look and behave identically
// instead of each keeping its own copy.
class MentionDropdown extends StatelessWidget {
  const MentionDropdown({
    super.key,
    required this.link,
    required this.controller,
    required this.focusNode,
  });

  final LayerLink link;
  final MentionTextEditingController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return CompositedTransformFollower(
      link: link,
      showWhenUnlinked: false,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(0, AppSpacing.xs),
      // The Overlay hands its top-level entries a full-screen-sized box to
      // fill, same as it would a route's page (see the search box's own
      // note on this - same trap). Without this, the dropdown's Material
      // would stretch to fill the whole screen height instead of sizing to
      // its own short list.
      child: UnconstrainedBox(
        alignment: Alignment.topLeft,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final query = controller.activeMentionQuery;
            if (query == null) return const SizedBox.shrink();

            final people = Get.isRegistered<FacesController>()
                ? Get.find<FacesController>().people
                : const <Person>[];
            final already = controller.recognizedPeople.map((p) => p.id).toSet();
            final matches = people
                .where((p) => (p.name ?? '').isNotEmpty)
                .where((p) => !already.contains(p.id))
                .where((p) => p.name!.toLowerCase().contains(query.toLowerCase()))
                .take(6)
                .toList();
            if (matches.isEmpty) return const SizedBox.shrink();

            return Material(
              elevation: 8,
              shadowColor: AppColors.ink.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              color: AppColors.canvas,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260, maxHeight: 240),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  itemCount: matches.length,
                  itemBuilder: (context, i) {
                    final person = matches[i];
                    return InkWell(
                      onTap: () {
                        controller.selectMention(person);
                        // onTapOutside on the field itself already unfocused it the
                        // moment this tap landed outside its bounds (the dropdown
                        // sits below the field, not over it) - reclaim focus so
                        // typing the rest of the sentence continues right where
                        // the mention was inserted, instead of needing a second tap.
                        focusNode.requestFocus();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.base,
                          vertical: AppSpacing.sm,
                        ),
                        child: Row(
                          children: [
                            FaceAvatar(faceId: person.coverFaceId, size: 32),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                person.name!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
