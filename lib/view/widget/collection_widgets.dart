import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/collections_controller.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/models/collection_model.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/confirm_dialog.dart';
import 'package:twentyonevision/view/widget/mention_input_field.dart';
import 'package:twentyonevision/view/widget/mention_text_controller.dart';

String _countLabel(int count) => count == 1 ? '1 item' : '$count items';

// One collection in the Collections tab's grid: a cover photo as its
// identity (as in Google Photos; it rotates through the collection's best
// matches - see CollectionsController.selectedCover), otherwise its icon on
// a plain card.
//
// While a collection is being (re)computed - just saved, or just edited -
// the card plays a "finding matches" animation: a light sweeps across it and
// a sparkle pulses. When it finishes the card pops slightly and the count
// ticks up from zero, so a new collection visibly arrives instead of
// appearing already finished.
class CollectionCard extends StatefulWidget {
  const CollectionCard({
    super.key,
    required this.collection,
    required this.stats,
    required this.coverBytes,
    required this.syncing,
    required this.onTap,
    required this.onLongPress,
  });

  final SmartCollection collection;
  final CollectionStats stats;
  final Uint8List? coverBytes;
  final bool syncing;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<CollectionCard> createState() => _CollectionCardState();
}

class _CollectionCardState extends State<CollectionCard> with TickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    if (widget.syncing) _sweep.repeat();
  }

  @override
  void didUpdateWidget(covariant CollectionCard old) {
    super.didUpdateWidget(old);
    if (widget.syncing && !old.syncing) {
      _sweep.repeat();
    } else if (!widget.syncing && old.syncing) {
      _sweep.stop();
      _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasCover = widget.coverBytes != null;
    final textTheme = Theme.of(context).textTheme;

    final scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.06), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1.06, end: 1.0), weight: 70),
    ]).animate(CurvedAnimation(parent: _pop, curve: Curves.easeOut));

    return ScaleTransition(
      scale: scale,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Crossfades when the cover changes (a new day, a new best
                // match) rather than snapping.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 700),
                  // The default layout gives its children loose constraints,
                  // so a cover would sit at its own size in the middle of the
                  // card with a border around it. Expand instead, so `cover`
                  // fills the whole card - cropped, never stretched or
                  // letterboxed.
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, if (current != null) current],
                  ),
                  child: hasCover
                      ? Image.memory(
                          widget.coverBytes!,
                          key: ValueKey(widget.coverBytes),
                          fit: BoxFit.cover,
                          cacheWidth: 420,
                          gaplessPlayback: true,
                        )
                      : ColoredBox(
                          key: const ValueKey('no-cover'),
                          color: AppColors.parchment,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                              child: Icon(widget.collection.icon, size: 34, color: AppColors.ink48),
                            ),
                          ),
                        ),
                ),
                if (hasCover)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black.withValues(alpha: 0.62)],
                        stops: const [0.45, 1],
                      ),
                    ),
                  ),
                if (widget.syncing) _SyncOverlay(animation: _sweep, onPhoto: hasCover),
                Positioned(
                  left: AppSpacing.md,
                  right: AppSpacing.md,
                  bottom: AppSpacing.md,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.collection.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall?.copyWith(
                          color: hasCover ? Colors.white : AppColors.ink,
                        ),
                      ),
                      widget.syncing
                          ? Text(
                              'Finding matches...',
                              style: textTheme.bodySmall?.copyWith(
                                color: hasCover ? Colors.white70 : AppColors.ink48,
                              ),
                            )
                          : TweenAnimationBuilder<int>(
                              tween: IntTween(begin: 0, end: widget.stats.count),
                              duration: const Duration(milliseconds: 900),
                              curve: Curves.easeOutCubic,
                              builder: (context, value, _) => Text(
                                _countLabel(value),
                                style: textTheme.bodySmall?.copyWith(
                                  color: hasCover ? Colors.white70 : AppColors.ink48,
                                ),
                              ),
                            ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// A soft band of light sweeping diagonally across the card, with a sparkle
// breathing in the middle.
class _SyncOverlay extends StatelessWidget {
  const _SyncOverlay({required this.animation, required this.onPhoto});

  final Animation<double> animation;
  final bool onPhoto;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        final breathe = 0.5 + 0.5 * math.sin(t * 2 * math.pi);

        return Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(-2.4 + 4.8 * t, -1),
                  end: Alignment(-1.2 + 4.8 * t, 1),
                  colors: [
                    Colors.white.withValues(alpha: 0),
                    Colors.white.withValues(alpha: onPhoto ? 0.35 : 0.85),
                    Colors.white.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                child: Transform.rotate(
                  angle: 0.35 * math.sin(t * 2 * math.pi),
                  child: Transform.scale(
                    scale: 0.85 + 0.3 * breathe,
                    child: Icon(
                      Icons.auto_awesome_rounded,
                      size: 30,
                      color: onPhoto ? Colors.white : AppColors.primary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// The Search tab's quick-access row - a pill with the collection's cover
// photo as a small round avatar (its icon until one exists), its name, and
// how many things are in it.
class CollectionChip extends StatelessWidget {
  const CollectionChip({
    super.key,
    required this.collection,
    required this.count,
    required this.coverBytes,
    required this.onTap,
  });

  final SmartCollection collection;
  final int count;
  final Uint8List? coverBytes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xs + 2,
            AppSpacing.xs + 2,
            AppSpacing.md,
            AppSpacing.xs + 2,
          ),
          decoration: BoxDecoration(
            color: AppColors.parchment,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ChipAvatar(bytes: coverBytes, icon: collection.icon),
              const SizedBox(width: AppSpacing.sm),
              Text(
                collection.name,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '$count',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.ink48),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "New collection" tile at the start of the Collections grid.
class NewCollectionCard extends StatelessWidget {
  const NewCollectionCard({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.hairline, width: 1.5),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.add_rounded,
                  color: AppColors.onPrimary,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'New collection',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Name (+ the phrase to search, when it isn't already known) for a new or
/// edited collection. [onSave] gets the finished values - [query] already
/// has any "@name" mentions stripped out (same as search's own
/// queryWithoutMention), with those names broken out separately into
/// [onSave]'s third argument.
Future<void> showSaveCollectionSheet(
  BuildContext context, {
  String? title,
  String initialName = '',
  String? initialQuery,
  bool showQuery = false,
  required Future<void> Function(String name, String query, List<int> personIds) onSave,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SaveCollectionSheet(
      title: title ?? 'Save as collection',
      initialName: initialName,
      initialQuery: initialQuery,
      showQuery: showQuery,
      onSave: onSave,
    ),
  );
}

class _SaveCollectionSheet extends StatefulWidget {
  const _SaveCollectionSheet({
    required this.title,
    required this.initialName,
    required this.initialQuery,
    required this.showQuery,
    required this.onSave,
  });

  final String title;
  final String initialName;
  final String? initialQuery;
  final bool showQuery;
  final Future<void> Function(String name, String query, List<int> personIds) onSave;

  @override
  State<_SaveCollectionSheet> createState() => _SaveCollectionSheetState();
}

class _SaveCollectionSheetState extends State<_SaveCollectionSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  // Same "@name" recognition the search box uses - lets a collection made
  // from the Collections page (not just one saved from an existing search)
  // filter by person too. peopleProvider mirrors NativeController's own
  // construction of its searchTextController.
  late final MentionTextEditingController _query = MentionTextEditingController(
    peopleProvider: () =>
        Get.isRegistered<FacesController>() ? Get.find<FacesController>().people : const [],
  )..text = widget.initialQuery ?? '';

  @override
  void dispose() {
    _name.dispose();
    _query.dispose();
    super.dispose();
  }

  bool get _canSave =>
      widget.showQuery ? _query.text.trim().isNotEmpty : _name.text.trim().isNotEmpty;

  // Closes right away and does the work behind it - the new card appears in
  // the list and plays its own "finding matches" animation, so there's
  // nothing to wait on here.
  void _save() {
    final query = widget.showQuery ? _query.queryWithoutMention : (widget.initialQuery ?? '');
    final personIds = widget.showQuery
        ? _query.recognizedPeople.map((p) => p.id).toList()
        : const <int>[];
    final name = _name.text.trim();
    final onSave = widget.onSave;
    Navigator.of(context).pop();
    unawaited(onSave(name, query, personIds));
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.canvas,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl,
          AppSpacing.base,
          AppSpacing.xl,
          AppSpacing.xl,
        ),
        child: SafeArea(
          top: false,
          // A tall keyboard (or a long "@name and @name2..." query) can
          // otherwise push this sheet's own content taller than the space
          // actually left above it - scrollable rather than clipped/
          // overflowing keeps the Save button reachable either way.
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.hairline,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.base),
              Text(widget.title, style: textTheme.titleMedium),
              if (!widget.showQuery &&
                  (widget.initialQuery ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  'Finds: ${widget.initialQuery}',
                  style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
                ),
              ],
              const SizedBox(height: AppSpacing.base),
              if (widget.showQuery) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
                  decoration: BoxDecoration(
                    color: AppColors.parchment,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                  ),
                  child: MentionInputField(
                    controller: _query,
                    autofocus: widget.initialQuery == null,
                    onChanged: () => setState(() {}),
                    style: textTheme.bodyMedium,
                    decoration: InputDecoration(
                      hintText: 'What to look for, e.g. "dog" or "@name at the beach"',
                      hintStyle: const TextStyle(color: AppColors.ink48),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              _Field(
                controller: _name,
                hint: widget.showQuery
                    ? 'Name (optional), e.g. "Mittu"'
                    : 'Name, e.g. "Mittu"',
                autofocus: !widget.showQuery,
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                width: double.infinity,
                child: Material(
                  color: _canSave ? AppColors.primary : AppColors.hairline,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: InkWell(
                    onTap: _canSave ? _save : null,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.md,
                      ),
                      child: Center(
                        child: Text(
                          'Save',
                          style: textTheme.titleSmall?.copyWith(
                            color: _canSave
                                ? AppColors.onPrimary
                                : AppColors.ink48,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final VoidCallback onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
      decoration: BoxDecoration(
        color: AppColors.parchment,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        onChanged: (_) => onChanged(),
        textCapitalization: TextCapitalization.sentences,
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: AppColors.ink48),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        ),
      ),
    );
  }
}

/// Long-press menu for a collection card. Every collection can be edited,
/// hidden or deleted; a built-in that's been edited can also be reset.
void showCollectionMenu(
  BuildContext context,
  SmartCollection collection,
  CollectionsController controller,
) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.canvas,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.base),
                child: Text(collection.name, style: Theme.of(context).textTheme.titleSmall),
              ),
              const Divider(height: 1, color: AppColors.hairline),
              _MenuRow(
                icon: Icons.edit_outlined,
                label: 'Rename or change',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showEditCollectionSheet(context, collection, controller);
                },
              ),
              const Divider(height: 1, color: AppColors.dividerSoft),
              _MenuRow(
                icon: Icons.visibility_off_outlined,
                label: 'Hide',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  controller.hideCollection(collection.id);
                },
              ),
              if (collection.isBuiltIn && controller.isEdited(collection.id)) ...[
                const Divider(height: 1, color: AppColors.dividerSoft),
                _MenuRow(
                  icon: Icons.restart_alt_rounded,
                  label: 'Reset to default',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    controller.resetBuiltIn(collection.id);
                  },
                ),
              ],
              const Divider(height: 1, color: AppColors.dividerSoft),
              _MenuRow(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                destructive: true,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showConfirmDialog(
                    context,
                    title: 'Delete this collection?',
                    message: collection.isBuiltIn
                        ? 'It comes off your list. You can bring it back any time from Settings, under "Restore default collections".'
                        : 'Only the collection goes - your photos and videos are untouched.',
                    confirmLabel: 'Delete',
                    onConfirm: () => controller.deleteCollection(collection.id),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> showEditCollectionSheet(
  BuildContext context,
  SmartCollection collection,
  CollectionsController controller,
) {
  // A photo collection has no phrase to edit - just its name.
  if (collection.isPhotos) {
    return showSaveCollectionSheet(
      context,
      title: 'Rename collection',
      initialName: collection.name,
      initialQuery: 'photos that look like the one you saved',
      onSave: (name, _, __) => controller.updateCollection(
        collection.copyWith(name: name.isEmpty ? collection.name : name),
      ),
    );
  }

  // Shows the short phrase (a built-in's several prompts are an
  // implementation detail); leaving it alone keeps the built-in's own. Any
  // already-mentioned people are put back in front of it, the same way
  // search's own lastQueryWithMentions does - so the field's own name
  // recognition picks them up again as soon as it opens, rather than
  // silently starting from a collection that looks like it has no person
  // filter at all.
  final currentQuery = collection.queryText;
  final currentPersonNames = collection.personIds.isEmpty || !Get.isRegistered<FacesController>()
      ? const <String>[]
      : Get.find<FacesController>().people
          .where((p) => collection.personIds.contains(p.id))
          .map((p) => p.name)
          .whereType<String>()
          .toList();
  final initialQueryWithMentions = currentPersonNames.isEmpty
      ? currentQuery
      : '${currentPersonNames.join(' and ')} $currentQuery';

  return showSaveCollectionSheet(
    context,
    title: 'Edit collection',
    initialName: collection.name,
    initialQuery: initialQueryWithMentions,
    showQuery: true,
    onSave: (name, query, personIds) => controller.updateCollection(
      collection.copyWith(
        name: name.isEmpty ? query : name,
        prompts: query == currentQuery ? null : [query],
        personIds: personIds,
      ),
    ),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.danger : AppColors.ink;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.base,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: AppSpacing.md),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChipAvatar extends StatelessWidget {
  const _ChipAvatar({required this.bytes, required this.icon});

  final Uint8List? bytes;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: SizedBox(
        width: 24,
        height: 24,
        child: bytes == null
            ? ColoredBox(
                color: AppColors.hairline,
                child: Icon(icon, size: 14, color: AppColors.ink48),
              )
            : Image.memory(
                bytes!,
                fit: BoxFit.cover,
                cacheWidth: 72,
                cacheHeight: 72,
              ),
      ),
    );
  }
}
