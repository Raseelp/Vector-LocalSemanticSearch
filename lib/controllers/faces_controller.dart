import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/services/native_services.dart';

/// Everything about faces and people: the scan status (the scan runs by
/// itself in the background - see FaceScanner), the list of people, and the
/// one person currently open.
///
/// People appear while the scan is still running: every progress tick
/// schedules a (throttled) refresh of the list.
class FacesController extends GetxController {
  final _native = NativeServices();

  FaceStatus status = FaceStatus();
  List<Person> people = [];
  List<Person> hiddenPeople = [];
  bool isLoadingPeople = true;

  StreamSubscription<FaceStatus>? _progressSub;
  Timer? _refreshTimer;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void onInit() {
    super.onInit();
    _progressSub = _native.faceProgress().listen(_onProgress, onError: (_) {});
    refreshAll().then((_) => startScan());
  }

  @override
  void onClose() {
    _progressSub?.cancel();
    _refreshTimer?.cancel();
    super.onClose();
  }

  // ---- scan status ----

  /// Asks for the scan to run (it does nothing if it already is, and only
  /// looks at photos not done yet). Safe to call whenever it might help: on
  /// launch, when the Faces tab opens, after indexing finishes.
  Future<void> startScan() async {
    try {
      await _native.startFaceScan();
    } catch (e) {
      debugPrint('startFaceScan failed: $e');
    }
  }

  /// The user's stop button. Stays stopped, across restarts, until [resumeScan].
  Future<void> pauseScan() async {
    status = status.withUserPaused(true);
    _rate = null;
    _rateAt = null;
    update();
    try {
      await _native.pauseFaceScan();
    } catch (e) {
      debugPrint('pauseFaceScan failed: $e');
    }
  }

  Future<void> resumeScan() async {
    status = status.withUserPaused(false);
    update();
    try {
      await _native.resumeFaceScan();
    } catch (e) {
      debugPrint('resumeFaceScan failed: $e');
    }
    await refreshStatus();
  }

  // ---- speed ----
  //
  // Photos per second over the last few ticks (smoothed), not the whole run's
  // average - that would include time spent waiting and loading the models.

  double? _rate;
  DateTime? _rateAt;
  int _rateProcessed = 0;

  /// How fast the scan is going right now, in photos per second; null until known.
  double? get scanRate => _rate;

  /// Time left at the current speed, or null while the speed isn't known.
  Duration? get scanEta {
    final rate = _rate;
    if (rate == null || rate <= 0 || !status.running || status.paused) return null;
    // Only the pass running now: the refining pass goes at a different pace.
    final remaining = status.phaseRemaining;
    if (remaining <= 0) return null;
    return Duration(seconds: (remaining / rate).round());
  }

  void _updateRate(FaceStatus tick) {
    if (!tick.running || tick.paused) {
      _rate = null;
      _rateAt = null;
      return;
    }
    final now = DateTime.now();
    final at = _rateAt;
    // The first tick of a run (or a new run's counter starting over) sets the baseline.
    if (at == null || tick.runProcessed < _rateProcessed) {
      _rateAt = now;
      _rateProcessed = tick.runProcessed;
      return;
    }
    final seconds = now.difference(at).inMilliseconds / 1000.0;
    if (seconds < 1.5) return;
    final instant = (tick.runProcessed - _rateProcessed) / seconds;
    _rate = _rate == null ? instant : _rate! * 0.6 + instant * 0.4;
    _rateAt = now;
    _rateProcessed = tick.runProcessed;
  }

  void _onProgress(FaceStatus tick) {
    final wasRunning = status.running;
    status = tick.mergedOnto(status);
    _updateRate(tick);
    update();

    // A refresh at most every few seconds while running, and one when it ends.
    final due = DateTime.now().difference(_lastRefresh) > const Duration(seconds: 3);
    if (tick.done || (wasRunning && !tick.running) || (tick.running && due)) {
      _scheduleRefresh(immediate: tick.done);
    }
    // The scan just ended: now is the time to look for people who may be one.
    if (wasRunning && !tick.running) refreshSuggestions();
  }

  void _scheduleRefresh({bool immediate = false}) {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(immediate ? Duration.zero : const Duration(milliseconds: 400), refreshPeople);
  }

  Future<void> refreshStatus() async {
    try {
      status = await _native.faceStatus();
      update();
    } catch (e) {
      debugPrint('faceStatus failed: $e');
    }
  }

  Future<void> refreshAll() async {
    await refreshStatus();
    await refreshPeople();
    await refreshSuggestions();
  }

  // ---- people who may be one ----

  List<MergeSuggestion> _suggestions = [];

  /// Pairs of listed people who may be the same person, as (a, b, score) with
  /// both people known; most likely first.
  List<({Person a, Person b, double score})> get suggestions {
    final byId = {for (final p in people) p.id: p};
    return [
      for (final s in _suggestions)
        if (byId[s.aId] != null && byId[s.bId] != null) (a: byId[s.aId]!, b: byId[s.bId]!, score: s.score),
    ];
  }

  /// How alike [other] looks to [person], if they were suggested as a pair.
  double? suggestionScoreFor(Person person, Person other) {
    for (final s in _suggestions) {
      if ((s.aId == person.id && s.bId == other.id) || (s.aId == other.id && s.bId == person.id)) return s.score;
    }
    return null;
  }

  // Not while the scan runs: the list would change under it and it is extra work
  // for the phone at the busiest time.
  Future<void> refreshSuggestions() async {
    if (status.running) return;
    try {
      _suggestions = await _native.suggestMerges();
    } catch (e) {
      debugPrint('suggestMerges failed: $e');
    }
    update();
  }

  Future<void> refreshPeople() async {
    _lastRefresh = DateTime.now();
    try {
      final results = await Future.wait([
        _native.listPeople(),
        _native.listPeople(hidden: true),
      ]);
      people = results[0];
      hiddenPeople = results[1];
      _prefetchCrops(people.map((p) => p.coverFaceId));
    } catch (e) {
      debugPrint('listPeople failed: $e');
    }
    isLoadingPeople = false;
    update();
  }

  // ---- face pictures ----
  //
  // Each picture is cut from its photo on the phone, so how they are asked for
  // matters. At most a few are made at once (more just slow each other down);
  // the newest request goes first, because that is what is on screen now; and a
  // request nobody wants any more (scrolled far past) is dropped before it
  // starts. Covers of the people list are made quietly in advance.

  static const int _maxCropsInFlight = 3;
  static const int _cropCacheLimit = 800;

  final Map<int, Uint8List> _crops = {};
  final Map<int, Completer<Uint8List?>> _cropWaiters = {};
  final Map<int, int> _cropWanted = {};
  final List<int> _cropStack = []; // wanted now; newest last
  final List<int> _cropLow = []; // prefetch; oldest first
  final Set<int> _cropRunning = {};

  Uint8List? cachedCrop(int faceId) => _crops[faceId];

  /// The picture of a face; pair every call with [releaseCrop].
  Future<Uint8List?> crop(int faceId) {
    final cached = _crops[faceId];
    if (cached != null) return Future.value(cached);

    _cropWanted[faceId] = (_cropWanted[faceId] ?? 0) + 1;
    final existing = _cropWaiters[faceId];
    if (existing != null) {
      // Asked for again while waiting (or prefetched): now it matters.
      if (_cropStack.remove(faceId) || _cropLow.remove(faceId)) _cropStack.add(faceId);
      return existing.future;
    }
    final waiter = Completer<Uint8List?>();
    _cropWaiters[faceId] = waiter;
    _cropStack.add(faceId);
    _pumpCrops();
    return waiter.future;
  }

  /// Says a caller of [crop] no longer needs it (it got the picture, or went
  /// off screen). A picture nobody wants that hasn't started is dropped.
  void releaseCrop(int faceId) {
    final left = (_cropWanted[faceId] ?? 1) - 1;
    if (left > 0) {
      _cropWanted[faceId] = left;
      return;
    }
    _cropWanted.remove(faceId);
    if (_cropStack.remove(faceId)) _cropWaiters.remove(faceId)?.complete(null);
  }

  /// Makes pictures ahead of time, without getting in the way of ones on screen.
  void _prefetchCrops(Iterable<int> faceIds) {
    for (final id in faceIds) {
      if (_crops.containsKey(id) || _cropWaiters.containsKey(id)) continue;
      _cropWaiters[id] = Completer<Uint8List?>();
      _cropLow.add(id);
    }
    _pumpCrops();
  }

  void _pumpCrops() {
    while (_cropRunning.length < _maxCropsInFlight) {
      final int id;
      if (_cropStack.isNotEmpty) {
        id = _cropStack.removeLast();
      } else if (_cropLow.isNotEmpty) {
        id = _cropLow.removeAt(0);
      } else {
        return;
      }
      final waiter = _cropWaiters[id];
      final ready = _crops[id];
      if (ready != null) {
        _cropWaiters.remove(id);
        waiter?.complete(ready);
        continue;
      }

      _cropRunning.add(id);
      _native.faceCrop(id).then<Uint8List?>((b) => b).catchError((_) => null).then((bytes) {
        _cropRunning.remove(id);
        if (bytes != null) {
          _crops[id] = bytes;
          if (_crops.length > _cropCacheLimit) _crops.remove(_crops.keys.first);
        }
        _cropWaiters.remove(id)?.complete(bytes);
        _pumpCrops();
      });
    }
  }

  // ---- one person ----

  Person? active;
  List<Map<String, dynamic>> photos = [];
  final Map<String, Uint8List> photoThumbs = {};
  bool isLoadingPhotos = false;
  bool isLoadingThumbs = false;
  int _openToken = 0;

  // Recently shown photo thumbnails, so re-opening someone is instant.
  final Map<String, Uint8List> _thumbCache = {};

  Future<void> openPerson(Person person) async {
    final token = ++_openToken;
    active = person;
    photos = [];
    photoThumbs.clear();
    isLoadingPhotos = true;
    isLoadingThumbs = false;
    update();

    try {
      final found = await _native.personPhotos(person.id);
      if (token != _openToken) return;
      photos = found;
    } catch (e) {
      debugPrint('personPhotos failed: $e');
    }
    isLoadingPhotos = false;
    isLoadingThumbs = photos.isNotEmpty;
    update();

    // Same approach as a collection: cached ones at once, the rest a few at a
    // time in list order, so the top of the grid fills first.
    final pending = <Map<String, dynamic>>[];
    for (final item in photos) {
      final key = item['path'] as String;
      final cached = _thumbCache.remove(key);
      if (cached != null) {
        _thumbCache[key] = cached;
        photoThumbs[key] = cached;
      } else {
        pending.add(item);
      }
    }
    if (photoThumbs.isNotEmpty) update();

    var next = 0;
    var sinceUpdate = 0;
    Future<void> worker() async {
      while (token == _openToken && next < pending.length) {
        final key = pending[next++]['path'] as String;
        try {
          final bytes = await _native.loadThumbnail(uri: key, isVideo: false, size: 420);
          _thumbCache.remove(key);
          _thumbCache[key] = bytes;
          if (_thumbCache.length > 500) _thumbCache.remove(_thumbCache.keys.first);
          if (token != _openToken) return;
          photoThumbs[key] = bytes;
        } catch (_) {}
        if (token == _openToken && ++sinceUpdate >= 6) {
          sinceUpdate = 0;
          update();
        }
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
    if (token == _openToken) {
      isLoadingThumbs = false;
      update();
    }
  }

  void closePerson() {
    _openToken++;
    active = null;
    photos = [];
    photoThumbs.clear();
    isLoadingPhotos = false;
    isLoadingThumbs = false;
  }

  /// Reloads the open person (name, counts, photos) after an edit.
  Future<void> _reloadActive() async {
    final current = active;
    if (current == null) return;
    final fresh = await _native.personSummary(current.id);
    if (fresh == null) {
      // Gone (merged away, or no faces left).
      closePerson();
      update();
      return;
    }
    await openPerson(fresh);
  }

  // ---- edits ----

  Future<void> rename(Person person, String? name) async {
    await _native.renamePerson(person.id, name);
    await refreshPeople();
    if (active?.id == person.id) {
      final fresh = await _native.personSummary(person.id);
      if (fresh != null) {
        active = fresh;
        update();
      }
    }
  }

  Future<void> setHidden(Person person, bool hidden) async {
    await _native.hidePerson(person.id, hidden);
    if (hidden && active?.id == person.id) closePerson();
    await refreshPeople();
  }

  /// Joins [other] into [keep] (the one with the name, or the bigger one, is kept).
  Future<void> merge({required Person keep, required Person other}) async {
    await _native.mergePeople(keepId: keep.id, otherId: other.id);
    await refreshPeople();
    if (active?.id == other.id) {
      final fresh = await _native.personSummary(keep.id);
      if (fresh != null) await openPerson(fresh);
    } else if (active?.id == keep.id) {
      await _reloadActive();
    }
    await refreshSuggestions();
  }

  /// "These two are different people": the suggestion goes away for good.
  Future<void> rejectSuggestion(Person a, Person b) async {
    _suggestions = _suggestions
        .where((s) => !((s.aId == a.id && s.bId == b.id) || (s.aId == b.id && s.bId == a.id)))
        .toList();
    update();
    await _native.rejectMerge(a.id, b.id);
  }

  /// "Not this person" for one face.
  Future<void> removeFace(PersonFace face) async {
    await _native.removeFace(face.faceId);
    await refreshPeople();
    await _reloadActive();
  }

  Future<List<PersonFace>> facesOf(Person person) => _native.personFaces(person.id);

  // ---- options ----

  Future<void> setThorough(bool value) async {
    await _native.setFaceSettings(thorough: value);
    await refreshStatus();
  }

  Future<void> setRefine(bool value) async {
    await _native.setFaceSettings(refine: value);
    await refreshStatus();
  }

  /// Runs the one-off speed test for this phone again.
  Future<void> retune() async {
    await _native.retuneFaces();
    await refreshStatus();
  }

  Future<void> setStrictness(String value) async {
    await _native.setFaceSettings(strictness: value);
    await refreshStatus();
  }

  /// Rebuilds the automatic groups (names and edits are kept).
  Future<void> regroup() async {
    isLoadingPeople = true;
    update();
    try {
      await _native.regroupFaces();
    } finally {
      await refreshAll();
    }
  }

  /// Forgets everything (names included) and searches all photos again.
  Future<void> rescanEverything() async {
    await _native.resetFaces();
    _crops.clear();
    _cropLow.clear();
    people = [];
    hiddenPeople = [];
    update();
    await startScan();
    await refreshStatus();
  }

  Future<FaceModels> models() => _native.faceModels();

  /// Switching the recognition model regroups everything from scratch.
  Future<void> selectModel(FaceModelInfo model) async {
    await _native.selectFaceModel(kind: model.kind, id: model.id);
    _crops.clear();
    await startScan();
    await refreshStatus();
  }
}
