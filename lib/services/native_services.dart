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

  // ---- Faces ----

  static const _faceProgressChannel = EventChannel('twentyonevision/faceProgress');

  /// Live status ticks from the face scan (also delivered while it runs in the
  /// background). Same fields as [FaceStatus].
  Stream<FaceStatus> faceProgress() => _faceProgressChannel
      .receiveBroadcastStream()
      .map((e) => FaceStatus.fromMap(e as Map<dynamic, dynamic>));

  /// Starts the automatic face scan; does nothing if it is already running.
  Future<void> startFaceScan() async {
    await _channel.invokeMethod('startFaceScan');
  }

  /// Stops the face scan and keeps it stopped (nothing restarts it automatically).
  Future<void> pauseFaceScan() => _channel.invokeMethod('pauseFaceScan');

  /// Lets the face scan run again (and starts it if there is anything to do).
  Future<void> resumeFaceScan() => _channel.invokeMethod('resumeFaceScan');

  Future<FaceStatus> faceStatus() async {
    final map = await _channel.invokeMapMethod<String, dynamic>('faceStatus');
    return FaceStatus.fromMap(map!);
  }

  Future<List<Person>> listPeople({bool hidden = false}) async {
    final list = await _channel.invokeListMethod<dynamic>('listPeople', {'hidden': hidden});
    return (list ?? const []).map((e) => Person.fromMap(e as Map<dynamic, dynamic>)).toList();
  }

  Future<Person?> personSummary(int personId) async {
    final map = await _channel.invokeMapMethod<String, dynamic>('personSummary', {'personId': personId});
    return map == null ? null : Person.fromMap(map);
  }

  /// A person's photos, in the shape the search results grid reads.
  Future<List<Map<String, dynamic>>> personPhotos(int personId) async {
    final list = await _channel.invokeListMethod<dynamic>('personPhotos', {'personId': personId});
    return (list ?? const []).cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Photos by several people at once. [mode]: 'any', 'together' or 'only'
  /// (see PeopleMode). Same shape as [personPhotos].
  Future<List<Map<String, dynamic>>> peoplePhotos(List<int> personIds, String mode) async {
    final list = await _channel.invokeListMethod<dynamic>('peoplePhotos', {'personIds': personIds, 'mode': mode});
    return (list ?? const []).cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// How many photos each mode would give for these people.
  Future<Map<String, int>> peopleCounts(List<int> personIds) async {
    final map = await _channel.invokeMapMethod<String, dynamic>('peopleCounts', {'personIds': personIds});
    return {for (final e in (map ?? const <String, dynamic>{}).entries) e.key: (e.value as num).toInt()};
  }

  Future<List<PersonFace>> personFaces(int personId) async {
    final list = await _channel.invokeListMethod<dynamic>('personFaces', {'personId': personId});
    return (list ?? const []).map((e) => PersonFace.fromMap(e as Map<dynamic, dynamic>)).toList();
  }

  /// The recognised people in one photo, with where their faces are.
  ///
  /// [token] identifies the viewer asking: if it is closed before the request's turn
  /// comes, [cancelPhotoFaces] with the same token skips the (then pointless) scan.
  Future<List<PhotoFace>> photoFaces(String uri, {int? token}) async {
    final list = await _channel.invokeListMethod<dynamic>('photoFaces', {'uri': uri, 'token': token});
    return (list ?? const []).map((e) => PhotoFace.fromMap(e as Map<dynamic, dynamic>)).toList();
  }

  /// Who is in the frame at [positionMs] of a video, looked up now (nothing is stored). Faces
  /// come back with made-up negative ids, just to tell them apart. [token] as in [photoFaces].
  Future<List<PhotoFace>> videoFaces(String uri, int positionMs, {int? token}) async {
    final list = await _channel.invokeListMethod<dynamic>(
      'videoFaces',
      {'uri': uri, 'positionMs': positionMs, 'token': token},
    );
    return (list ?? const []).map((e) => PhotoFace.fromMap(e as Map<dynamic, dynamic>)).toList();
  }

  /// The faces a scan stored for the frame at exactly [tsMs] of a video: [VideoFrameFaces.exact]
  /// says whether their positions can be trusted on the player's picture at once.
  Future<VideoFrameFaces> videoFrameFaces(String uri, int tsMs) async {
    final map = await _channel.invokeMapMethod<String, dynamic>('videoFrameFaces', {'uri': uri, 'tsMs': tsMs});
    if (map == null) return VideoFrameFaces(false, const []);
    return VideoFrameFaces(
      map['exact'] as bool? ?? false,
      ((map['faces'] as List?) ?? const []).map((e) => PhotoFace.fromMap(e as Map<dynamic, dynamic>)).toList(),
    );
  }

  /// The people the background scan found in a video, and when (earliest first).
  Future<List<VideoPerson>> videoPeople(String uri) async {
    final list = await _channel.invokeListMethod<dynamic>('videoPeople', {'uri': uri});
    return (list ?? const []).map((e) => VideoPerson.fromMap(e as Map<dynamic, dynamic>)).toList();
  }

  /// Whether a video can be scanned and has been ('needs', 'done', 'unavailable'), and how loose
  /// the next scan of it will be.
  Future<VideoScanInfo> videoScanState(String uri) async {
    final map = await _channel.invokeMapMethod<String, dynamic>('videoScanState', {'uri': uri});
    return map == null ? VideoScanInfo('unavailable', 0, null) : VideoScanInfo.fromMap(map);
  }

  /// A video the user asked to scan: scans it now if it hasn't been (its people are then ready
  /// for [videoPeople]). True if it was scanned; false if it already was, or can't be.
  /// Follow its progress with [photoScanStatus] (key "video:" + the uri).
  Future<VideoScanResult> scanVideoFaces(String uri, {int? token}) async {
    final map = await _channel.invokeMapMethod<String, dynamic>('scanVideoFaces', {'uri': uri, 'token': token});
    return map == null ? VideoScanResult(false, 0, 0) : VideoScanResult.fromMap(map);
  }

  Future<void> cancelPhotoFaces(int token) => _channel.invokeMethod('cancelPhotoFaces', {'token': token});

  /// How far the scan of a photo opened in the viewer has got, or null if none is running.
  Future<PhotoScanStatus?> photoScanStatus(String uri) async {
    final map = await _channel.invokeMapMethod<String, dynamic>('photoScanStatus', {'uri': uri});
    return map == null ? null : PhotoScanStatus.fromMap(map);
  }

  /// A square picture of one face.
  Future<Uint8List> faceCrop(int faceId, {int size = 256}) async {
    final bytes = await _channel.invokeMethod<List<int>>('faceCrop', {'faceId': faceId, 'size': size});
    return Uint8List.fromList(bytes!);
  }

  Future<void> renamePerson(int personId, String? name) =>
      _channel.invokeMethod('renamePerson', {'personId': personId, 'name': name});

  Future<void> hidePerson(int personId, bool hidden) =>
      _channel.invokeMethod('hidePerson', {'personId': personId, 'hidden': hidden});

  /// Joins [otherId] into [keepId]; the name and edits carry over.
  ///
  /// Returns the merge's history id (for undoing it), 0 if nothing was merged.
  Future<int> mergePeople({required int keepId, required int otherId}) async {
    final id = await _channel.invokeMethod<int>('mergePeople', {'keepId': keepId, 'otherId': otherId});
    return id ?? 0;
  }

  /// Merges that can still be undone, newest first.
  Future<List<MergeRecord>> mergeHistory() async {
    final list = await _channel.invokeListMethod<dynamic>('mergeHistory');
    return (list ?? const []).map((e) => MergeRecord.fromMap(e as Map<dynamic, dynamic>)).toList();
  }

  /// The two groups a person's faces fall into, or null if there are too few clear faces.
  Future<SplitPreview?> previewSplit(int personId) async {
    final map = await _channel.invokeMapMethod<String, dynamic>('previewSplit', {'personId': personId});
    return map == null ? null : SplitPreview.fromMap(map);
  }

  /// Moves [faceIds] out of the person into a new one; returns the new person's id.
  Future<int> splitPerson(int personId, List<int> faceIds) async =>
      await _channel.invokeMethod<int>('splitPerson', {'personId': personId, 'faceIds': faceIds}) ?? 0;

  /// Splits a merged person back out; false if that merge can't be found any more.
  Future<bool> undoMerge(int id) async => await _channel.invokeMethod<bool>('undoMerge', {'id': id}) ?? false;

  /// Pairs of people who may be the same person, most likely first.
  Future<List<MergeSuggestion>> suggestMerges({int limit = 20}) async {
    final list = await _channel.invokeListMethod<dynamic>('suggestMerges', {'limit': limit});
    return (list ?? const []).map((e) => MergeSuggestion.fromMap(e as Map<dynamic, dynamic>)).toList();
  }

  /// "These are different people": never suggested or merged automatically again.
  Future<void> rejectMerge(int a, int b) => _channel.invokeMethod('rejectMerge', {'a': a, 'b': b});

  Future<void> removeFace(int faceId) => _channel.invokeMethod('removeFace', {'faceId': faceId});

  Future<void> regroupFaces() => _channel.invokeMethod('regroupFaces');

  /// Forgets every face and person (names too); the next scan starts over.
  Future<void> resetFaces() => _channel.invokeMethod('resetFaces');

  Future<void> setFaceSettings({bool? thorough, bool? refine, String? strictness, bool? scanVideos, String? videoDensity}) =>
      _channel.invokeMethod('setFaceSettings', {
        'thorough': thorough,
        'refine': refine,
        'strictness': strictness,
        'scanVideos': scanVideos,
        'videoDensity': videoDensity,
      });

  /// Runs the one-off speed test for this phone again.
  Future<void> retuneFaces() => _channel.invokeMethod('retuneFaces');

  /// The face models found on the device (bundled or dropped into [FaceModels.dir]).
  Future<FaceModels> faceModels() async {
    final map = await _channel.invokeMapMethod<String, dynamic>('faceModels');
    return FaceModels.fromMap(map!);
  }

  Future<void> selectFaceModel({required String kind, required String id}) async {
    await _channel.invokeMethod('selectFaceModel', {'kind': kind, 'id': id});
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

  /// The search (CLIP) models are downloaded and verified.
  Future<bool> areModelsReady() async {
    return await _channel.invokeMethod<bool>('areModelsReady') ?? false;
  }

  /// Everything the app needs is on the device: the search models and the
  /// face recognition model.
  Future<bool> areAllModelsReady() async {
    return await _channel.invokeMethod<bool>('areAllModelsReady') ?? false;
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
  ///
  /// [groups] picks what to download: 'search' (the CLIP models, the
  /// default) and/or 'faces' (the face recognition model). The result says
  /// whether everything asked for is now on the device.
  Future<bool> downloadModels({List<String> groups = const ['search']}) async {
    try {
      return await _channel.invokeMethod<bool>('downloadModels', {'groups': groups}) ?? false;
    } on PlatformException catch (e) {
      debugPrint('downloadModels failed: ${e.code} ${e.message}');
      rethrow;
    }
  }

  Future<void> cancelModelDownload() async {
    await _channel.invokeMethod('cancelModelDownload');
  }

  /// Deletes every model - the search models and the face recognition model.
  Future<void> deleteModels() async {
    await _channel.invokeMethod('deleteModels');
  }


  Stream<ModelDownloadProgress> modelDownloadProgressStream() {
    return _modelDownloadChannel.receiveBroadcastStream().map(
      (event) => ModelDownloadProgress.fromMap(Map<dynamic, dynamic>.from(event)),
    );
  }
}

/// A group of faces believed to be one person.
class Person {
  Person({
    required this.id,
    required this.name,
    required this.hidden,
    required this.faceCount,
    required this.photoCount,
    required this.coverFaceId,
  });

  final int id;
  final String? name;
  final bool hidden;
  final int faceCount, photoCount;
  final int coverFaceId;

  factory Person.fromMap(Map<dynamic, dynamic> m) => Person(
        id: (m['id'] as num).toInt(),
        name: m['name'] as String?,
        hidden: m['hidden'] as bool? ?? false,
        faceCount: (m['faceCount'] as num).toInt(),
        photoCount: (m['photoCount'] as num).toInt(),
        coverFaceId: (m['coverFaceId'] as num).toInt(),
      );
}

/// The two groups one person's faces fall into (the bigger group first).
class SplitPreview {
  SplitPreview({required this.first, required this.second, required this.firstCovers, required this.secondCovers});

  final List<int> first, second; // every face id in each group
  final List<int> firstCovers, secondCovers; // a few clear ones to show

  factory SplitPreview.fromMap(Map<dynamic, dynamic> m) {
    List<int> ints(String key) => (m[key] as List).map((e) => (e as num).toInt()).toList();
    return SplitPreview(
      first: ints('first'),
      second: ints('second'),
      firstCovers: ints('firstCovers'),
      secondCovers: ints('secondCovers'),
    );
  }
}

/// One merge the user made, as remembered for undo.
class MergeRecord {
  MergeRecord({
    required this.id,
    required this.keptId,
    required this.keptName,
    required this.keptCover,
    required this.removedName,
    required this.removedCover,
    required this.faceCount,
    required this.createdAt,
  });

  final int id;
  final int keptId;
  final String? keptName;
  final int? keptCover; // a face of the person who stayed
  final String? removedName;
  final int? removedCover; // a face of the person who was folded in
  final int faceCount; // faces that moved
  final int createdAt; // millis since epoch

  factory MergeRecord.fromMap(Map<dynamic, dynamic> m) => MergeRecord(
        id: (m['id'] as num).toInt(),
        keptId: (m['keptId'] as num).toInt(),
        keptName: m['keptName'] as String?,
        keptCover: (m['keptCover'] as num?)?.toInt(),
        removedName: m['removedName'] as String?,
        removedCover: (m['removedCover'] as num?)?.toInt(),
        faceCount: (m['faceCount'] as num?)?.toInt() ?? 0,
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
      );
}

/// Two people who may be one.
class MergeSuggestion {
  MergeSuggestion({required this.aId, required this.bId, required this.score});

  final int aId, bId;
  // How alike they look, roughly 0.3 (maybe) to 0.6 (very likely).
  final double score;

  factory MergeSuggestion.fromMap(Map<dynamic, dynamic> m) => MergeSuggestion(
        aId: (m['a'] as num).toInt(),
        bId: (m['b'] as num).toInt(),
        score: (m['score'] as num).toDouble(),
      );
}

/// One face of a person (for the review screen).
/// What tapping a video's scan button would do.
class VideoScanInfo {
  VideoScanInfo(this.state, this.level, this.lastFaces);

  final String state; // 'needs', 'done' or 'unavailable'
  final int level; // how loose the next scan is: 0 standard, 1 looser, 2 loosest
  final int? lastFaces; // faces the last scan kept (null: never scanned)

  factory VideoScanInfo.fromMap(Map<dynamic, dynamic> m) => VideoScanInfo(
        m['state'] as String? ?? 'unavailable',
        (m['level'] as num?)?.toInt() ?? 0,
        (m['lastFaces'] as num?)?.toInt(),
      );
}

/// How a video scan went.
class VideoScanResult {
  VideoScanResult(this.scanned, this.level, this.faces);

  final bool scanned;
  final int level; // the search level it used
  final int faces; // faces kept

  factory VideoScanResult.fromMap(Map<dynamic, dynamic> m) => VideoScanResult(
        m['scanned'] as bool? ?? false,
        (m['level'] as num?)?.toInt() ?? 0,
        (m['faces'] as num?)?.toInt() ?? 0,
      );
}

/// Stored faces of one video frame; [exact]: the scan read exact frames, so they line up on screen.
class VideoFrameFaces {
  VideoFrameFaces(this.exact, this.faces);

  final bool exact;
  final List<PhotoFace> faces;
}

/// A person seen in a video, and at which moments (ms).
class VideoPerson {
  VideoPerson({required this.person, required this.times, this.storedTimes = const []});

  final Person person;
  final List<int> times;

  /// The moments where a face of theirs is stored (a position to point at) - a subset of [times].
  final List<int> storedTimes;

  factory VideoPerson.fromMap(Map<dynamic, dynamic> m) => VideoPerson(
        person: Person.fromMap(m['person'] as Map<dynamic, dynamic>),
        times: (m['times'] as List? ?? const []).map((e) => (e as num).toInt()).toList(),
        storedTimes: (m['stored'] as List? ?? const []).map((e) => (e as num).toInt()).toList(),
      );
}

/// Progress of the face scan of one photo: which step, and how many faces.
class PhotoScanStatus {
  PhotoScanStatus({
    required this.stage,
    required this.faces,
    required this.total,
    required this.more,
    this.video = false,
    this.step = 0,
    this.steps = 0,
    this.relax = 0,
  });

  final String stage; // reading, detecting, recognising, placing
  final int faces; // faces found
  final int total; // faces being recognised
  final bool more; // finishing a photo scanned before
  final bool video; // a whole video being scanned
  final int step, steps; // a video: frames looked through so far, of how many
  final int relax; // a video: how loose the search is (0 standard, 1 looser, 2 loosest)

  factory PhotoScanStatus.fromMap(Map<dynamic, dynamic> m) => PhotoScanStatus(
        stage: m['stage'] as String? ?? 'reading',
        faces: (m['faces'] as num?)?.toInt() ?? 0,
        total: (m['total'] as num?)?.toInt() ?? 0,
        more: m['more'] as bool? ?? false,
        video: m['video'] as bool? ?? false,
        step: (m['step'] as num?)?.toInt() ?? 0,
        steps: (m['steps'] as num?)?.toInt() ?? 0,
        relax: (m['relax'] as num?)?.toInt() ?? 0,
      );

  /// What to tell the person, in a few words.
  String get message {
    String faceWord(int n) => n == 1 ? '1 face' : '$n faces';
    if (video) {
      switch (stage) {
        case 'detecting':
          final mode = relax >= 2 ? 'Loosest search' : relax == 1 ? 'Looser search' : 'Scanning';
          return steps > 0
              ? '$mode · frame $step of $steps${faces > 0 ? ' · ${faceWord(faces)} spotted' : ''}'
              : 'Opening the video';
        case 'recognising':
          return 'Identifying ${faceWord(total)}';
        case 'placing':
          return 'Matching faces to people';
        default:
          return 'Opening the video';
      }
    }
    switch (stage) {
      case 'reading':
        return 'Opening the photo';
      case 'detecting':
        return 'Looking for faces';
      case 'recognising':
        return more ? 'Identifying ${total == 1 ? '1 more face' : '$total more faces'}' : 'Found ${faceWord(faces)} · identifying';
      case 'placing':
        return faces == 0 ? 'No faces here' : 'Matching ${faceWord(total == 0 ? faces : total)} to people';
      default:
        return 'Looking for faces';
    }
  }
}

/// A recognised face in a photo: where it is (0..1 fractions of the upright photo) and who it is.
class PhotoFace {
  PhotoFace({
    required this.faceId,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.photoW,
    required this.photoH,
    required this.person,
  });

  final int faceId;
  final double left, top, right, bottom;
  final int photoW, photoH; // 0 if unknown
  final Person person;

  factory PhotoFace.fromMap(Map<dynamic, dynamic> m) => PhotoFace(
        faceId: (m['faceId'] as num).toInt(),
        left: (m['left'] as num).toDouble(),
        top: (m['top'] as num).toDouble(),
        right: (m['right'] as num).toDouble(),
        bottom: (m['bottom'] as num).toDouble(),
        photoW: (m['photoW'] as num?)?.toInt() ?? 0,
        photoH: (m['photoH'] as num?)?.toInt() ?? 0,
        person: Person.fromMap(m['person'] as Map<dynamic, dynamic>),
      );
}

class PersonFace {
  PersonFace({required this.faceId, required this.good, required this.photoUri, this.isVideo = false});

  final int faceId;
  // False for small / blurry / turned-away faces that weren't used to decide who the person is.
  final bool good;
  final String photoUri;
  final bool isVideo; // found in a video: photoUri is the video

  factory PersonFace.fromMap(Map<dynamic, dynamic> m) => PersonFace(
        faceId: (m['faceId'] as num).toInt(),
        good: m['good'] as bool? ?? true,
        photoUri: m['photoUri'] as String? ?? '',
        isVideo: m['isVideo'] as bool? ?? false,
      );
}

/// Where the automatic face scan is, plus the current totals.
class FaceStatus {
  FaceStatus({
    this.running = false,
    this.paused = false,
    this.userPaused = false,
    this.done = false,
    this.phase = 'scan',
    this.refine = true,
    this.deferredPhotos = 0,
    this.tuning,
    this.processed = 0,
    this.total = 0,
    this.faces = 0,
    this.people = 0,
    this.failed = 0,
    this.runProcessed = 0,
    this.elapsedMs = 0,
    this.error,
    this.ready = true,
    this.thorough = false,
    this.strictness = 'balanced',
    this.modelsDir = '',
    this.scanVideos = true,
    this.videoDensity = 'balanced',
    this.videos = 0,
    this.videosTotal = 0,
  });

  // paused: waiting for photo indexing to finish. userPaused: stopped by the user.
  final bool running, paused, userPaused, done;

  // What the scan is doing: 'scan' (finding and recognising the clear faces),
  // 'refine' (the small / blurry ones, afterwards) or 'tune' (a one-off speed
  // test for this phone). While refining, processed/total count photos of that pass.
  final String phase;

  // Whether the refining pass is switched on, and how many photos still have
  // faces waiting for it.
  final bool refine;
  final int deferredPhotos;

  // What the speed test picked for this phone, for the options sheet.
  final String? tuning;
  final int processed, total, faces, people, failed, runProcessed, elapsedMs;
  final String? error;
  // False when no recognition model is installed.
  final bool ready;
  final bool thorough;
  final String strictness;
  final String modelsDir;

  // Videos: whether they are scanned, how many frames ('fast' / 'balanced' / 'thorough'),
  // and how many are done of how many.
  final bool scanVideos;
  final String videoDensity;
  final int videos, videosTotal;

  /// Photos (or videos, in the videos pass) left in the pass that is running now.
  int get phaseRemaining => (total - processed).clamp(0, total);

  /// Photos still to work on overall, including faces waiting for the refining pass.
  int get remaining => phase == 'refine' ? phaseRemaining : phaseRemaining + (refine ? deferredPhotos : 0);

  FaceStatus withUserPaused(bool value) => FaceStatus(
        running: value ? false : running,
        paused: paused,
        userPaused: value,
        done: done,
        phase: phase,
        refine: refine,
        deferredPhotos: deferredPhotos,
        tuning: tuning,
        processed: processed,
        total: total,
        faces: faces,
        people: people,
        failed: failed,
        runProcessed: runProcessed,
        elapsedMs: elapsedMs,
        error: error,
        ready: ready,
        thorough: thorough,
        strictness: strictness,
        modelsDir: modelsDir,
        scanVideos: scanVideos,
        videoDensity: videoDensity,
        videos: videos,
        videosTotal: videosTotal,
      );

  double? get fraction => total > 0 ? (processed / total).clamp(0.0, 1.0) : null;

  /// Rough time left, from this run's pace; null until there is enough to go on.
  Duration? get eta {
    if (!running || paused || runProcessed < 10 || elapsedMs < 4000) return null;
    final remaining = total - processed;
    if (remaining <= 0) return null;
    final perPhotoMs = elapsedMs / runProcessed;
    return Duration(milliseconds: (perPhotoMs * remaining).round());
  }

  /// A tick from the running scan: keeps what a tick doesn't carry from [previous].
  FaceStatus mergedOnto(FaceStatus previous) => FaceStatus(
        running: running,
        paused: paused,
        userPaused: userPaused,
        done: done,
        phase: phase,
        refine: previous.refine,
        deferredPhotos: previous.deferredPhotos,
        tuning: previous.tuning,
        processed: processed,
        total: total,
        faces: faces,
        people: people,
        failed: failed,
        runProcessed: runProcessed,
        elapsedMs: elapsedMs,
        error: error,
        ready: error == 'no_model' ? false : previous.ready,
        thorough: previous.thorough,
        strictness: previous.strictness,
        modelsDir: previous.modelsDir,
        scanVideos: previous.scanVideos,
        videoDensity: previous.videoDensity,
        videos: previous.videos,
        videosTotal: previous.videosTotal,
      );

  factory FaceStatus.fromMap(Map<dynamic, dynamic> m) => FaceStatus(
        running: m['running'] as bool? ?? false,
        paused: m['paused'] as bool? ?? false,
        userPaused: m['userPaused'] as bool? ?? false,
        done: m['done'] as bool? ?? false,
        phase: m['phase'] as String? ?? 'scan',
        refine: m['refine'] as bool? ?? true,
        deferredPhotos: (m['deferredPhotos'] as num?)?.toInt() ?? 0,
        tuning: m['tuning'] as String?,
        processed: (m['processed'] as num?)?.toInt() ?? 0,
        total: (m['total'] as num?)?.toInt() ?? 0,
        faces: (m['faces'] as num?)?.toInt() ?? 0,
        people: (m['people'] as num?)?.toInt() ?? 0,
        failed: (m['failed'] as num?)?.toInt() ?? 0,
        runProcessed: (m['runProcessed'] as num?)?.toInt() ?? 0,
        elapsedMs: (m['elapsedMs'] as num?)?.toInt() ?? 0,
        error: m['error'] as String?,
        ready: m['ready'] as bool? ?? true,
        thorough: m['thorough'] as bool? ?? false,
        strictness: m['strictness'] as String? ?? 'balanced',
        modelsDir: m['modelsDir'] as String? ?? '',
        scanVideos: m['scanVideos'] as bool? ?? true,
        videoDensity: m['videoDensity'] as String? ?? 'balanced',
        videos: (m['videos'] as num?)?.toInt() ?? 0,
        videosTotal: (m['videosTotal'] as num?)?.toInt() ?? 0,
      );
}

class FaceModelInfo {
  FaceModelInfo({
    required this.kind,
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.source,
    required this.selected,
  });

  final String kind; // 'detector' | 'embedder'
  final String id;
  final String name;
  final int sizeBytes;
  final String source; // 'bundled' | 'device'
  final bool selected;

  factory FaceModelInfo.fromMap(Map<dynamic, dynamic> m) => FaceModelInfo(
        kind: m['kind'] as String,
        id: m['id'] as String,
        name: m['name'] as String,
        sizeBytes: (m['sizeBytes'] as num).toInt(),
        source: m['source'] as String,
        selected: m['selected'] as bool,
      );
}

class FaceModels {
  FaceModels({required this.dir, required this.models});

  /// Folder on the device to drop new .onnx models into.
  final String dir;
  final List<FaceModelInfo> models;

  List<FaceModelInfo> ofKind(String kind) => models.where((m) => m.kind == kind).toList();

  factory FaceModels.fromMap(Map<dynamic, dynamic> m) => FaceModels(
        dir: m['dir'] as String,
        models: (m['models'] as List)
            .map((e) => FaceModelInfo.fromMap(e as Map<dynamic, dynamic>))
            .toList(),
      );
}
