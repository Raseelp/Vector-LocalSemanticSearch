import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
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
  }) async {
    final tokenizer = await ClipTokenizer.load();
    final tokens = tokenizer.tokenize(query);

    debugPrint('tokens generated for the query $query ${tokens.toString()}');
    try {
      final results = await _channel.invokeMethod<List<dynamic>>(
        'searchByText',
        {'tokens': tokens, 'topK': limitNumber},
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
  }) async {
    try {
      final results = await _channel.invokeMethod<List<dynamic>>(
        "searchByImage",
        {"uri": uri, "topK": limit},
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

  Future<ImageMetadata?> loadMetadataByUri({required String uri}) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'loadMetadataByUri',
        {'uri': uri},
      );

      return result != null ? ImageMetadata.fromMap(result) : null;
    } on Exception catch (e) {
      debugPrint(e.toString());
      return null;
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

  Future<void> retryBackgroundScan() async {
    await _channel.invokeMethod<bool>('retryBackgroundScan');
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
