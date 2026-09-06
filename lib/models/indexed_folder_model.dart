/// Stable identity for an indexed location: a folder's own SAF tree URI, or
/// this sentinel for whole-device scans.
class IndexedFolderIdentity {
  static const device = '__device_scan__';
}

/// One file that just finished embedding - carried on live scan progress
/// only, never persisted (see IndexedFolder.toMap).
class RecentEmbeddedItem {
  final String uri;
  final bool isVideo;
  final int timestampMs;

  const RecentEmbeddedItem({
    required this.uri,
    required this.isVideo,
    required this.timestampMs,
  });

  factory RecentEmbeddedItem.fromMap(Map<dynamic, dynamic> map) {
    return RecentEmbeddedItem(
      uri: map['uri'] ?? '',
      isVideo: map['isVideo'] as bool? ?? false,
      timestampMs: (map['timestampMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class IndexedFolder {
  final String id;
  final int total;
  final int embedded;
  final int skipped;
  final num elapsedMs;
  final String path;
  final int processed;
  final bool done;

  /// Epoch millis of the last scan, used to sort the folders list.
  final int updatedAt;

  /// Rolling window of recently-embedded files from live scan progress -
  /// empty once loaded from the DB (see toMap, which doesn't persist it).
  final List<RecentEmbeddedItem> recentItems;

  const IndexedFolder({
    required this.id,
    required this.total,
    required this.embedded,
    required this.skipped,
    required this.elapsedMs,
    required this.path,
    required this.processed,
    required this.done,
    this.updatedAt = 0,
    this.recentItems = const [],
  });

  factory IndexedFolder.fromMap(Map<dynamic, dynamic> map) {
    return IndexedFolder(
      id: map['id'] ?? '',
      total: map['total'] as int? ?? 0,
      embedded: map['embedded'] as int? ?? 0,
      skipped: map['skipped'] as int? ?? 0,
      elapsedMs: map['elapsedMs'] as num? ?? 0,
      path: map['path'] ?? '',
      processed: map['processed'] ?? 0,
      done: map['done'] ?? false,
      updatedAt: (map['updatedAt'] as num?)?.toInt() ?? 0,
      recentItems: (map['recentItems'] as List<dynamic>?)
              ?.map(
                (e) => RecentEmbeddedItem.fromMap(Map<dynamic, dynamic>.from(e as Map)),
              )
              .toList() ??
          const [],
    );
  }

  factory IndexedFolder.empty() {
    return const IndexedFolder(
      id: '',
      total: 0,
      embedded: 0,
      skipped: 0,
      elapsedMs: 0,
      path: '',
      processed: 0,
      done: false,
      updatedAt: 0,
      recentItems: [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'total': total,
      'embedded': embedded,
      'skipped': skipped,
      'elapsedMs': elapsedMs,
      'path': path,
      'processed': processed,
      'updatedAt': updatedAt,
    };
  }

  IndexedFolder copyWith({
    String? id,
    int? total,
    int? embedded,
    int? skipped,
    num? elapsedMs,
    String? path,
    int? processed,
    bool? done,
    int? updatedAt,
    List<RecentEmbeddedItem>? recentItems,
  }) {
    return IndexedFolder(
      id: id ?? this.id,
      total: total ?? this.total,
      embedded: embedded ?? this.embedded,
      skipped: skipped ?? this.skipped,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      path: path ?? this.path,
      processed: processed ?? this.processed,
      done: done ?? this.done,
      updatedAt: updatedAt ?? this.updatedAt,
      recentItems: recentItems ?? this.recentItems,
    );
  }
}
