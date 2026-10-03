import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:twentyonevision/controllers/collections_controller.dart';
import 'package:twentyonevision/controllers/faces_controller.dart';
import 'package:twentyonevision/db/indexed_folder_db_helper.dart';
import 'package:twentyonevision/models/indexed_folder_model.dart';
import 'package:twentyonevision/models/meta_data_model.dart';
import 'package:twentyonevision/models/model_status.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/query_words.dart';
import 'package:twentyonevision/view/widget/mention_text_controller.dart';

class NativeController extends GetxController with WidgetsBindingObserver {
  // Keys for the preferences persisted below - see
  // _loadPersistedPreferences/toggleSelectedContentMode/setResultsLayout/
  // setSliderValue/setSearchContentMode.
  static const _contentModeKey = 'scan_content_mode';
  static const _resultsLayoutKey = 'results_layout';
  static const _resultsLimitKey = 'results_limit';
  static const _searchContentModeKey = 'search_content_mode';
  // See _persistInterruptedScanMarker/_checkForInterruptedScan.
  static const _interruptedScanKey = 'interrupted_scan';
  // folderId -> how many files couldn't be embedded the last time that
  // location finished scanning. See _recordFailedForFolder.
  static const _failedByFolderKey = 'failed_by_folder';

  @override
  onInit() async {
    WidgetsBinding.instance.addObserver(this);
    await _loadPersistedPreferences();
    unawaited(_loadBenchLogs());
    await checkModelsReady();
    await getAllFoldersList();
    await refreshLibraryStats();
    await checkBackgroundScanPermission();
    await _resumeActiveScanIfAny();
    await _checkForInterruptedScan();
    _refreshCollections();
    super.onInit();
  }

  // Counts/covers for the Collections tab depend on the index, so anything
  // that changes it (startup once models are known, a finished scan, a
  // clear) re-scores them. Guarded - the collections controller is
  // registered right after this one, so it may not exist yet at the very
  // start.
  void _refreshCollections() {
    if (Get.isRegistered<CollectionsController>()) {
      unawaited(Get.find<CollectionsController>().refreshStats());
    }
  }

  // Scan mode (images/videos/both), results layout (list/grid columns),
  // and the results-per-search limit are just standing preferences, not
  // something tied to any one scan or search - loaded once here before
  // anything else needs them, so the UI opens already showing what the
  // user picked last time rather than resetting to the defaults every
  // launch.
  Future<void> _loadPersistedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final modeName = prefs.getString(_contentModeKey);
      if (modeName != null) {
        selectedContentMode = ContentMode.values.firstWhere(
          (m) => m.name == modeName,
          orElse: () => ContentMode.both,
        );
      }

      final layoutName = prefs.getString(_resultsLayoutKey);
      if (layoutName != null) {
        resultsLayout = ResultsLayout.values.firstWhere(
          (l) => l.name == layoutName,
          orElse: () => ResultsLayout.bento,
        );
      }

      final limit = prefs.getDouble(_resultsLimitKey);
      if (limit != null) {
        sliderValue = limit.clamp(10, 100).toDouble();
      }


      final failedRaw = prefs.getString(_failedByFolderKey);
      if (failedRaw != null) {
        final decoded = jsonDecode(failedRaw) as Map;
        _failedByFolder
          ..clear()
          ..addAll(decoded.map((k, v) => MapEntry(k as String, v as int)));
        totalFailed = _failedByFolder.values.fold(0, (a, b) => a + b);
      }

      final searchModeName = prefs.getString(_searchContentModeKey);
      if (searchModeName != null) {
        searchContentMode = ContentMode.values.firstWhere(
          (m) => m.name == searchModeName,
          orElse: () => ContentMode.both,
        );
      }

      update();
    } catch (e) {
      // Worst case the app just opens with the defaults, same as before
      // this existed - never worth blocking startup over.
      debugPrint('Failed to load persisted preferences: $e');
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    searchFocusNode.dispose();
    super.onClose();
  }

  // A permanently-denied notification permission hands off to the app's
  // system settings screen (see requestBackgroundScanPermission) and
  // returns immediately, well before the user has actually responded to
  // it - checking right after that call reads the answer too early and
  // leaves the "Enable" control stuck showing stale state until something
  // else happens to refresh it. Re-checking on resume (the same pattern
  // the storage-permissions card already uses) catches the real answer
  // the moment the user comes back from that screen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(checkBackgroundScanPermission());
    }
  }

  // Which home tab is showing: 0 Search, 1 Collections, 2 Library. Lives
  // here (not in the home screen's own state) so something opened from
  // another tab - a photo inside a collection - can send the user to Search.
  int homeTab = 0;

  void setHomeTab(int index) {
    if (homeTab == index) return;
    homeTab = index;
    update();
  }

  int total = 0;
  int embedded = 0;
  int skipped = 0;
  // The four kept in step by refreshLibraryStats - totalEmbeddings is raw
  // embedding vectors (a video contributes several, one per frame);
  // images/videos are distinct media item counts; indexSizeBytes is the
  // on-disk size of the embeddings store itself.
  int totalEmbeddings = 0;
  int totalImages = 0;
  int totalVideos = 0;
  int indexSizeBytes = 0;
  double sliderValue = 10;
  List<Map<String, dynamic>> searchResults = [];
  bool isScanning = false;
  // Set by _checkForInterruptedScan when a scan was still running last time
  // this app process existed but isn't anymore (killed by the OS rather
  // than finished or explicitly stopped - see _persistInterruptedScanMarker)
  // and no live one was found to reconnect to. Null means there's nothing
  // to offer resuming. Keys: folderId, uri, mode, contentMode.
  Map<String, String>? interruptedScan;

  // Files that couldn't be embedded (corrupt, unsupported, unreadable) as of
  // each location's last completed scan - shown as the Library tab's
  // "Failed" tile. A failed file isn't stored, so every rescan retries it;
  // that's also why a finished library still counted a few files as "new".
  final Map<String, int> _failedByFolder = {};
  int totalFailed = 0;

  // Set when a scan runs all the way to the end (not cancelled, not
  // errored) - drives the Library tab's completion card. Cleared by the
  // card itself, or when the next scan begins.
  ScanSummary? scanSummary;

  void dismissScanSummary() {
    if (scanSummary == null) return;
    scanSummary = null;
    update();
  }

  Future<void> _persistFailedByFolder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_failedByFolderKey, jsonEncode(_failedByFolder));
    } catch (e) {
      debugPrint('Failed to persist failed counts: $e');
    }
  }

  Future<void> _recordFailedForFolder(String folderId, int failed) async {
    if (failed > 0) {
      _failedByFolder[folderId] = failed;
    } else {
      _failedByFolder.remove(folderId);
    }
    totalFailed = _failedByFolder.values.fold(0, (a, b) => a + b);
    update();
    await _persistFailedByFolder();
  }

  // Whether the OS will show our scan-progress notification (see
  // ScanForegroundService natively). Never requested automatically - we
  // already ask for storage/media access right before a scan, and asking
  // for both at once overwhelms people. Instead the scanning UI offers its
  // own "Enable" control; this just reflects the OS's actual current
  // answer, re-checked on app open and whenever a scan starts.
  bool backgroundNotificationsGranted = false;
  bool isSearching = false;
  bool isFetchingMetadata = false;
  bool showMetadata = false;
  String error = '';
  String scannedPath = '';
  // Recognises one named person typed plainly, or picked via "@", inside the query itself -
  // see MentionTextEditingController's own doc for how runSearch() below uses it.
  final MentionTextEditingController searchTextController =
      MentionTextEditingController(
        peopleProvider: () => Get.isRegistered<FacesController>()
            ? Get.find<FacesController>().people
            : const [],
      );
  // The search box's focus, held here so the navigation bar's Search button
  // can put the cursor in it.
  final FocusNode searchFocusNode = FocusNode();
  ContentMode selectedContentMode = ContentMode.both;
  // What a search is filtered to include - separate from
  // selectedContentMode above, which governs scanning (what to embed),
  // not searching (what to search across). Set via the search filter
  // sheet - see setSearchContentMode.
  ContentMode searchContentMode = ContentMode.both;
  final Map<String, Uint8List> imageCache = {};

  // The image attached for a reverse-image search - picking one no longer
  // searches immediately. It's held here (shown as a preview chip) until
  // the user explicitly submits, same as typing text doesn't search until
  // Search is pressed.
  String? pickedSearchImageUri;
  // Set only when the attached "image" is really one frame of a video - the
  // uri above is then the video's, not a photo's. See searchWithVideoFrame.
  int? pickedSearchVideoTimestampMs;
  Uint8List? pickedSearchImageBytes;

  // The last submitted *text* query, if that's how the currently-shown
  // results were found - null after an image-based search, since there's
  // no text to explain a match by. Set in runSearch, read by
  // loadMatchExplanation when a result gets opened.
  //
  // Deliberately the mention-stripped phrase, not the raw box text - a
  // name isn't something CLIP has any concept of, so it's not what "why
  // this matched" should explain. lastMentionedPersonIds/Names below are
  // the other half of the same search, snapshotted separately rather than
  // re-read live off searchTextController later (which may have since been
  // edited for the *next* search by the time something asks).
  String? lastTextQuery;
  List<int> lastMentionedPersonIds = [];
  List<String> lastMentionedPeopleNames = [];

  /// The last search's free text with any mentioned names put back in front
  /// of it - what a "save as collection" name/query field should show,
  /// since [lastTextQuery] alone silently drops them.
  String get lastQueryWithMentions {
    final text = lastTextQuery ?? '';
    if (lastMentionedPeopleNames.isEmpty) return text;
    final names = lastMentionedPeopleNames.join(' and ');
    return text.isEmpty ? names : '$names $text';
  }

  // Set when the results on screen came from an image search (a picked photo,
  // "search with this image", or a video frame) - what "Save as collection"
  // turns into a photo-seeded collection. Null after a text search.
  String? lastImageSeedUri;
  int? lastImageSeedTimestampMs;

  // "Why this matched" for whichever result is currently open - see
  // loadMatchExplanation. Empty until that resolves, or if there's
  // nothing to explain (image-based search, or a query with no real
  // content words in it).
  List<MapEntry<String, double>> matchExplanation = [];

  // "Similar to this" - the small strip shown from the viewer instead of
  // running the full search straight away. Its own list and thumbnail
  // cache, separate from searchResults/imageCache above, since those
  // represent a different (and much larger) result set that a real search
  // would clear and replace. See loadSimilar.
  List<Map<String, dynamic>> similarResults = [];
  final Map<String, Uint8List> similarThumbCache = {};
  bool isLoadingSimilar = false;

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
  // runSearch), which would otherwise blank this strip mid-scan.
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

  // Throttles the Library tab's live stat refresh during an active scan -
  // see _maybeRefreshLibraryStatsLive.
  DateTime? _lastLiveStatsRefresh;

  final db = IndexedFolderDbHelper.instance;
  ImageMetadata selectedMetadata = ImageMetadata.empty();

  List<IndexedFolder> allIndexedFoldersList = [];

  // Search (CLIP) models ready.
  bool modelsReady = false;

  // Everything needed to use the app is ready: the search models AND the face
  // recognition model. The setup screen shows until this is true.
  bool allModelsReady = false;
  bool isCheckingModels = true;
  List<ModelStatus> modelStatuses = [];
  bool isDownloadingModels = false;
  ModelDownloadProgress downloadProgress = ModelDownloadProgress.empty();
  String downloadError = '';
  StreamSubscription<ModelDownloadProgress>? _downloadSub;

  // Download speed, in bytes per second over the last few seconds (smoothed);
  // null until there is a reading.
  double? downloadBytesPerSecond;
  DateTime? _speedAt;
  int _speedBytes = 0;

  /// Time left at the current speed, or null while unknown.
  Duration? get downloadEta {
    final rate = downloadBytesPerSecond;
    final progress = downloadProgress;
    if (rate == null || rate <= 0 || progress.overallTotalBytes == 0)
      return null;
    final left = progress.overallTotalBytes - progress.overallBytesDownloaded;
    if (left <= 0) return null;
    return Duration(seconds: (left / rate).round());
  }

  void _updateDownloadSpeed(ModelDownloadProgress progress) {
    final now = DateTime.now();
    final at = _speedAt;
    if (at == null || progress.overallBytesDownloaded < _speedBytes) {
      _speedAt = now;
      _speedBytes = progress.overallBytesDownloaded;
      return;
    }
    final seconds = now.difference(at).inMilliseconds / 1000.0;
    if (seconds < 1.0) return;
    final instant = (progress.overallBytesDownloaded - _speedBytes) / seconds;
    downloadBytesPerSecond = downloadBytesPerSecond == null
        ? instant
        : downloadBytesPerSecond! * 0.6 + instant * 0.4;
    _speedAt = now;
    _speedBytes = progress.overallBytesDownloaded;
  }

  List<ModelStatus> get _searchModels =>
      modelStatuses.where((m) => m.group == 'search').toList();
  List<ModelStatus> get _faceModels =>
      modelStatuses.where((m) => m.group == 'faces').toList();

  /// Size of the search (CLIP) models together.
  int get searchModelBytes =>
      _searchModels.fold<int>(0, (sum, m) => sum + m.sizeBytes);

  /// Size of the face recognition model.
  int get faceModelBytes =>
      _faceModels.fold<int>(0, (sum, m) => sum + m.sizeBytes);

  /// True once the search models are downloaded and verified.
  bool get searchModelsVerified =>
      _searchModels.isNotEmpty && _searchModels.every((m) => m.verified);

  /// True if the face recognition model was downloaded (not merely found on the device).
  bool get faceModelVerified =>
      _faceModels.isNotEmpty && _faceModels.every((m) => m.verified);

  /// What the setup screen's button would download right now (whatever isn't there yet).
  int get pendingDownloadBytes {
    var total = 0;
    if (!searchModelsVerified) total += searchModelBytes;
    if (!faceModelVerified) total += faceModelBytes;
    return total;
  }

  // Things that were computed while the models were missing (collection counts
  // and covers) are empty and nothing else would redo them: when the search
  // models come back - a finished download, or a check that finds them - redo
  // them now.
  Future<void> _modelsBecameReady() async {
    await refreshLibraryStats();
    _refreshCollections();
  }

  Future<void> checkModelsReady() async {
    final wasReady = modelsReady;
    try {
      modelsReady = await NativeServices().areModelsReady();
      allModelsReady = await NativeServices().areAllModelsReady();
      modelStatuses = await NativeServices().getModelInfo();
    } finally {
      isCheckingModels = false;
      update();
    }
    if (!wasReady && modelsReady) unawaited(_modelsBecameReady());
  }

  /// Downloads the models that aren't on the device yet: the search models,
  /// then the face recognition model ([onlyFaces] for just the latter).
  Future<void> startModelDownload({bool onlyFaces = false}) async {
    if (isDownloadingModels) return;

    final groups = <String>[if (!onlyFaces) 'search', 'faces'];

    isDownloadingModels = true;
    downloadError = '';
    downloadProgress = ModelDownloadProgress.empty();
    downloadBytesPerSecond = null;
    _speedAt = null;
    _speedBytes = 0;
    update();

    _downloadSub = NativeServices().modelDownloadProgressStream().listen((
      progress,
    ) {
      downloadProgress = progress;
      _updateDownloadSpeed(progress);
      update();
    });

    try {
      await NativeServices().downloadModels(groups: groups);
    } on PlatformException catch (e) {
      downloadError = e.message ?? e.code;
    } catch (e) {
      downloadError = e.toString();
    } finally {
      await _downloadSub?.cancel();
      _downloadSub = null;
      // What is really on the device, whatever happened (cancelled, or the search
      // models done and the face model failed): the setup screen goes by this.
      final wasReady = modelsReady;
      try {
        modelsReady = await NativeServices().areModelsReady();
        allModelsReady = await NativeServices().areAllModelsReady();
        modelStatuses = await NativeServices().getModelInfo();
      } catch (_) {}
      isDownloadingModels = false;
      update();
      if (!wasReady && modelsReady) unawaited(_modelsBecameReady());

      // A new face model means the face scan can start.
      if (faceModelVerified && Get.isRegistered<FacesController>()) {
        unawaited(Get.find<FacesController>().onFaceModelChanged());
      }
    }
  }

  Future<void> cancelModelDownload() async {
    await NativeServices().cancelModelDownload();
  }

  /// Deletes every model. The app then falls back to the setup screen (see AppGate).
  Future<void> deleteModels() async {
    await NativeServices().deleteModels();
    downloadError = '';
    await checkModelsReady();
    if (Get.isRegistered<FacesController>()) {
      unawaited(Get.find<FacesController>().onFaceModelChanged());
    }
  }

  // Just picks and previews - doesn't search. Mirrors typing text: nothing
  // runs until the user submits.
  Future<void> pickSearchImage() async {
    final uri = await NativeServices().pickImageForSearching();
    if (uri == null) return;

    pickedSearchImageUri = uri;
    pickedSearchVideoTimestampMs = null;
    pickedSearchImageBytes = null;
    update();

    try {
      pickedSearchImageBytes = await NativeServices().loadImageBytes(
        uri: uri,
        isCompressed: true,
      );
    } catch (_) {
      // Preview failed to load - the search itself still works from the
      // uri alone, so this isn't fatal, just a missing thumbnail.
    }
    update();
  }

  // "Search with this image" from the full-screen viewer - attaches the
  // photo exactly as if it had been picked from the search bar, then runs
  // the same search. The text box is cleared (an attached image takes
  // priority in runSearch anyway, but leaving stale text behind would show
  // up again the moment the image chip is removed), and the previous
  // result's match explanation goes too since it described a different
  // search.
  Future<void> searchWithImage({
    required String uri,
    required Uint8List bytes,
  }) {
    homeTab = 0;
    pickedSearchImageUri = uri;
    pickedSearchImageBytes = bytes;
    pickedSearchVideoTimestampMs = null;
    searchTextController.clear();
    matchExplanation = [];
    update();
    return runSearch();
  }

  // Same idea from the video viewer - the "image" is one frame of a video,
  // so the picked uri is the video's and the timestamp says which frame
  // (see runSearch). The preview bytes are that same frame, fetched here
  // since the search bar's chip needs something to show.
  Future<void> searchWithVideoFrame({
    required String uri,
    required int timestampMs,
  }) async {
    homeTab = 0;
    pickedSearchImageUri = uri;
    pickedSearchVideoTimestampMs = timestampMs;
    pickedSearchImageBytes = null;
    searchTextController.clear();
    matchExplanation = [];
    update();

    try {
      pickedSearchImageBytes = await NativeServices().loadVideoThumbnail(
        uri: uri,
        timestampMs: timestampMs,
      );
    } catch (_) {
      // Missing preview only - the search itself doesn't need it.
    }
    update();

    await runSearch();
  }

  // "Similar to this" - the same embedding search behind searchWithImage/
  // searchWithVideoFrame, but for a quick strip of ~10 results shown right
  // in the viewer instead of a full results screen. [timestampMs] set means
  // the seed is one frame of a video, same convention as above.
  //
  // The native side scores every stored embedding regardless of topK, so
  // asking for a small number costs nothing extra - the +3 over the 10 we
  // actually want just covers dropping the seed itself (it always comes
  // back as its own best match) without a second round trip.
  //
  // Guarded by _similarToken: this is shared, single-instance state, and
  // nothing stops two calls overlapping - closing the strip while a fetch
  // is still in flight (clearSimilar), or opening it again for a different
  // photo before the first fetch finished. Without a token, whichever call
  // happens to resolve last would win regardless of which one is actually
  // still wanted, silently repopulating results for a photo the viewer has
  // already moved on from.
  int _similarToken = 0;

  Future<void> loadSimilar({required String uri, int? timestampMs}) async {
    final token = ++_similarToken;
    similarResults = [];
    similarThumbCache.clear();
    isLoadingSimilar = true;
    update();

    try {
      final raw = timestampMs != null
          ? await NativeServices().searchByVideoFrame(
              uri: uri,
              timestampMs: timestampMs,
              limit: 13,
              contentMode: ContentMode.both,
            )
          : await NativeServices().searchByImage(
              uri: uri,
              limit: 13,
              contentMode: ContentMode.both,
            );
      if (token != _similarToken)
        return; // superseded while the search was in flight

      similarResults = raw
          .where((item) => (item['path'] as String?) != uri)
          .take(10)
          .toList();
      update();

      // Small and fast (grid-sized thumbnails, not full images) - loaded a
      // few at a time so the strip fills in rather than waiting on all ten.
      // update() rebuilds this whole viewer screen (the same one GetBuilder
      // covers everything else on it too), so - same as openPerson's own
      // thumbnail workers in faces_controller.dart - it's batched rather
      // than called after every single thumbnail, which for ten quick
      // fetches would otherwise mean up to ten extra full-screen rebuilds
      // stacked on top of whatever else is animating (the badge, playback).
      const workers = 3;
      var next = 0;
      var sinceUpdate = 0;
      Future<void> worker() async {
        while (true) {
          if (token != _similarToken) return;
          final i = next++;
          if (i >= similarResults.length) return;
          final item = similarResults[i];
          try {
            final bytes = await NativeServices().loadThumbnail(
              uri: item['path'] as String,
              isVideo: item['isVideo'] as bool? ?? false,
              timestampMs: (item['timestampMs'] as num?)?.toInt() ?? 0,
              size: 300,
            );
            if (token != _similarToken) return;
            similarThumbCache[cacheKeyForResult(item)] = bytes;
          } catch (_) {}
          if (token == _similarToken && ++sinceUpdate >= 3) {
            sinceUpdate = 0;
            update();
          }
        }
      }

      await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    } on ModelsNotReadyError {
      // Silently empty - the viewer itself already says elsewhere when
      // models aren't ready; this strip just has nothing to show.
    } catch (_) {
      // No strip - the viewer is still fully usable without it.
    } finally {
      if (token == _similarToken) {
        isLoadingSimilar = false;
        update();
      }
    }
  }

  void clearSimilar() {
    _similarToken++; // invalidates any load still in flight so it can't repopulate after this
    similarResults = [];
    similarThumbCache.clear();
    isLoadingSimilar = false;
  }

  void clearPickedSearchImage() {
    pickedSearchImageUri = null;
    pickedSearchImageBytes = null;
    pickedSearchVideoTimestampMs = null;
    update();
  }

  // The one submit action, whichever input is active - an attached image
  // takes priority over typed text (matching what's actually shown in the
  // search bar), never both at once.
  Future<void> runSearch() async {
    final imageUri = pickedSearchImageUri;
    final rawQuery = searchTextController.text.trim();
    if (imageUri == null && rawQuery.isEmpty) return;

    try {
      isSearching = true;
      error = '';
      update();
      searchResults = [];
      imageCache.clear();

      if (imageUri != null) {
        // No text behind an image-based search, so there's nothing to
        // explain a match by - see loadMatchExplanation's doc.
        lastTextQuery = null;
        lastMentionedPersonIds = [];
        lastMentionedPeopleNames = [];
        final frameMs = pickedSearchVideoTimestampMs;
        lastImageSeedUri = imageUri;
        lastImageSeedTimestampMs = frameMs;
        searchResults = frameMs != null
            ? await NativeServices().searchByVideoFrame(
                uri: imageUri,
                timestampMs: frameMs,
                limit: sliderValue.round().toInt(),
                contentMode: searchContentMode,
              )
            : await NativeServices().searchByImage(
                uri: imageUri,
                limit: sliderValue.round().toInt(),
                contentMode: searchContentMode,
              );
      } else {
        // Recognised people (typed plainly, or picked via "@" - "Person and Person2 at the
        // beach") narrow the search to photos/videos with all of them in it; their names are
        // dropped from what's sent to CLIP, since a name isn't something an image-similarity
        // model has any concept of - only the words describing what to find in those photos are.
        final mentionedPeople = <int, Person>{
          for (final p in searchTextController.recognizedPeople) p.id: p,
        }.values.toList();
        final mentionedIds = mentionedPeople.map((p) => p.id).toList();
        final query = searchTextController.queryWithoutMention;
        lastTextQuery = query;
        lastMentionedPersonIds = mentionedIds;
        // A Person can only ever be recognised/mentioned in the first place
        // if it has a name (see peopleProvider's own filter in
        // MentionTextEditingController) - never null here.
        lastMentionedPeopleNames = mentionedPeople.map((p) => p.name!).toList();
        lastImageSeedUri = null;
        lastImageSeedTimestampMs = null;
        searchResults = await NativeServices().searchImages(
          query: query,
          limitNumber: sliderValue.round().toInt(),
          contentMode: searchContentMode,
          personIds: mentionedIds,
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
      allModelsReady = false;
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

  Future<void> _fetchRecentThumbnail(
    RecentEmbeddedItem item,
    String key,
  ) async {
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
        if (!recentThumbnails.any(
          (e) => _recentThumbKey(e) == _recentThumbKey(removed),
        )) {
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

    await _beginScan(
      folderId: folderId,
      uri: uri,
      scanMode: scanMode,
      contentMode: contentMode,
    );
  }

  // Reuses a scan interrupted by the OS killing the app mid-run (see
  // _checkForInterruptedScan) - same folderId/uri as before, no picker
  // involved. Safe to skip the picker for a folder scan because
  // SafPickerActivity takes a *persistable* URI permission grant when the
  // folder was first picked, so it's still valid after an app restart.
  Future<void> resumeInterruptedScan() async {
    final marker = interruptedScan;
    if (marker == null || isScanning) return;

    final scanMode = marker['mode'] == 'device'
        ? PickingMode.device
        : PickingMode.folder;
    final contentMode = ContentMode.values.firstWhere(
      (m) => m.name == marker['contentMode'],
      orElse: () => ContentMode.both,
    );

    await _beginScan(
      folderId: marker['folderId'] ?? '',
      uri: marker['uri'] ?? '',
      scanMode: scanMode,
      contentMode: contentMode,
    );
  }

  // The user chose not to resume it - just forget it rather than keep
  // asking every launch.
  Future<void> dismissInterruptedScan() async {
    interruptedScan = null;
    update();
    await _clearInterruptedScanMarker();
  }

  // Shared by a fresh pick (pickAndScanFolders) and resuming an interrupted
  // one (resumeInterruptedScan) - everything from here on doesn't care how
  // the folderId/uri/mode were arrived at.
  Future<void> _beginScan({
    required String folderId,
    required String uri,
    required PickingMode scanMode,
    required ContentMode contentMode,
  }) async {
    // Never requested here - we're about to ask for storage/media access
    // below, and asking for notifications too would be one permission
    // prompt too many. Just refresh what the OS currently says, in case it
    // changed since the app opened (e.g. granted from system settings);
    // the scanning UI offers its own control to actually request it.
    unawaited(checkBackgroundScanPermission());

    isScanning = true;
    interruptedScan = null;
    scanSummary = null;
    scanResult = IndexedFolder.empty();
    recentEmbeddingsPerSecond = 0;
    _previousProgress = null;
    recentThumbnails = [];
    recentThumbBytes.clear();
    _recentThumbInFlight.clear();
    _lastRecentThumbFetch = null;
    _lastLiveStatsRefresh = null;
    error = '';
    update();

    // Written before the scan actually starts, not just on each progress
    // tick - so even a kill before the first tick arrives still leaves a
    // marker behind to resume from. Cleared on a clean finish, an explicit
    // stop, or an immediate failure below (see _listenToScanProgress's done
    // branch and this method's own failure branch).
    unawaited(
      _persistInterruptedScanMarker(
        folderId: folderId,
        uri: uri,
        scanMode: scanMode,
        contentMode: contentMode,
      ),
    );

    _listenToScanProgress();

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
      allModelsReady = false;
      error = 'Models are not downloaded yet.';
      result = null;
    }

    if (result == null || result == false) {
      isScanning = false;
      _progressSub.cancel();
      unawaited(_clearInterruptedScanMarker());

      if (result != null) {
        scanResult = IndexedFolder.empty();
        update();
      }

      return;
    }

    // Bookkeeping for a normal finish already ran from inside
    // _listenToScanProgress's done branch, above - by the time scan()
    // resolves, the native loop's last onProgress(done: true) tick has
    // already reached it.
  }

  // Shared by a scan started in this session and one resumed on app start
  // (see _resumeActiveScanIfAny) - either way, a live scan is identified by
  // the same progress stream and finishes the same way.
  void _listenToScanProgress() {
    _progressSub = NativeServices().scanProgressStream().listen((data) {
      final newResult = IndexedFolder.fromMap(data);

      final prev = _previousProgress;
      if (prev != null) {
        final embeddedDelta = newResult.embedded - prev.embedded;
        // Over indexing's own time: the waits while faces are found for a batch
        // would make it look slow (the time left still uses the real time).
        final msDelta = newResult.activeMs - prev.activeMs;
        // Ignore a duplicate/out-of-order tick rather than divide by ~0 and
        // show a meaningless spike. Also ignore a tick that embedded
        // nothing (e.g. a run of already-indexed files getting skipped
        // between two ticks) rather than let it compute a rate of exactly
        // 0 - that flipped the UI back to "measuring speed" every time a
        // skip happened, instead of only showing that once at the very
        // start. Leaving recentEmbeddingsPerSecond untouched here just
        // keeps showing the last real rate until the next tick that
        // actually embedded something.
        if (msDelta > 200 && embeddedDelta > 0) {
          recentEmbeddingsPerSecond = embeddedDelta / (msDelta / 1000.0);
        }
      }
      _previousProgress = newResult;
      scanResult = newResult;
      _maybeFetchNextRecentThumbnail(newResult.recentItems);
      _maybeRefreshLibraryStatsLive();

      if (scanResult.done) {
        isScanning = false;
        _progressSub.cancel();
        unawaited(_clearInterruptedScanMarker());
        // Only a scan that actually reached the end counts - a cancelled
        // one reports done too, with processed short of total, and an
        // errored one reports total 0.
        final completed =
            scanResult.total > 0 && scanResult.processed >= scanResult.total;
        // New photos are in the index now - the face scan picks them up.
        if (Get.isRegistered<FacesController>()) {
          unawaited(Get.find<FacesController>().startScan());
        }
        if (completed) {
          scanSummary = ScanSummary(
            total: scanResult.total,
            failed: scanResult.failed,
          );
          unawaited(_recordFailedForFolder(scanResult.id, scanResult.failed));
        }
        if (scanResult.id.isNotEmpty) {
          unawaited(_finishScan(folderId: scanResult.id));
        }
      }

      update();
    });
  }

  Future<void> _finishScan({required String folderId}) async {
    await addIndexedFolderToDb(indexedFolder: scanResult, folderId: folderId);
    await refreshLibraryStats();
    await getAllFoldersList();
    _refreshCollections();
  }

  // Removing the app from Recents doesn't kill this process (the
  // foreground service keeps it alive so the scan can finish), but it does
  // recreate the Activity/Flutter engine - so a scan started before that
  // keeps running natively with nothing telling this fresh Dart layer about
  // it. Called from onInit to resync with whatever the native side says is
  // still going, using the same cache the notification itself reads from.
  Future<void> _resumeActiveScanIfAny() async {
    final progress = await NativeServices().getActiveScanProgress();
    if (progress == null) return;

    final restored = IndexedFolder.fromMap(progress);
    if (restored.done) return;

    scanResult = restored;
    _previousProgress = restored;
    recentEmbeddingsPerSecond = 0;
    isScanning = true;
    recentThumbnails = [];
    recentThumbBytes.clear();
    _recentThumbInFlight.clear();
    _lastRecentThumbFetch = null;
    _maybeFetchNextRecentThumbnail(restored.recentItems);

    _listenToScanProgress();
    update();
  }

  // Called from onInit right after _resumeActiveScanIfAny - only reaches
  // here if that found nothing actually still running natively. If a
  // marker was still persisted at that point, the process that was running
  // it is gone without ever reaching a clean finish/stop, which on a
  // foreground-serviced, wake-locked scan realistically means the OS killed
  // it (see _persistInterruptedScanMarker for when the marker is written
  // and cleared). Surfacing that as "tap to resume" turns a silent failure
  // into a one-tap fix - the underlying embedImages() call already skips
  // whatever it finished before by hash, so resuming just picks up where
  // it left off rather than starting over.
  Future<void> _checkForInterruptedScan() async {
    if (isScanning) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_interruptedScanKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as Map;
      interruptedScan = decoded.map(
        (k, v) => MapEntry(k as String, v as String),
      );
      update();
    } catch (e) {
      debugPrint('Failed to read interrupted-scan marker: $e');
    }
  }

  Future<void> _persistInterruptedScanMarker({
    required String folderId,
    required String uri,
    required PickingMode scanMode,
    required ContentMode contentMode,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _interruptedScanKey,
        jsonEncode({
          'folderId': folderId,
          'uri': uri,
          'mode': scanMode.name,
          'contentMode': contentMode.name,
        }),
      );
    } catch (e) {
      debugPrint('Failed to persist interrupted-scan marker: $e');
    }
  }

  Future<void> _clearInterruptedScanMarker() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_interruptedScanKey);
    } catch (e) {
      debugPrint('Failed to clear interrupted-scan marker: $e');
    }
  }

  // Also backs the Library tab's live stat tiles - besides the explicit
  // call sites below (after a scan finishes, after clearing/deleting),
  // this is also called periodically while a scan is running (see
  // _listenToScanProgress) so the numbers climb in real time instead of
  // only updating once the whole scan completes.
  Future<void> refreshLibraryStats() async {
    final stats = await NativeServices().getLibraryStats();
    totalEmbeddings = stats.totalEmbeddings;
    totalImages = stats.images;
    totalVideos = stats.videos;
    indexSizeBytes = stats.sizeBytes;
    update();
  }

  // Throttled rather than called on every progress tick (twice a second) -
  // refreshLibraryStats re-reads the whole embeddings store from disk, and
  // doing that on every tick would compete with the scan's own I/O for a
  // large library, for no real benefit over updating every couple of
  // seconds. Still far more "live" than the old behavior of only updating
  // once the entire scan finishes.
  void _maybeRefreshLibraryStatsLive() {
    final now = DateTime.now();
    if (_lastLiveStatsRefresh != null &&
        now.difference(_lastLiveStatsRefresh!) < const Duration(seconds: 2)) {
      return;
    }
    _lastLiveStatsRefresh = now;
    unawaited(refreshLibraryStats());
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

  Future<void> loadMetaDataByUri({
    required String uri,
    bool isVideo = false,
  }) async {
    // Reset so the sheet doesn't open with the previous photo's metadata.
    showMetadata = false;
    selectedMetadata = ImageMetadata.empty();
    isFetchingMetadata = true;
    update();
    final data = await NativeServices().loadMetadataByUri(
      uri: uri,
      isVideo: isVideo,
    );
    if (data != null) {
      selectedMetadata = data;
    }
    isFetchingMetadata = false;
    update();
  }

  // Actions sheet (both viewers) - each a thin passthrough to native, since
  // the actual work (share intent, MediaStore copy, wallpaper, clipboard)
  // only makes sense done natively. Feedback (snackbar/share sheet opening)
  // is the calling widget's job, not this controller's - it needs a
  // BuildContext these don't have.
  Future<void> shareFile({required String uri, required bool isVideo}) {
    return NativeServices().shareFile(uri: uri, isVideo: isVideo);
  }

  Future<bool> saveFileCopy({required String uri, required bool isVideo}) {
    return NativeServices().saveCopyToGallery(uri: uri, isVideo: isVideo);
  }

  Future<bool> setPhotoAsWallpaper({required String uri}) {
    return NativeServices().setAsWallpaper(uri: uri);
  }

  Future<bool> copyImageToClipboard({required String uri}) {
    return NativeServices().copyImageToClipboard(uri: uri);
  }

  // Called when a result is actually opened, not for every result a
  // search returns - see NativeServices.explainMatch's doc on why this is
  // lazy. Silently leaves matchExplanation empty (no loading state, no
  // error) whenever there's nothing honest to show: an image-based
  // search, or a query with no real content words (e.g. just "photos of
  // it") - the UI section this backs simply doesn't appear in that case.
  Future<void> loadMatchExplanation({
    required String path,
    required bool isVideo,
    required int timestampMs,
    // Set when the result was opened from somewhere other than a text
    // search (a collection) - explains the match by that phrase instead.
    String? query,
  }) async {
    matchExplanation = [];

    query ??= lastTextQuery;
    if (query == null || query.isEmpty) {
      update();
      return;
    }
    final words = extractContentWords(query);
    if (words.isEmpty) {
      update();
      return;
    }
    update();

    final raw = await NativeServices().explainMatch(
      path: path,
      isVideo: isVideo,
      timestampMs: timestampMs,
      words: words,
    );

    final entries =
        raw
            .map(
              (m) => MapEntry(
                m['word'] as String,
                (m['score'] as num?)?.toDouble() ?? 0.0,
              ),
            )
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));

    matchExplanation = entries.take(3).toList();
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

  // Timing logs for indexing and face finding (adb logcat -s VectorBench). The
  // switch itself lives natively, where the logs are written; this mirrors it.
  bool benchLogsEnabled = true;

  Future<void> _loadBenchLogs() async {
    try {
      benchLogsEnabled = await NativeServices().benchLogsEnabled();
      update();
    } catch (_) {
      // Stays on, the default.
    }
  }

  Future<void> setBenchLogsEnabled(bool value) async {
    benchLogsEnabled = value;
    update();
    await NativeServices().setBenchLogsEnabled(value);
  }

  Future<void> clearAllEmbeddings() async {
    _failedByFolder.clear();
    totalFailed = 0;
    unawaited(_persistFailedByFolder());
    await NativeServices().clearEmbeddings();
    await db.clearFolderList();
    await getAllFoldersList();
    await refreshLibraryStats();
    _refreshCollections();
    update();
  }

  Future<void> deleteEmbeddingsByFolderid({required String folderId}) async {
    await NativeServices().deleteEmbeddingsByFolderId(folderId: folderId);
  }

  Future<void> deleteFolderById({required String id}) async {
    await _recordFailedForFolder(id, 0);
    await deleteEmbeddingsByFolderid(folderId: id);
    await db.deleteById(id);
    await getAllFoldersList();
    await refreshLibraryStats();
    _refreshCollections();
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

  // Explicit close, not a toggle - for anything that should only ever
  // close the sheet (tapping the photo, dragging the sheet down), never
  // flip it open. A no-op update() call when already closed is harmless.
  void hideMetadata() {
    if (!showMetadata) return;
    showMetadata = false;
    update();
  }

  void setSliderValue(double value) {
    sliderValue = value;
    update();
    unawaited(_persistDouble(_resultsLimitKey, value));
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

  // Read-only - reflects the OS's current answer without prompting.
  // No-op/always-granted pre-Android 13, where this permission doesn't exist.
  Future<void> checkBackgroundScanPermission() async {
    if (!Platform.isAndroid) {
      backgroundNotificationsGranted = true;
      update();
      return;
    }
    backgroundNotificationsGranted = await Permission.notification.isGranted;
    update();
  }

  // The only place that actually prompts for it - wired to the "Enable"
  // control in the scanning UI, never called automatically. No battery-
  // optimization-exemption request alongside it anymore - Play policy
  // only allows that for a short list of core-function use cases this
  // app doesn't fit, and the scan surviving being killed (WorkManager's
  // own retry-after-interruption) is the replacement for asking not to
  // be killed in the first place.
  Future<void> requestBackgroundScanPermission() async {
    if (!Platform.isAndroid) return;

    final status = await Permission.notification.status;
    if (status.isPermanentlyDenied) {
      // A second in-app prompt would be a no-op - the OS already stopped
      // asking. Settings is the only way left to turn it on.
      await openAppSettings();
    } else {
      await Permission.notification.request();
    }

    // Reads whatever actually landed above - the real value if the user
    // responded synchronously, a stale one otherwise, corrected by
    // didChangeAppLifecycleState the moment the app resumes for real.
    await checkBackgroundScanPermission();
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
    unawaited(_persistString(_contentModeKey, contentMode.name));
  }

  // Committed from the search filter sheet's draft state - never called
  // live per-tap, only once the user taps Confirm (see
  // _SearchFilterSheet). Whether this should also re-run the current
  // search is that widget's call, not this setter's.
  void setSearchContentMode(ContentMode contentMode) {
    searchContentMode = contentMode;
    update();
    unawaited(_persistString(_searchContentModeKey, contentMode.name));
  }

  ResultsLayout resultsLayout = ResultsLayout.bento;

  void setResultsLayout(ResultsLayout layout) {
    resultsLayout = layout;
    update();
    unawaited(_persistString(_resultsLayoutKey, layout.name));
  }

  Future<void> _persistString(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (e) {
      // Cosmetic preference, not core state - a failed write just means
      // it falls back to the default next launch, never worth surfacing.
      debugPrint('Failed to persist "$key": $e');
    }
  }

  Future<void> _persistDouble(String key, double value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(key, value);
    } catch (e) {
      debugPrint('Failed to persist "$key": $e');
    }
  }
}

/// What the Library tab's completion card shows once a scan runs to the end.
class ScanSummary {
  const ScanSummary({required this.total, required this.failed});

  final int total;
  final int failed;

  int get indexed => (total - failed).clamp(0, total);
}

enum PickingMode { device, folder }

enum ContentMode { both, videos, images }

enum ResultsLayout { list, grid2, grid3, grid4, bento }
