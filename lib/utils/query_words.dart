/// Common words filtered out before asking "why did this word match" -
/// scoring "the" or "a" against an image is meaningless noise, not a real
/// signal. Deliberately short and generic (not exhaustive) - this only
/// needs to remove the obvious non-content words, not perform real NLP.
const Set<String> _stopwords = {
  'a', 'an', 'the', 'of', 'in', 'on', 'at', 'to', 'for', 'with', 'and', 'or',
  'is', 'are', 'was', 'were', 'be', 'been', 'my', 'me', 'i', 'this', 'that',
  'these', 'those', 'some', 'near', 'by', 'from', 'it', 'its', 'as', 'into',
  'photo', 'photos', 'picture', 'pictures', 'image', 'images', 'video', 'videos',
};

/// The query words worth explaining a match by - lowercased, deduplicated,
/// stripped of punctuation, with stopwords and very short fragments
/// dropped. Used both to decide whether there's anything worth asking
/// native to score, and as the actual candidate list sent over.
List<String> extractContentWords(String query) {
  final seen = <String>{};
  final words = <String>[];

  for (final raw in query.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
    if (raw.length <= 2) continue;
    if (_stopwords.contains(raw)) continue;
    if (seen.add(raw)) words.add(raw);
  }

  return words;
}
