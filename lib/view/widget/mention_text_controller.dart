import 'package:flutter/material.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';

typedef _Mention = ({TextRange range, Person person});

/// The search box's own controller: on top of ordinary typing, it recognises named people in
/// the text - each one either typed plain ("Person at the beach", matched live against the
/// People list) or picked explicitly out of an "@" dropdown ("Person and Person2 at the beach") -
/// and highlights whichever it found.
///
/// A name typed in plain text is only ever recognised if it belongs to exactly one person -
/// two people sharing a name is exactly what "@" is for, since picking one from the dropdown
/// is never ambiguous. Once people are recognised, [recognizedPeople] and
/// [queryWithoutMention] are what runSearch() actually acts on: they become a photo filter
/// (everyone mentioned has to be in it), and their names are dropped from the words sent to
/// CLIP - a name means nothing to an image-similarity model, only the description around it
/// does.
class MentionTextEditingController extends TextEditingController {
  MentionTextEditingController({required this.peopleProvider});

  /// A function, not a fixed list - people can be named after this controller is created, and
  /// each keystroke should see the current list, not a stale snapshot from construction.
  final List<Person> Function() peopleProvider;

  // Explicit "@" picks, revalidated on every change against their own stored range - see
  // _recompute for what happens to one once an edit elsewhere moves it enough to invalidate it
  // (it's dropped, and the plain-text scan picks the name back up from its new spot anyway,
  // unless that name happens to be ambiguous - a known, narrow gap, not worth the bookkeeping
  // a full position-diffing scheme would take to close).
  final List<_Mention> _explicit = [];

  List<_Mention> _mentions = const [];

  /// Every person recognised in the current text, left to right.
  List<Person> get recognizedPeople => _mentions.map((m) => m.person).toList();

  // A gap left behind where a mention used to be - "Raseel and Priya" leaves
  // " and " between them once both names are gone, "Raseel, Priya" leaves
  // ", " - counts as empty when it's *only* a bare connector once trimmed,
  // so joining several names never leaves that connector word as the only
  // thing CLIP ends up searching for (queryWithoutMention was briefly just
  // "and" for a plain "@Raseel and @Priya" search before this existed).
  static const _bareConnectors = {'and', '&', 'with', ','};

  /// What to actually send to CLIP: the typed text with every recognised name (and the "@"
  /// that introduced it, if any) removed, whitespace collapsed back down.
  String get queryWithoutMention {
    if (_mentions.isEmpty) return text.trim();
    final ascending = [..._mentions]
      ..sort((a, b) => a.range.start.compareTo(b.range.start));

    // Each gap - before the first mention, between two, after the last -
    // kept as its own piece rather than concatenated directly, so a bare
    // connector can be checked (and dropped) in isolation without touching
    // real content elsewhere in the text.
    final gaps = <String>[];
    var cursor = 0;
    for (final m in ascending) {
      if (m.range.end > text.length || m.range.start < cursor) continue;
      var start = m.range.start;
      if (start > cursor && text[start - 1] == '@') start -= 1;
      gaps.add(text.substring(cursor, start));
      cursor = m.range.end;
    }
    gaps.add(text.substring(cursor));

    final cleaned = gaps.map((gap) {
      return _bareConnectors.contains(gap.trim().toLowerCase()) ? '' : gap;
    });
    return cleaned.join(' ').trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  /// The partial name typed after an unfinished "@" right before the cursor, or null if the
  /// cursor isn't sitting in one right now - what the dropdown filters its list by.
  String? get activeMentionQuery {
    final pos = selection.baseOffset;
    if (pos < 0 || pos > text.length) return null;
    final upToCursor = text.substring(0, pos);
    final at = upToCursor.lastIndexOf('@');
    if (at == -1) return null;
    final between = upToCursor.substring(at + 1);
    // A space or a second "@" means whatever was being typed after the first one is done/
    // abandoned - no live dropdown for it any more.
    if (between.contains(' ') || between.contains('@')) return null;
    return between;
  }

  /// Confirms [person] for the "@partial" just before the cursor - explicit, so (unlike a live
  /// plain-text match) it's never ambiguous even if other people share this name. The "@"
  /// itself is dropped once picked - a confirmed mention should look exactly like a plain typed
  /// name that got recognised live, not carry a leftover "@" as a badge of how it got there.
  void selectMention(Person person) {
    final pos = selection.baseOffset;
    if (pos < 0 || pos > text.length) return;
    final upToCursor = text.substring(0, pos);
    final at = upToCursor.lastIndexOf('@');
    if (at == -1) return;
    final name = person.name ?? 'Unnamed';
    final newText = '${text.substring(0, at)}$name ${text.substring(pos)}';
    final newCursor = at + name.length + 1;
    _explicit.add((
      range: TextRange(start: at, end: at + name.length),
      person: person,
    ));
    value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
  }

  @override
  set value(TextEditingValue newValue) {
    // Computed before the assignment, not after: super.value's setter notifies listeners as
    // part of setting it, and anything reacting to that notification (the field's own
    // highlighted repaint, the dropdown) needs _mentions already caught up to this text, not
    // the previous one.
    _recompute(newValue.text);
    super.value = newValue;
  }

  void _recompute(String newText) {
    // Keep only the explicit picks whose exact text is still sitting right where it was left.
    _explicit.removeWhere(
      (m) =>
          m.range.end > newText.length ||
          newText.substring(m.range.start, m.range.end) != m.person.name,
    );

    final named =
        peopleProvider().where((p) => (p.name ?? '').trim().isNotEmpty).toList()
          // Longest name first, so a full name wins over a shorter name that happens to be a
          // prefix of it, rather than whichever happens to come first in the list.
          ..sort((a, b) => b.name!.length.compareTo(a.name!.length));

    final found = <_Mention>[..._explicit];
    final claimed = _explicit.map((m) => m.person.id).toSet();

    for (final person in named) {
      if (claimed.contains(person.id))
        continue; // already mentioned, via an explicit pick
      final name = person.name!;
      final matches = _wholeWordMatches(newText, name);
      if (matches.isEmpty) continue;
      final sharedByOthers = named.any(
        (p) => p.id != person.id && p.name == name,
      );
      if (sharedByOthers)
        continue; // ambiguous - "@" is how you resolve this, not a guess
      final span = matches.first;
      // An explicit pick can sit right next to (or overlap, mid-edit) a plain match - it wins.
      final overlapsExplicit = _explicit.any(
        (e) => span.start < e.range.end && span.end > e.range.start,
      );
      if (overlapsExplicit) continue;
      found.add((range: span, person: person));
      claimed.add(person.id);
    }

    found.sort((a, b) => a.range.start.compareTo(b.range.start));
    _mentions = found;
  }

  static bool _isWordChar(String ch) {
    final code = ch.codeUnitAt(0);
    return (code >= 48 && code <= 57) || // 0-9
        (code >= 65 && code <= 90) || // A-Z
        (code >= 97 && code <= 122) || // a-z
        code == 95; // _
  }

  static List<TextRange> _wholeWordMatches(String haystack, String needle) {
    if (needle.isEmpty) return const [];
    final lowerHay = haystack.toLowerCase();
    final lowerNeedle = needle.toLowerCase();
    final matches = <TextRange>[];
    var start = 0;
    while (true) {
      final i = lowerHay.indexOf(lowerNeedle, start);
      if (i == -1) break;
      final end = i + needle.length;
      final before = i == 0 || !_isWordChar(haystack[i - 1]);
      final after = end == haystack.length || !_isWordChar(haystack[end]);
      if (before && after) matches.add(TextRange(start: i, end: end));
      start = i + 1;
    }
    return matches;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (_mentions.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final highlight = (style ?? const TextStyle()).copyWith(
      color: AppColors.primary,
      fontWeight: FontWeight.w700,
    );
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final m in _mentions) {
      if (m.range.start < cursor || m.range.end > text.length) continue;
      spans.add(TextSpan(text: text.substring(cursor, m.range.start)));
      spans.add(
        TextSpan(
          text: text.substring(m.range.start, m.range.end),
          style: highlight,
        ),
      );
      cursor = m.range.end;
    }
    spans.add(TextSpan(text: text.substring(cursor)));
    return TextSpan(style: style, children: spans);
  }
}
