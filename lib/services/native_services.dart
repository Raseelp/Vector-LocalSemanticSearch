import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/library_stats.dart';
import 'package:twentyonevision/models/meta_data_model.dart';
import 'package:twentyonevision/models/model_status.dart';
import 'package:twentyonevision/tokanizer/clip_tokenizer.dart';

/// Thrown when a native call fails because the CLIP models aren't
/// downloaded/verified yet, so callers can redirect to the download screen.
class ModelsNotReadyError implements Exception {
  const ModelsNotReadyError();
}

class NativeServices {
  static const MethodChannel _channel = MethodChannel('twentyonevision/native');
  static const _progressChannel = EventChannel('twentyonevision/progress');
  static const _modelDownloadChannel = EventChannel(
    'twentyonevision/modelDownload',
  );
  /// Opens the SAF folder picker, returns the picked tree URI or null if
  /// cancelled. Split from scan() so the caller can derive a stable folder
  /// identity from the URI before the scan starts.
  Future<String?> pickFolderUri() async {
    try {
      return await _channel.invokeMethod<String>('pickFolder');
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') {
        debugPrint('Folder picking cancelled by user');
        return null;
      }
      rethrow;
    }
  }

  Future<bool?> scan({
    required String folderId,
    required PickingMode pickingMode,
    required String uri,
    required ContentMode contentMode,
  }) async {
    final NativeController nativeController = Get.find();
    try {
      final String pickingModeString = nativeController.getPickingModeString(
        pickingMode: pickingMode,
      );
      final String contentModeString = nativeController.getContentModeString(
        contentMode: contentMode,
      );
      final result = await _channel.invokeMethod('scanImagesAndOrVideos', {
        'mode': pickingModeString,
        'uri': uri,
        'folderId': folderId,
        'contentMode': contentModeString,
      });
      return result;
    } on PlatformException catch (e) {
      if (e.code == 'MODELS_NOT_READY') throw const ModelsNotReadyError();
      debugPrint('Error in scan: ${e.toString()}');
      return null;
    } catch (e) {
      debugPrint('Unexpected error: ${e.toString()}');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> searchImages({
    required String query,
    required int limitNumber,
    required ContentMode contentMode,
  }) async {
    final tokenizer = await ClipTokenizer.load();
    final tokens = tokenizer.tokenize(query);
    final NativeController nativeController = Get.find();

    debugPrint('tokens generated for the query $query ${tokens.toString()}');
    try {
      final results = await _channel.invokeMethod<List<dynamic>>(
        'searchByText',
        {
          'tokens': tokens,
          'topK': limitNumber,
          'contentMode': nativeController.getContentModeString(
            contentMode: contentMode,
          ),
        },
      );

      return results!
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } on PlatformException catch (e) {
      if (e.code == 'MODELS_NOT_READY') throw const ModelsNotReadyError();
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> searchByImage({
    required String uri,
    int limit = 20,
    required ContentMode contentMode,
  }) async {
    final NativeController nativeController = Get.find();
    try {
      final results = await _channel.invokeMethod<List<dynamic>>(
        "searchByImage",
        {
          "uri": uri,
          "topK": limit,
          "contentMode": nativeController.getContentModeString(
            contentMode: contentMode,
          ),
        },
      );

      return results!
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } on PlatformException catch (e) {
      if (e.code == 'MODELS_NOT_READY') throw const ModelsNotReadyError();
      rethrow;
    }
  }

  /// Raw (unnormalized) text embedding for an already-tokenized prompt -
  /// what collections average into their query embedding.
  Future<List<double>> encodeText(List<int> tokens) async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('encodeText', {'tokens': tokens});
      return (result ?? const []).map((e) => (e as num).toDouble()).toList();
    } on PlatformException catch (e) {
      if (e.code == 'MODELS_NOT_READY') throw const ModelsNotReadyError();
      rethrow;
    }
  }

  /// Raw embedding of a photo - or of one frame of a video, when
  /// [timestampMs] is given.
  Future<List<double>> encodeImage({required String uri, int? timestampMs}) async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('encodeImage', {
        'uri': uri,
        'timestampMs': timestampMs,
      });
      return (result ?? const []).map((e) => (e as num).toDouble()).toList();
    } on PlatformException catch (e) {
      if (e.code == 'MODELS_NOT_READY') throw const ModelsNotReadyError();
      rethrow;
    }
  }

  /// One pass over the index scoring every collection at once - see
  /// EmbeddingEngine's "Collections" section. [collections] entries carry
  /// id, embedding, contentMode and k.
  Future<List<Map<String, dynamic>>> scoreCollections(
    List<Map<String, dynamic>> collections,
  ) async {
    final results = await _channel.invokeMethod<List<dynamic>>('scoreCollections', {
      'collections': collections,
    });
    return (results ?? const []).cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Every member of one collection, best first (capped at [limit]).
  Future<List<Map<String, dynamic>>> collectionMembers(
    Map<String, dynamic> collection, {
    int limit = 200,
  }) async {
    final results = await _channel.invokeMethod<List<dynamic>>('collectionMembers', {
      'collections': [collection],
      'limit': limit,
    });
    return (results ?? const []).cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Image search seeded by one moment of a video rather than a picked photo.
  Future<List<Map<String, dynamic>>> searchByVideoFrame({
    required String uri,
    required int timestampMs,
    int limit = 20,
    required ContentMode contentMode,
  }) async {
    final NativeController nativeController = Get.find();
    try {
      final results = await _channel.invokeMethod<List<dynamic>>('searchByVideoFrame', {
        'uri': uri,
        'timestampMs': timestampMs,
        'topK': limit,
        'contentMode': nativeController.getContentModeString(contentMode: contentMode),
      });

      return results!.cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } on PlatformException catch (e) {
      if (e.code == 'MODELS_NOT_READY') throw const ModelsNotReadyError();
      rethrow;
    }
  }

  /// "Why this matched" for one result - scores each candidate word's own
  /// embedding against that specific item, lazily, for whichever result
  /// the user actually opened. Empty list (not an error) if the item's
  /// embedding can no longer be found (deleted/re-embedded since the
  /// search ran) or if anything else goes wrong - this is a nice-to-have
  /// detail, never worth surfacing a failure for.
  Future<List<Map<String, dynamic>>> explainMatch({
    required String path,
    required bool isVideo,
    required int timestampMs,
    required List<String> words,
  }) async {
    if (words.isEmpty) return [];

    final tokenizer = await ClipTokenizer.load();
    final wordArgs = words
        .map((w) => {'word': w, 'tokens': tokenizer.tokenize(w)})
        .toList();

    try {
      final results = await _channel.invokeMethod<List<dynamic>>('explainMatch', {
        'path': path,
        'isVideo': isVideo,
        'timestampMs': timestampMs,
        'words': wordArgs,
      });

      return (results ?? [])
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (e) {
      debugPrint('explainMatch failed: $e');
      return [];
    }
  }

  Future<Uint8List> loadImageBytes({
    required String uri,
    required bool isCompressed,
  }) async {
    final bytes = await _channel.invokeMethod<List<int>>('loadImageBytes', {
      'uri': uri,
      'compress': isCompressed,
    });

    return Uint8List.fromList(bytes!);
  }

  /// A small (grid/card sized) JPEG - far cheaper than [loadImageBytes],
  /// which returns a full-screen-sized image.
  Future<Uint8List> loadThumbnail({
    required String uri,
    required bool isVideo,
    int timestampMs = 0,
    int size = 400,
  }) async {
    final bytes = await _channel.invokeMethod<List<int>>('loadThumbnail', {
      'uri': uri,
      'isVideo': isVideo,
      'timestampMs': timestampMs,
      'size': size,
    });
    return Uint8List.fromList(bytes!);
  }

  Future<Uint8List> loadVideoThumbnail({
    required String uri,
    required int timestampMs,
  }) async {
    final bytes = await _channel.invokeMethod<List<int>>('loadVideoThumbnail', {
      'uri': uri,
      'timestampMs': timestampMs,
    });
    return Uint8List.fromList(bytes!);
  }

  Future<ImageMetadata?> loadMetadataByUri({
    required String uri,
    bool isVideo = false,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'loadMetadataByUri',
        {'uri': uri, 'isVideo': isVideo},
      );

      return result != null ? ImageMetadata.fromMap(result) : null;
    } on Exception catch (e) {
      debugPrint(e.toString());
      return null;
    }
  }

  /// Hands the file to Android's own share sheet - no bytes cross the
  /// platform channel, just the content URI already in hand.
  Future<bool> shareFile({required String uri, required bool isVideo}) async {
    try {
      return await _channel.invokeMethod<bool>('shareFile', {
            'uri': uri,
            'isVideo': isVideo,
          }) ??
          false;
    } catch (e) {
      debugPrint('shareFile failed: $e');
      return false;
    }
  }

  /// Copies the file into the system Photos/Gallery app's own storage -
  /// useful when the original was indexed from a folder that app can't see
  /// (an arbitrary SAF tree, a downloads folder, etc).
  Future<bool> saveCopyToGallery({required String uri, required bool isVideo}) async {
    try {
      return await _channel.invokeMethod<bool>('saveCopyToGallery', {
            'uri': uri,
            'isVideo': isVideo,
          }) ??
          false;
    } catch (e) {
      debugPrint('saveCopyToGallery failed: $e');
      return false;
    }
  }

  Future<bool> setAsWallpaper({required String uri}) async {
    try {
      return await _channel.invokeMethod<bool>('setAsWallpaper', {'uri': uri}) ?? false;
    } catch (e) {
      debugPrint('setAsWallpaper failed: $e');
      return false;
    }
  }

  Future<bool> copyImageToClipboard({required String uri}) async {
    try {
      return await _channel.invokeMethod<bool>('copyImageToClipboard', {'uri': uri}) ?? false;
    } catch (e) {
      debugPrint('copyImageToClipboard failed: $e');
      return false;
    }
  }

  Stream<Map<String, dynamic>> scanProgressStream() {
    return _progressChannel.receiveBroadcastStream().map(
      (event) => Map<String, dynamic>.from(event),
    );
  }

  Future<bool> cancelScanning() async {
    return await _channel.invokeMethod<bool>('cancelEmbedding') ?? false;
  }

  /// The latest progress tick for a scan that's still running natively -
  /// null if none is. Used to resync a freshly (re)created Dart layer with
  /// a scan it didn't start (e.g. after the app was removed from Recents
  /// and reopened).
  Future<Map<String, dynamic>?> getActiveScanProgress() async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getActiveScanProgress',
    );
    return result != null ? Map<String, dynamic>.from(result) : null;
  }

  pickImageForSearching() async {
    return await _channel.invokeMethod('pickImage');
  }

  Future<void> deleteEmbeddingsByFolderId({required String folderId}) async {
    await _channel.invokeMethod<bool>('deleteEmbeddingsByFolderId', {
      'folderId': folderId,
    });
  }

  Future<int> getEmbeddingCount() async {
    return await _channel.invokeMethod<int>('getEmbeddingCount') ?? 0;
  }

  /// Backs the Library tab's stat tiles - total embeddings, distinct
  /// image/video counts, and the index's on-disk size, in one call.
  Future<LibraryStats> getLibraryStats() async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getLibraryStats',
    );
    return result != null ? LibraryStats.fromMap(result) : LibraryStats.empty();
  }

  Future<int> getEmbeddingCountForFolder({required String folderId}) async {
    return await _channel.invokeMethod<int>('getEmbeddingCountForFolder', {
          'folderId': folderId,
        }) ??
        0;
  }

  Future<void> clearEmbeddings() async {
    await _channel.invokeMethod('clearEmbeddings');
  }

  Future<bool> areModelsReady() async {
    return await _channel.invokeMethod<bool>('areModelsReady') ?? false;
  }

  Future<List<ModelStatus>> getModelInfo() async {
    final results = await _channel.invokeMethod<List<dynamic>>(
      'getModelInfo',
    );
    return (results ?? [])
        .cast<Map>()
        .map((e) => ModelStatus.fromMap(e))
        .toList();
  }

  /// Progress is reported via [modelDownloadProgressStream]; this only
  /// resolves once the download finishes or fails.
  Future<bool> downloadModels() async {
    try {
      return await _channel.invokeMethod<bool>('downloadModels') ?? false;
    } on PlatformException catch (e) {
      debugPrint('downloadModels failed: ${e.code} ${e.message}');
      rethrow;
    }
  }

  Future<void> cancelModelDownload() async {
    await _channel.invokeMethod('cancelModelDownload');
  }

  Future<void> deleteModels() async {
    await _channel.invokeMethod('deleteModels');
  }

  Stream<ModelDownloadProgress> modelDownloadProgressStream() {
    return _modelDownloadChannel.receiveBroadcastStream().map(
      (event) => ModelDownloadProgress.fromMap(Map<dynamic, dynamic>.from(event)),
    );
  }
}
