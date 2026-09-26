class ModelStatus {
  final String id;
  final String fileName;
  final int sizeBytes;
  final bool downloaded;
  final bool verified;

  // 'search' (the CLIP models) or 'faces' (the face recognition model).
  final String group;

  const ModelStatus({
    required this.id,
    required this.fileName,
    required this.sizeBytes,
    required this.downloaded,
    required this.verified,
    this.group = 'search',
  });

  factory ModelStatus.fromMap(Map<dynamic, dynamic> map) {
    return ModelStatus(
      id: map['id'] ?? '',
      fileName: map['fileName'] ?? '',
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      downloaded: map['downloaded'] as bool? ?? false,
      verified: map['verified'] as bool? ?? false,
      group: map['group'] as String? ?? 'search',
    );
  }
}

class ModelDownloadProgress {
  final String modelId;
  final String modelFileName;
  final int bytesForModel;
  final int totalBytesForModel;
  final int overallBytesDownloaded;
  final int overallTotalBytes;
  final bool done;

  const ModelDownloadProgress({
    required this.modelId,
    required this.modelFileName,
    required this.bytesForModel,
    required this.totalBytesForModel,
    required this.overallBytesDownloaded,
    required this.overallTotalBytes,
    required this.done,
  });

  factory ModelDownloadProgress.fromMap(Map<dynamic, dynamic> map) {
    return ModelDownloadProgress(
      modelId: map['modelId'] ?? '',
      modelFileName: map['modelFileName'] ?? '',
      bytesForModel: (map['bytesForModel'] as num?)?.toInt() ?? 0,
      totalBytesForModel: (map['totalBytesForModel'] as num?)?.toInt() ?? 0,
      overallBytesDownloaded:
          (map['overallBytesDownloaded'] as num?)?.toInt() ?? 0,
      overallTotalBytes: (map['overallTotalBytes'] as num?)?.toInt() ?? 0,
      done: map['done'] as bool? ?? false,
    );
  }

  factory ModelDownloadProgress.empty() {
    return const ModelDownloadProgress(
      modelId: '',
      modelFileName: '',
      bytesForModel: 0,
      totalBytesForModel: 0,
      overallBytesDownloaded: 0,
      overallTotalBytes: 0,
      done: false,
    );
  }

  double get overallFraction => overallTotalBytes == 0
      ? 0.0
      : (overallBytesDownloaded / overallTotalBytes).clamp(0.0, 1.0);

  /// A transfer speed, e.g. "4.2 MB/s".
  static String formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  /// True while a file has all its bytes but is still being checked (the
  /// last step before it counts as downloaded).
  bool get isVerifying =>
      !done && totalBytesForModel > 0 && bytesForModel >= totalBytesForModel;

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
