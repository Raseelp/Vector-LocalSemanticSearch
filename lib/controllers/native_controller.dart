import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:twentyonevision/db/indexed_folder_db_helper.dart';
import 'package:twentyonevision/models/indexed_folder_model.dart';
import 'package:twentyonevision/models/meta_data_model.dart';
import 'package:twentyonevision/models/model_status.dart';
import 'package:twentyonevision/services/native_services.dart';

class NativeController extends GetxController {
  @override
  onInit() async {
    await checkModelsReady();
    await getAllFoldersList();
    await getTotalEmbeddings();
    super.onInit();
  }

  int total = 0;
  int embedded = 0;
  int skipped = 0;
  int totalEmbeddings = 0;
  double sliderValue = 10;
  List<Map<String, dynamic>> searchResults = [];
  bool isScanning = false;
  bool isSearching = false;
  bool isFetchingMetadata = false;
  bool showMetadata = false;
  String error = '';
  String scannedPath = '';
  TextEditingController searchTextController = TextEditingController();
  ContentMode selectedContentMode = ContentMode.both;
  final Map<String, Uint8List> imageCache = {};
  late StreamSubscription<Map<String, dynamic>> _progressSub;
  IndexedFolder scanResult = IndexedFolder.empty();

  // Recent (not whole-scan-average) throughput, recomputed from consecutive
  // progress events - reacts within a couple of seconds to something that
  // actually changes speed, instead of being dragged down by the whole
  // scan's history like a cumulative average would be.
  double recentEmbeddingsPerSecond = 0;
  IndexedFolder? _previousProgress;

  // "Recently indexed" strip: a small, bounded, newest-first list of files
  // shown while a scan is running. Deliberately its own cache (not
  // imageCache) - a concurrent search clears imageCache on every run (see
  // searchUsingText), which would otherwise blank this strip mid-scan.
  // Fetching is throttled on purpose: the scan can embed several files per
  // progress tick, and fetching a thumbnail for every single one would
  // compete with the scan itself for I/O/CPU. One fetch per tick keeps the
  // strip feeling alive without adding meaningful load.
  static const int _maxRecentThumbnails = 8;
  static const Duration _recentThumbFetchThrottle = Duration(milliseconds: 900);
  List<RecentEmbeddedItem> recentThumbnails = [];
  final Map<String, Uint8List> recentThumbBytes = {};
  final Set<String> _recentThumbInFlight = {};
  DateTime? _lastRecentThumbFetch;

  final db = IndexedFolderDbHelper.instance;
  ImageMetadata selectedMetadata = ImageMetadata.empty();

  List<IndexedFolder> allIndexedFoldersList = [];

  bool modelsReady = false;
  bool isCheckingModels = true;
  List<ModelStatus> modelStatuses = [];
  bool isDownloadingModels = false;
  ModelDownloadProgress downloadProgress = ModelDownloadProgress.empty();
  String downloadError = '';
  StreamSubscription<ModelDownloadProgress>? _downloadSub;

  Future<void> checkModelsReady() async {
    try {
      modelsReady = await NativeServices().areModelsReady();
      modelStatuses = await NativeServices().getModelInfo();
    } finally {
      isCheckingModels = false;
      update();
    }
  }

  Future<void> startModelDownload() async {
    if (isDownloadingModels) return;

    isDownloadingModels = true;
    downloadError = '';
    downloadProgress = ModelDownloadProgress.empty();
    update();

    _downloadSub = NativeServices().modelDownloadProgressStream().listen((
      progress,
    ) {
      downloadProgress = progress;
      update();
    });

    try {
      final ok = await NativeServices().downloadModels();
      modelsReady = ok;
      modelStatuses = await NativeServices().getModelInfo();
    } on PlatformException catch (e) {
      downloadError = e.message ?? e.code;
    } catch (e) {
      downloadError = e.toString();
    } finally {
      await _downloadSub?.cancel();
      _downloadSub = null;
      isDownloadingModels = false;
      update();
    }
  }

  Future<void> cancelModelDownload() async {
    await NativeServices().cancelModelDownload();
  }

  Future<void> deleteModels() async {
    await NativeServices().deleteModels();
    await checkModelsReady();
  }

  Future<void> searchUsingText({required bool isSearchUsingImage}) async {
    try {
      isSearching = true;
      error = '';
      update();
      searchResults = [];
      imageCache.clear();

      if (isSearchUsingImage) {
        final uri = await NativeServices().pickImageForSearching();
        if (uri != null) {
          searchResults = await NativeServices().searchByImage(
            uri: uri,
            limit: sliderValue.round().toInt(),
          );
        }
      } else {
        searchResults = await NativeServices().searchImages(
          query: searchTextController.text,
          limitNumber: sliderValue.round().toInt(),
        );
      }

      debugPrint(searchResults.toString());

      for (final item in searchResults) {
        final uri = item['path'] as String;
        final isVideo = item['isVideo'] as bool? ?? false;
        final timestampMs = (item['timestampMs'] as num?)?.toInt() ?? 0;
        final cacheKey = isVideo ? '$uri@$timestampMs' : uri;

        if (!imageCache.containsKey(cacheKey)) {
          try {
            if (isVideo) {
              final bytes = await NativeServices().loadVideoThumbnail(
                uri: uri,
                timestampMs: timestampMs,
              );
              imageCache[cacheKey] = bytes;
            } else {
              final bytes = await NativeServices().loadImageBytes(
                uri: uri,
                isCompressed: true,
              );
              imageCache[cacheKey] = bytes;
            }
          } catch (_) {}
        }
      }
    } on ModelsNotReadyError {
      modelsReady = false;
      error = 'Models are not downloaded yet.';
    } finally {
      isSearching = false;
      update();
    }
  }

  String cacheKeyForResult(Map<String, dynamic> item) {
    final uri = item['path'] as String;
    final isVideo = item['isVideo'] as bool? ?? false;
    final timestampMs = (item['timestampMs'] as num?)?.toInt() ?? 0;
    return isVideo ? '$uri@$timestampMs' : uri;
  }

  String _recentThumbKey(RecentEmbeddedItem item) {
    return item.isVideo ? '${item.uri}@${item.timestampMs}' : item.uri;
  }

  // items is newest-first. Picks at most one not-yet-fetched item per
  // throttle window rather than draining the whole list, so a fast scan
  // can't turn this into a thumbnail-fetch flood.
  void _maybeFetchNextRecentThumbnail(List<RecentEmbeddedItem> items) {
    if (items.isEmpty) return;

    final now = DateTime.now();
    if (_lastRecentThumbFetch != null &&
        now.difference(_lastRecentThumbFetch!) < _recentThumbFetchThrottle) {
      return;
    }

    RecentEmbeddedItem? next;
    for (final item in items) {
      final key = _recentThumbKey(item);
      if (!recentThumbBytes.containsKey(key) &&
          !_recentThumbInFlight.contains(key)) {
        next = item;
        break;
      }
    }
    if (next == null) return;

    _lastRecentThumbFetch = now;
    final item = next;
    final key = _recentThumbKey(item);
    _recentThumbInFlight.add(key);

    _fetchRecentThumbnail(item, key);
  }

  Future<void> _fetchRecentThumbnail(RecentEmbeddedItem item, String key) async {
    try {
      final bytes = item.isVideo
          ? await NativeServices().loadVideoThumbnail(
              uri: item.uri,
              timestampMs: item.timestampMs,
            )
          : await NativeServices().loadImageBytes(
              uri: item.uri,
              isCompressed: true,
            );

      recentThumbBytes[key] = bytes;
      recentThumbnails.insert(0, item);
      if (recentThumbnails.length > _maxRecentThumbnails) {
        final removed = recentThumbnails.removeLast();
        // Only drop the cached bytes if nothing else in the strip still
        // needs them (same file could reappear if it hashes the same key).
        if (!recentThumbnails.any((e) => _recentThumbKey(e) == _recentThumbKey(removed))) {
          recentThumbBytes.remove(_recentThumbKey(removed));
        }
      }
      update();
    } catch (_) {
      // Cosmetic feature - never worth surfacing an error for a missed thumbnail.
    } finally {
      _recentThumbInFlight.remove(key);
    }
  }

  Future<void> pickAndScanFolders({required bool isScanEntirePhone}) async {
    if (isScanning) return;

    // Best-effort only - without it, the scan's keep-alive notification
    // just won't be visible. Never allowed to block or fail the scan
    // itself, so its result is deliberately ignored. No-op pre-Android 13.
    if (Platform.isAndroid) {
      unawaited(Permission.notification.request());
    }

    final PickingMode scanMode = isScanEntirePhone
        ? PickingMode.device
        : PickingMode.folder;
    final ContentMode contentMode = selectedContentMode;

    // Stable identity for this location, ties every scan of it together
    // across rescans - the device sentinel, or the folder's own SAF URI.
    String folderId;
    String uri;

    if (isScanEntirePhone) {
      folderId = IndexedFolderIdentity.device;
      uri = '';
    } else {
      final pickedUri = await NativeServices().pickFolderUri();
      if (pickedUri == null) {
        return; // user cancelled the picker - nothing changed
      }
      uri = pickedUri;
      folderId = pickedUri;
    }

    isScanning = true;
    scanResult = IndexedFolder.empty();
    recentEmbeddingsPerSecond = 0;
    _previousProgress = null;
    recentThumbnails = [];
    recentThumbBytes.clear();
    _recentThumbInFlight.clear();
    _lastRecentThumbFetch = null;
    error = '';
    update();

    _progressSub = NativeServices().scanProgressStream().listen((data) {
      final newResult = IndexedFolder.fromMap(data);

      final prev = _previousProgress;
      if (prev != null) {
        final embeddedDelta = newResult.embedded - prev.embedded;
        final msDelta = newResult.elapsedMs - prev.elapsedMs;
        // Ignore a duplicate/out-of-order tick rather than divide by ~0 and
        // show a meaningless spike.
        if (msDelta > 200) {
          recentEmbeddingsPerSecond = embeddedDelta / (msDelta / 1000.0);
        }
      }
      _previousProgress = newResult;
      scanResult = newResult;
      _maybeFetchNextRecentThumbnail(newResult.recentItems);

      if (scanResult.done) {
        isScanning = false;
        _progressSub.cancel();
      }

      update();
    });

    bool? result;
    try {
      result = await NativeServices().scan(
        folderId: folderId,
        pickingMode: scanMode,
        uri: uri,
        contentMode: contentMode,
      );
    } on ModelsNotReadyError {
      modelsReady = false;
      error = 'Models are not downloaded yet.';
      result = null;
    }

    if (result == null || result == false) {
      isScanning = false;
      _progressSub.cancel();

      if (result != null) {
        scanResult = IndexedFolder.empty();
        update();
      }

      return;
    }

    await addIndexedFolderToDb(indexedFolder: scanResult, folderId: folderId);
    await getTotalEmbeddings();
    await getAllFoldersList();
  }

  Future<void> listenProgress() async {
    NativeServices().scanProgressStream().listen((data) {
      IndexedFolder.fromMap(data);
      update();
    });
  }

  Future<void> getTotalEmbeddings() async {
    totalEmbeddings = await NativeServices().getEmbeddingCount();
    update();
  }

  Future<Uint8List> loadImageByURI({
    required String uri,
    bool? isCompressed,
  }) async {
    return await NativeServices().loadImageBytes(
      uri: uri,
      isCompressed: isCompressed ?? true,
    );
  }

  Future<void> loadMetaDataByUri({required String uri}) async {
    // Reset so the sheet doesn't open with the previous photo's metadata.
    showMetadata = false;
    selectedMetadata = ImageMetadata.empty();
    isFetchingMetadata = true;
    update();
    final data = await NativeServices().loadMetadataByUri(uri: uri);
    if (data != null) {
      selectedMetadata = data;
    }
    isFetchingMetadata = false;
    update();
  }

  Future<void> stopScanning() async {
    await NativeServices().cancelScanning();
  }

  // embedded is fetched fresh from native rather than accumulated here,
  // since native's per-scan numbers only describe that one scan.
  Future<void> addIndexedFolderToDb({
    required IndexedFolder indexedFolder,
    required String folderId,
  }) async {
    if (indexedFolder.path.isEmpty) return;

    final embeddedForFolder = await NativeServices().getEmbeddingCountForFolder(
      folderId: folderId,
    );

    final toSave = indexedFolder.copyWith(
      id: folderId,
      embedded: embeddedForFolder,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    await db.upsertFolder(folder: toSave);
    update();
  }

  Future<void> clearAllEmbeddings() async {
    await NativeServices().clearEmbeddings();
    await db.clearFolderList();
    await getAllFoldersList();
    await getTotalEmbeddings();
    update();
  }

  Future<void> deleteEmbeddingsByFolderid({required String folderId}) async {
    await NativeServices().deleteEmbeddingsByFolderId(folderId: folderId);
  }

  Future<void> deleteFolderById({required String id}) async {
    await deleteEmbeddingsByFolderid(folderId: id);
    await db.deleteById(id);
    await getAllFoldersList();
    await getTotalEmbeddings();
  }

  Future<void> getAllFoldersList() async {
    allIndexedFoldersList = await db.getAllFolders();
    update();
  }

  // Based on the whole-scan average rather than the recent/instantaneous
  // one - an ETA that jumps around every time the recent rate wobbles would
  // be more distracting than useful. Null until there's enough data to
  // bother estimating from.
  String? get scanEtaText {
    if (!isScanning) return null;
    final total = scanResult.total;
    final processed = scanResult.processed;
    if (total <= 0 || processed <= 0 || processed >= total) return null;

    final msPerItem = scanResult.elapsedMs / processed;
    final remainingMs = (msPerItem * (total - processed)).round();
    return formatDuration(milliseconds: remainingMs);
  }

  String formatDuration({required num milliseconds}) {
    if (milliseconds <= 0) return '0 Seconds';

    int totalSeconds = (milliseconds / 1000).floor();

    final int days = totalSeconds ~/ 86400;
    totalSeconds %= 86400;

    final int hours = totalSeconds ~/ 3600;
    totalSeconds %= 3600;

    final int minutes = totalSeconds ~/ 60;
    final int seconds = totalSeconds % 60;

    final List<String> parts = [];

    if (days > 0) parts.add('$days ${days == 1 ? 'Day' : 'Days'}');
    if (hours > 0) parts.add('$hours ${hours == 1 ? 'Hour' : 'Hours'}');
    if (minutes > 0) {
      parts.add('$minutes ${minutes == 1 ? 'Minute' : 'Minutes'}');
    }
    if (seconds > 0) {
      parts.add('$seconds ${seconds == 1 ? 'Second' : 'Seconds'}');
    }

    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.first;

    return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  }

  void toggleMetadata() {
    showMetadata = !showMetadata;
    update();
  }

  void setSliderValue(double value) {
    sliderValue = value;
    update();
  }

  Future<bool> requestMediaPermission({
    required ContentMode contentMode,
  }) async {
    if (!Platform.isAndroid) return true;

    final bool needsImages =
        contentMode == ContentMode.images || contentMode == ContentMode.both;
    final bool needsVideos =
        contentMode == ContentMode.videos || contentMode == ContentMode.both;

    final List<Permission> required = [
      if (needsImages) Permission.photos,
      if (needsVideos) Permission.videos,
    ];

    if (required.isEmpty) return true;

    bool allGranted = true;
    for (final p in required) {
      if (!await p.isGranted) {
        allGranted = false;
        break;
      }
    }
    if (allGranted) return true;

    final Map<Permission, PermissionStatus> statuses = await required.request();

    return statuses.values.every((s) => s.isGranted);
  }

  getPickingModeString({required PickingMode pickingMode}) {
    switch (pickingMode) {
      case PickingMode.device:
        return 'device';
      case PickingMode.folder:
        return 'folder';
    }
  }

  getContentModeString({required ContentMode contentMode}) {
    switch (contentMode) {
      case ContentMode.both:
        return 'both';
      case ContentMode.images:
        return 'images';
      case ContentMode.videos:
        return 'videos';
    }
  }

  void toggleSelectedContentMode({required ContentMode contentMode}) {
    selectedContentMode = contentMode;
    update();
  }
}

enum PickingMode { device, folder }

enum ContentMode { both, videos, images }
