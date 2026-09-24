class ImageMetadata {
  final String imagePath;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final int width;
  final int height;
  final int orientation;
  final String dateTime;
  final String cameraMake;
  final String cameraModel;
  final double? latitude;
  final double? longitude;
  // Video only - 0 for an image. Kept on this same model rather than a
  // separate VideoMetadata type since everything else here (name/size/
  // mime/resolution) already applies equally to both; the sheet just shows
  // this row only when it's non-zero.
  final int durationMs;

  const ImageMetadata({
    required this.imagePath,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.orientation,
    required this.dateTime,
    required this.cameraMake,
    required this.cameraModel,
    this.latitude,
    this.longitude,
    this.durationMs = 0,
  });

  factory ImageMetadata.fromMap(Map<dynamic, dynamic> map) {
    return ImageMetadata(
      imagePath: map['imagePath'] ?? '',
      fileName: map['fileName'] ?? '',
      fileSize: map['fileSize'] as int? ?? 0,
      mimeType: map['mimeType'] ?? '',
      width: map['width'] as int? ?? 0,
      height: map['height'] as int? ?? 0,
      orientation: map['orientation'] as int? ?? 0,
      dateTime: map['dateTime'] ?? '',
      cameraMake: map['cameraMake'] ?? '',
      cameraModel: map['cameraModel'] ?? '',
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
      durationMs: map['durationMs'] as int? ?? 0,
    );
  }

  factory ImageMetadata.empty() {
    return const ImageMetadata(
      imagePath: '',
      fileName: '',
      fileSize: 0,
      mimeType: '',
      width: 0,
      height: 0,
      orientation: 0,
      dateTime: '',
      cameraMake: '',
      cameraModel: '',
      latitude: null,
      longitude: null,
      durationMs: 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'fileName': fileName,
      'imagePath': imagePath,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'width': width,
      'height': height,
      'orientation': orientation,
      'dateTime': dateTime,
      'cameraMake': cameraMake,
      'cameraModel': cameraModel,
      'latitude': latitude,
      'longitude': longitude,
      'durationMs': durationMs,
    };
  }

  ImageMetadata copyWith({
    String? imagePath,
    String? fileName,
    int? fileSize,
    String? mimeType,
    int? width,
    int? height,
    int? orientation,
    String? dateTime,
    String? cameraMake,
    String? cameraModel,
    double? latitude,
    double? longitude,
    int? durationMs,
  }) {
    return ImageMetadata(
      imagePath: imagePath ?? this.imagePath,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      width: width ?? this.width,
      height: height ?? this.height,
      orientation: orientation ?? this.orientation,
      dateTime: dateTime ?? this.dateTime,
      cameraMake: cameraMake ?? this.cameraMake,
      cameraModel: cameraModel ?? this.cameraModel,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      durationMs: durationMs ?? this.durationMs,
    );
  }

  String get durationFormatted {
    final totalSeconds = durationMs ~/ 1000;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String get resolution => '${width}x$height';

  double get aspectRatio => height > 0 ? width / height : 0;

  String get fileSizeFormatted {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  bool get hasLocation => latitude != null && longitude != null;

  String get cameraInfo {
    if (cameraMake.isEmpty && cameraModel.isEmpty) return 'Unknown';
    if (cameraMake.isEmpty) return cameraModel;
    if (cameraModel.isEmpty) return cameraMake;
    return '$cameraMake $cameraModel';
  }
}
