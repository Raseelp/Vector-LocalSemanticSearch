import 'dart:convert';

import 'package:flutter/material.dart';

// A named, live, on-device smart search - see collections_plan.md. The
// display name and the query are independent: search "dog", call it
// "Mittu". Only the definition is stored; membership is re-evaluated from
// the embedding index every time, so new scans show up automatically.
class SmartCollection {
  const SmartCollection({
    required this.id,
    required this.name,
    required this.prompts,
    this.icon = Icons.bookmark_border_rounded,
    this.explainQuery,
    this.contentMode = 'both',
    this.sensitivity = defaultSensitivity,
    this.isBuiltIn = false,
    this.createdAt = 0,
    this.kind = kindText,
    this.seedEmbedding,
    this.seedUri,
    this.seedTimestampMs,
    this.personIds = const [],
  });

  static const String kindText = 'text';
  static const String kindPhotos = 'photos';

  /// Standard deviations above a query's library-wide mean score an item
  /// must reach to count as a member - see EmbeddingEngine's "Collections"
  /// section. Per-collection tunable.
  static const double defaultSensitivity = 3.0;

  final String id;
  final String name;
  /// Shown on a card that has no cover photo yet - built-ins each have one,
  /// a collection you made uses the generic bookmark. Identity otherwise
  /// comes from the cover photo itself, like Google Photos.
  final IconData icon;

  /// One or more phrasings of the same idea, embedded separately and
  /// averaged - noticeably more accurate than a single phrase. A
  /// user-created collection has exactly one (what they typed).
  final List<String> prompts;

  /// Short phrase used to explain a match ("why this matched") when a
  /// result is opened from this collection. Defaults to the first prompt.
  final String? explainQuery;

  /// 'both' | 'images' | 'videos'
  final String contentMode;
  final double sensitivity;
  final bool isBuiltIn;
  final int createdAt;

  /// 'text' (a phrase) or 'photos' (found by looking like a photo you saved
  /// a search from). A photo collection stores that photo's embedding
  /// itself - it keeps working if the original file is later deleted.
  final String kind;
  final List<double>? seedEmbedding;
  final String? seedUri;
  final int? seedTimestampMs;

  /// Recognised-person ids mentioned when this collection was made (e.g.
  /// "@Raseel at the beach") - narrows membership to photos/videos with all
  /// of them in it, same "together" rule the search box's own @-mention
  /// uses. Empty for a collection with no person filter at all.
  final List<int> personIds;

  bool get isPhotos => kind == kindPhotos;

  String get queryText => explainQuery ?? prompts.first;

  /// Changes whenever anything that affects the cached query embedding
  /// changes, so a stale one is never reused.
  String get embeddingSignature => prompts.join('|');

  SmartCollection copyWith({
    String? name,
    List<String>? prompts,
    String? contentMode,
    double? sensitivity,
    // Only needed when [prompts] is given but the short phrase should stay
    // (restoring a built-in's own override).
    String? explainQuery,
    List<int>? personIds,
  }) {
    return SmartCollection(
      id: id,
      name: name ?? this.name,
      icon: icon,
      prompts: prompts ?? this.prompts,
      explainQuery: explainQuery ?? (prompts != null ? null : this.explainQuery),
      contentMode: contentMode ?? this.contentMode,
      sensitivity: sensitivity ?? this.sensitivity,
      isBuiltIn: isBuiltIn,
      createdAt: createdAt,
      kind: kind,
      seedEmbedding: seedEmbedding,
      seedUri: seedUri,
      seedTimestampMs: seedTimestampMs,
      personIds: personIds ?? this.personIds,
    );
  }

  Map<String, Object?> toRow({int hiddenState = 0}) => {
    'id': id,
    'name': name,
    'emoji': '',
    'prompts': jsonEncode(prompts),
    'contentMode': contentMode,
    'sensitivity': sensitivity,
    'isBuiltIn': isBuiltIn ? 1 : 0,
    'hidden': hiddenState,
    'createdAt': createdAt,
    'kind': kind,
    'seed': isPhotos
        ? jsonEncode({'embedding': seedEmbedding, 'uri': seedUri, 'timestampMs': seedTimestampMs})
        : null,
    'personIds': personIds.isEmpty ? null : jsonEncode(personIds),
  };

  factory SmartCollection.fromRow(Map<String, Object?> row) {
    final kind = row['kind'] as String? ?? kindText;
    final seedRaw = row['seed'] as String?;
    final seed = kind == kindPhotos && seedRaw != null
        ? jsonDecode(seedRaw) as Map<String, dynamic>
        : null;
    return SmartCollection(
      kind: kind,
      icon: kind == kindPhotos ? Icons.photo_library_outlined : Icons.bookmark_border_rounded,
      seedEmbedding: (seed?['embedding'] as List?)?.map((e) => (e as num).toDouble()).toList(),
      seedUri: seed?['uri'] as String?,
      seedTimestampMs: (seed?['timestampMs'] as num?)?.toInt(),
      id: row['id'] as String,
      name: row['name'] as String? ?? '',
      prompts: (jsonDecode(row['prompts'] as String? ?? '[]') as List).cast<String>(),
      contentMode: row['contentMode'] as String? ?? 'both',
      sensitivity: (row['sensitivity'] as num?)?.toDouble() ?? defaultSensitivity,
      isBuiltIn: (row['isBuiltIn'] as int? ?? 0) == 1,
      createdAt: row['createdAt'] as int? ?? 0,
      personIds: (row['personIds'] as String?) == null
          ? const []
          : (jsonDecode(row['personIds'] as String) as List).cast<num>().map((e) => e.toInt()).toList(),
    );
  }
}

/// What the last scoring pass found for one collection - count plus a few
/// cover items for its card.
class CollectionStats {
  const CollectionStats({required this.count, required this.covers});

  final int count;
  final List<CollectionCover> covers;

  static const empty = CollectionStats(count: 0, covers: []);
}

class CollectionCover {
  const CollectionCover({required this.uri, required this.isVideo, required this.timestampMs});

  final String uri;
  final bool isVideo;
  final int timestampMs;

  String get cacheKey => isVideo ? '$uri@$timestampMs' : uri;

  factory CollectionCover.fromMap(Map<dynamic, dynamic> map) {
    return CollectionCover(
      uri: map['path'] as String? ?? '',
      isVideo: map['isVideo'] as bool? ?? false,
      timestampMs: (map['timestampMs'] as num?)?.toInt() ?? 0,
    );
  }
}
