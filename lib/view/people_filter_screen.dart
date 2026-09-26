import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';
import 'package:twentyonevision/view/widget/search_results.dart';

/// Photos by several people at once. Pick who (and add more with the "+"), then
/// how: any of them, all of them (other people welcome), or only them. The
/// choices show how many photos each would give, and a plain sentence says
/// what the current one means.
class PeopleFilterScreen extends StatefulWidget {
  const PeopleFilterScreen({super.key, required this.people});

  final List<Person> people;

  @override
  State<PeopleFilterScreen> createState() => _PeopleFilterScreenState();
}

class _PeopleFilterScreenState extends State<PeopleFilterScreen> {
  late final FacesController _faces = Get.find<FacesController>();

  @override
  void initState() {
    super.initState();
    // After the first frame: opening notifies listeners, which can't happen mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _faces.openPeopleFilter(widget.people);
    });
  }

  @override
  void dispose() {
    _faces.closePeopleFilter();
    super.dispose();
  }

  // The choices for how to combine the people: a radio list, each with a plain
  // explanation and how many photos it would give.
  void _pickScope(
    FacesController faces,
    List<Person> people,
    List<({String mode, String label, IconData icon})> options,
  ) {
    showFacesSheet<void>(
      context,
      title: 'Show photos',
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.dividerSoft),
            SheetRow(
              icon: options[i].icon,
              label: options[i].label,
              subtitle: _sentence(options[i].mode, people),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (faces.filterCounts.containsKey(options[i].mode))
                    Text(
                      '${faces.filterCounts[options[i].mode]}',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: faces.filterMode == options[i].mode
                            ? AppColors.primary
                            : AppColors.ink48,
                      ),
                    ),
                  if (faces.filterMode == options[i].mode) ...[
                    const SizedBox(width: AppSpacing.sm),
                    const Icon(
                      Icons.check_rounded,
                      size: 20,
                      color: AppColors.primary,
                    ),
                  ],
                ],
              ),
              onTap: () {
                Navigator.of(sheet).pop();
                faces.setFilterMode(options[i].mode);
              },
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
        ],
      ),
    );
  }

  // Everyone who could still be added.
  List<Person> addable(FacesController faces, List<Person> chosen) {
    final taken = chosen.map((p) => p.id).toSet();
    return faces.people.where((p) => !taken.contains(p.id)).toList();
  }

  // The "+": a grid of everyone not chosen yet; tapping one adds them.
  void _pickPerson(FacesController faces, List<Person> chosen) {
    final rest = addable(faces, chosen);
    showFacesSheet<void>(
      context,
      title: 'Add a person',
      builder: (sheet) => GridView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.all(AppSpacing.base),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: AppSpacing.md,
          crossAxisSpacing: AppSpacing.xs,
          childAspectRatio: 0.82,
        ),
        itemCount: rest.length,
        itemBuilder: (context, i) {
          final person = rest[i];
          return InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: () {
              Navigator.of(sheet).pop();
              faces.addToFilter(person);
            },
            child: Column(
              children: [
                LayoutBuilder(
                  builder: (context, box) => FaceAvatar(
                    faceId: person.coverFaceId,
                    size: (box.maxWidth - 8).clamp(40.0, 72.0),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  person.name ?? 'Unnamed',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.ink80),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // "Anna", "Anna and Ben", "Anna, Ben and Cara".
  static String _names(List<Person> people) {
    final names = people.map((p) => p.name ?? 'Unnamed').toList();
    if (names.length == 1) return names.first;
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  // The ways of combining, with the words that fit how many people are chosen.
  static List<({String mode, String label, IconData icon})> _options(
    int count,
  ) {
    if (count == 1) {
      // One person: every photo they are in, or only the ones where they are alone.
      return const [
        (
          mode: PeopleMode.any,
          label: 'With anyone',
          icon: Icons.groups_rounded,
        ),
        (
          mode: PeopleMode.only,
          label: 'On their own',
          icon: Icons.person_rounded,
        ),
      ];
    }
    // Any of them: a crowd to pick from. Plus others: the group, in a bigger crowd.
    // Only this group: focused in on just them.
    return const [
      (
        mode: PeopleMode.any,
        label: 'Any of them',
        icon: Icons.people_outline_rounded,
      ),
      (
        mode: PeopleMode.together,
        label: 'Plus others',
        icon: Icons.groups_rounded,
      ),
      (
        mode: PeopleMode.only,
        label: 'Only this group',
        icon: Icons.filter_center_focus_rounded,
      ),
    ];
  }

  // What the chosen combination means, in a sentence.
  static String _sentence(String mode, List<Person> people) {
    final names = _names(people);
    final one = people.length == 1;
    switch (mode) {
      case PeopleMode.any:
        return one
            ? 'Every photo $names appears in, whoever else is there'
            : 'Photos with at least one of $names';
      case PeopleMode.together:
        return 'Photos with $names together - other people can be there too';
      case PeopleMode.only:
        return one
            ? 'Photos where $names is on their own - nobody else in the picture'
            : 'Photos with only $names - nobody else in the picture';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return GetBuilder<FacesController>(
      builder: (faces) {
        final textTheme = Theme.of(context).textTheme;
        final native = Get.find<NativeController>();
        // Until the screen has loaded, what it was opened with; after, what is chosen
        // (which can be nobody).
        final people = faces.filterOpened ? faces.filterPeople : widget.people;
        final options = _options(people.length);
        final count = faces.filterPhotos.length;

        return Scaffold(
          backgroundColor: AppColors.canvas,
          body: SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm,
                      AppSpacing.xs,
                      AppSpacing.xl,
                      0,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            size: 18,
                            color: AppColors.ink,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        Text('Photos with', style: textTheme.titleMedium),
                      ],
                    ),
                  ),
                ),
                // Who: the chosen people (a cross takes one off, down to a single person).
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xl,
                        vertical: AppSpacing.sm,
                      ),
                      // The people, then a "+" (only while someone is left to add).
                      itemCount:
                          people.length +
                          (addable(faces, people).isEmpty ? 0 : 1),
                      separatorBuilder: (_, __) =>
                          const SizedBox(width: AppSpacing.base),
                      itemBuilder: (context, i) => i < people.length
                          ? _ChosenPerson(
                              person: people[i],
                              onRemove: () => faces.removeFromFilter(people[i]),
                            )
                          : _AddPerson(onTap: () => _pickPerson(faces, people)),
                    ),
                  ),
                ),
                // How: one control showing the current choice and how many photos it
                // gives; tapping it opens the choices, each explained.
                if (people.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.xl,
                        AppSpacing.sm,
                        AppSpacing.xl,
                        0,
                      ),
                      child: _ScopeBar(
                        icon: options
                            .firstWhere(
                              (o) => o.mode == faces.filterMode,
                              orElse: () => options.first,
                            )
                            .icon,
                        label: options
                            .firstWhere(
                              (o) => o.mode == faces.filterMode,
                              orElse: () => options.first,
                            )
                            .label,
                        count: faces.isFilterLoading
                            ? null
                            : faces.filterPhotos.length,
                        onTap: () => _pickScope(faces, people, options),
                      ),
                    ),
                  ),
                // Breathing room before the photos.
                const SliverToBoxAdapter(
                  child: SizedBox(height: AppSpacing.md),
                ),
                if (people.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.xxl,
                        AppSpacing.xl,
                        AppSpacing.xxl,
                        0,
                      ),
                      child: Text(
                        'No one chosen. Tap + to pick a person, or go back.',
                        textAlign: TextAlign.center,
                        style: textTheme.bodySmall?.copyWith(
                          color: AppColors.ink48,
                          height: 1.45,
                        ),
                      ),
                    ),
                  )
                else if (faces.isFilterLoading)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(top: AppSpacing.xxl),
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else if (count == 0)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.xxl,
                        AppSpacing.xxl,
                        AppSpacing.xxl,
                        0,
                      ),
                      child: Text(
                        'No photos match this combination. Try another choice above.',
                        textAlign: TextAlign.center,
                        style: textTheme.bodySmall?.copyWith(
                          color: AppColors.ink48,
                          height: 1.45,
                        ),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl,
                    ),
                    sliver: collectionResultsGrid(
                      controller: native,
                      results: faces.filterPhotos,
                      bytesFor: (item) =>
                          faces.filterThumbs[item['path'] as String],
                      matchQuery: '',
                      loading: faces.isFilterThumbs,
                    ),
                  ),
                const SliverToBoxAdapter(
                  child: SizedBox(height: AppSpacing.xl),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// One person in the "who" row.
class _ChosenPerson extends StatelessWidget {
  const _ChosenPerson({required this.person, required this.onRemove});

  final Person person;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return SizedBox(
      width: 64,
      child: Column(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                FaceAvatar(faceId: person.coverFaceId, size: 56),
                if (onRemove != null)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: GestureDetector(
                      onTap: onRemove,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: AppColors.ink,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.canvas,
                            width: 1.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 12,
                          color: AppColors.canvas,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            person.name ?? 'Unnamed',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: AppColors.ink80),
          ),
        ],
      ),
    );
  }
}

// The "+" at the end of the row: same size as a face, so it reads as one more
// place in the row - tap it to add someone.
class _AddPerson extends StatelessWidget {
  const _AddPerson({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.parchment,
                border: Border.all(color: AppColors.hairline, width: 1.5),
              ),
              child: const Icon(
                Icons.add_rounded,
                size: 26,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Add',
              style: textTheme.bodySmall?.copyWith(color: AppColors.primary),
            ),
          ],
        ),
      ),
    );
  }
}

// One row: the current choice as a tappable pill on the left (the chevron says it
// opens a list), and how many photos it gives on the right as plain text. Both edges
// line up with the faces above and the photo grid below (same side margins), and
// nothing competes for attention - it is a control and a caption, not a card.
class _ScopeBar extends StatelessWidget {
  const _ScopeBar({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Row(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: Container(
              height: 40,
              padding: const EdgeInsets.only(
                left: AppSpacing.md,
                right: AppSpacing.sm,
              ),
              // A wash of the accent colour, so it reads as the thing to touch (a plain
              // outlined pill blended into the page).
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: AppColors.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    label,
                    style: textTheme.titleSmall?.copyWith(
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: AppColors.primary,
                  ),
                ],
              ),
            ),
          ),
        ),
        const Spacer(),
        if (count == null)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Text(
            count == 1 ? '1 photo' : '$count photos',
            style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
          ),
      ],
    );
  }
}
