/// Everything the Library tab's stat tiles show - one round trip
/// (NativeServices.getLibraryStats) instead of separate calls per number.
class LibraryStats {
  final int totalEmbeddings;
  final int images;
  final int videos;
  final int sizeBytes;

  const LibraryStats({
    required this.totalEmbeddings,
    required this.images,
    required this.videos,
    required this.sizeBytes,
  });

  factory LibraryStats.fromMap(Map<dynamic, dynamic> map) {
    return LibraryStats(
      totalEmbeddings: (map['totalEmbeddings'] as num?)?.toInt() ?? 0,
      images: (map['images'] as num?)?.toInt() ?? 0,
      videos: (map['videos'] as num?)?.toInt() ?? 0,
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
    );
  }

  factory LibraryStats.empty() {
    return const LibraryStats(totalEmbeddings: 0, images: 0, videos: 0, sizeBytes: 0);
  }
}
