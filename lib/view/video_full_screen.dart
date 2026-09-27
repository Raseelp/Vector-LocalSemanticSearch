import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:twentyonevision/controllers/native_controller.dart';
import 'package:twentyonevision/models/meta_data_model.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/utils/app_radius.dart';
import 'package:twentyonevision/utils/app_spacing.dart';
import 'package:twentyonevision/view/image_full_screen.dart';
import 'package:twentyonevision/view/person_screen.dart';
import 'package:twentyonevision/view/widget/draggable_metadata_sheet.dart';
import 'package:twentyonevision/view/widget/face_widgets.dart';
import 'package:twentyonevision/view/widget/match_strength_bars.dart';
import 'package:twentyonevision/view/widget/media_actions_sheet.dart';
import 'package:twentyonevision/view/widget/media_chrome_button.dart';
import 'package:twentyonevision/view/widget/media_info_widgets.dart';
import 'package:twentyonevision/view/widget/photo_faces_layer.dart';
import 'package:twentyonevision/view/widget/similar_items_bar.dart';
import 'package:twentyonevision/view/widget/video_people_strip.dart';
import 'package:video_player/video_player.dart';

class VideoViewScreen extends StatefulWidget {
  const VideoViewScreen({
    super.key,
    required this.videoUri,
    required this.timestampMs,
    required this.thumbnailBytes,
  });

  final String videoUri;
  final int timestampMs;

  final Uint8List thumbnailBytes;

  @override
  State<VideoViewScreen> createState() => _VideoViewScreenState();
}

class _VideoViewScreenState extends State<VideoViewScreen> with SingleTickerProviderStateMixin {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _showControls = true;
  bool _pickingFrame = false;

  String? _initError;

  // ---- who is in the paused frame ----
  //
  // While the video plays nothing is drawn. Pause it (or scrub and let go) and, once it has
  // been still a moment, the frame on screen is looked at: every face that matches a known
  // person gets the same tappable outline as in a photo. Nothing is stored by this.
  final int _token = DateTime.now().microsecondsSinceEpoch;
  int _request = 0;
  int? _pendingToken;
  List<PhotoFace> _faces = const [];
  PhotoFace? _selectedFace;
  bool _looking = false;
  String _scanMessage = 'Looking for faces';
  Timer? _stillTimer;
  Timer? _slowTimer;
  Timer? _poll;
  int _watchedPos = -1;
  bool _wasPlaying = true;
  final TransformationController _still = TransformationController();

  // A person picked in the strip: once their moment is on screen, their head is highlighted.
  int? _autoSelect;

  // The moment the outlines were drawn at straight from what the scan stored (no new look), and
  // a counter that only changes when the outlines are for a new moment (so adding people to the
  // same moment doesn't restart the outline animations).
  int? _instantMs;
  int _layerKey = 0;

  // The transition from the strip to the head: while the video jumps to the moment, the
  // person's face flies from the strip to where their head is, and the outline draws when it
  // lands - by then the new picture is on screen, so the outline never appears on an old frame.
  late final AnimationController _flightCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  FaceFlight? _flight;
  RingEntry? _ringEntry; // the look shared by the flight and the outline that takes over
  int _jumpId = 0;
  final GlobalKey _videoBox = GlobalKey();

  // ---- the people found in this video ----
  List<VideoPerson> _people = const [];
  int? _focusPerson;
  bool _peopleOpen = false; // the panel opened from the People button

  // ---- "Similar to this": the strip opened once a frame has been picked ----
  bool _similarOpen = false;
  int? _similarFrameMs; // the frame the strip (and "search with this" below it) is for

  // ---- scanning the whole video (when the user asks) while it plays ----
  // 'needs' (not scanned yet), 'done', 'unavailable' (not indexed / models not ready), or
  // null while it is being looked up.
  String? _scanState;
  // How loose the next scan is (0 standard, 1 looser, 2 loosest) and what the last one kept.
  int _scanLevel = 0;
  int? _lastFaces;
  final int _scanToken = DateTime.now().microsecondsSinceEpoch + 7;
  bool _scanningVideo = false;
  String _videoMessage = 'Opening the video';
  Timer? _videoPoll;

  @override
  void initState() {
    super.initState();
    _loadPeople();
    _loadScanState();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _controller = VideoPlayerController.contentUri(Uri.parse(widget.videoUri));

    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;

          _controller.seekTo(Duration(milliseconds: widget.timestampMs));
          _controller.play();

          setState(() {
            _initialized = true;
          });
        })
        .catchError((Object e) {
          if (!mounted) return;
          setState(() {
            _initError = "Couldn't play this video.";
          });
        });

    _controller.addListener(() {
      if (!mounted) return;
      _onPlayback();
      setState(() {});
    });
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _flightCtrl.dispose();
    _toastTimer?.cancel();
    _stillTimer?.cancel();
    _slowTimer?.cancel();
    _poll?.cancel();
    _videoPoll?.cancel();
    NativeServices().cancelPhotoFaces(_scanToken).catchError((_) {});
    _cancelPending();
    _still.dispose();
    _controller.dispose();
    // Coming back to the results, the search box was getting its focus (and keyboard) back.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Get.isRegistered<NativeController>()) Get.find<NativeController>().searchFocusNode.unfocus();
    });
    super.dispose();
  }

  Future<void> _loadScanState() async {
    try {
      final info = await NativeServices().videoScanState(widget.videoUri);
      if (mounted) {
        setState(() {
          _scanState = info.state;
          _scanLevel = info.level;
          _lastFaces = info.lastFaces;
        });
      }
      // Being scanned right now (by the background scan, or a visit to this video before): show
      // the same glow and progress, and pick the people up when it finishes.
      final running = await NativeServices().photoScanStatus('video:${widget.videoUri}');
      if (running != null && mounted && !_scanningVideo) _watchRunningScan();
    } catch (_) {
      if (mounted) setState(() => _scanState = 'unavailable');
    }
  }

  // A short message over the video: a title, a line of what to do next and - after a scan - the
  // faces that were found. (Not the system snackbar.)
  _ToastData? _toast;
  Timer? _toastTimer;

  void _say(String title, {String? subtitle, List<int> faces = const [], int seconds = 4}) {
    _toastTimer?.cancel();
    setState(() => _toast = _ToastData(title, subtitle, faces));
    _toastTimer = Timer(Duration(seconds: seconds), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  // Bumped to make the People button draw the eye (see PeopleChipButton).
  int _peoplePulse = 0;
  bool _peopleLoadedOnce = false;

  // The button on top: find the people in this video. The video keeps playing and every
  // control keeps working meanwhile; a quiet glow and live progress say what is happening.
  // Tapping it again scans again (and replaces what the first scan found).
  void _onScanButton() {
    if (_scanningVideo) {
      _say('Still scanning', subtitle: 'The people show up on the People button when it is done.');
      return;
    }
    // Scanned or not, tapping scans (again): a second look replaces the first.
    if (_scanState == 'needs' || _scanState == 'done') {
      _explainLevel();
      _startScan();
    } else {
      _say("Can't scan this video yet", subtitle: "The face models or the search index aren't ready.");
    }
  }

  // Tells what this scan will do differently: after a look that found nothing, each tap is a
  // little less strict - and this video remembers the level it needed.
  void _explainLevel() {
    if (_scanLevel <= 0) return;
    if (_lastFaces == 0) {
      _say(
        _scanLevel >= 2 ? 'Searching as loosely as possible' : 'Searching less strictly',
        subtitle: 'Nothing was found last time, so smaller and blurrier faces count now, and more frames are checked.',
      );
    } else {
      _say('Using a looser search', subtitle: 'The setting this video needed.');
    }
  }

  void _watchRunningScan() {
    setState(() {
      _scanningVideo = true;
      _videoMessage = 'Scanning the video';
    });
    _videoPoll?.cancel();
    _videoPoll = Timer.periodic(const Duration(milliseconds: 300), (timer) async {
      try {
        final status = await NativeServices().photoScanStatus('video:${widget.videoUri}');
        if (!mounted) {
          timer.cancel();
          return;
        }
        if (status == null) {
          timer.cancel();
          setState(() => _scanningVideo = false);
          await _loadScanState();
          await _loadPeople();
          if (mounted && _people.isNotEmpty) {
            final n = _people.length;
            setState(() {
              _showControls = true;
              _peoplePulse++;
            });
            _say(
              n == 1 ? 'Found 1 person' : 'Found $n people',
              subtitle: 'Tap the People button to see who.',
              faces: _people.take(3).map((p) => p.person.coverFaceId).toList(),
              seconds: 5,
            );
          }
        } else if (status.message != _videoMessage) {
          setState(() => _videoMessage = status.message);
        }
      } catch (_) {}
    });
  }

  Future<void> _startScan() async {
    if (_scanningVideo) return;
    setState(() {
      _scanningVideo = true;
      _videoMessage = 'Opening the video';
    });
    _videoPoll?.cancel();
    _videoPoll = Timer.periodic(const Duration(milliseconds: 300), (_) async {
      try {
        final status = await NativeServices().photoScanStatus('video:${widget.videoUri}');
        if (mounted && _scanningVideo && status != null && status.message != _videoMessage) {
          setState(() => _videoMessage = status.message);
        }
      } catch (_) {}
    });

    var result = VideoScanResult(false, 0, 0);
    try {
      result = await NativeServices().scanVideoFaces(widget.videoUri, token: _scanToken);
    } catch (_) {
      // The video plays fine without it.
    }
    _videoPoll?.cancel();
    if (!mounted) return;
    setState(() => _scanningVideo = false);
    await _loadScanState();
    if (!mounted) return;
    if (result.scanned) {
      // Its people are ready now: show them.
      await _loadPeople();
      if (!mounted) return;
      if (result.faces == 0) {
        _say(
          result.level >= 2 ? 'No clear faces found' : 'Nothing found yet',
          subtitle: result.level >= 2
              ? 'Even the loosest search found none - this video may not have any.'
              : 'Tap the scan button again to search less strictly.',
        );
      } else if (_people.isEmpty) {
        _say('Faces found, but no one listed', subtitle: 'No one showed up often enough. Tap the scan button to look again.');
      } else {
        // The number of people the People button shows - not the count of faces kept (one person has several).
        final n = _people.length;
        // The button is in the controls: make sure they are showing, and point at it.
        setState(() {
          _showControls = true;
          _peoplePulse++;
        });
        _say(
          n == 1 ? 'Found 1 person' : 'Found $n people',
          subtitle: 'Tap the People button to see who.',
          faces: _people.take(3).map((p) => p.person.coverFaceId).toList(),
          seconds: 5,
        );
      }
    } else if (_scanState == 'needs') {
      _say("Couldn't read this video", subtitle: 'Try again in a moment.');
    }
  }

  Future<void> _loadPeople() async {
    try {
      final found = await NativeServices().videoPeople(widget.videoUri);
      if (!mounted) return;
      final grew = _peopleLoadedOnce && found.length > _people.length;
      _peopleLoadedOnce = true;
      setState(() {
        if (grew) _peoplePulse++;
        _people = found;
        if (_focusPerson != null && !found.any((p) => p.person.id == _focusPerson)) _focusPerson = null;
      });
    } catch (_) {
      // No strip - the video plays as ever.
    }
  }

  // Playback changed: leaving the paused state clears what was found; pausing (or moving
  // while paused) starts waiting for stillness.
  void _onPlayback() {
    if (!_initialized || _pickingFrame) return;
    final v = _controller.value;
    if (v.isPlaying) {
      if (!_wasPlaying || _faces.isNotEmpty || _looking || _stillTimer != null) _leaveStill();
      _wasPlaying = true;
      return;
    }
    final pos = v.position.inMilliseconds;
    // Sitting on the moment whose outlines came straight from the scan: leave them be.
    final instant = _instantMs;
    if (instant != null) {
      if ((pos - instant).abs() < 600) {
        _watchedPos = pos;
        _wasPlaying = false;
        return;
      }
      _instantMs = null;
    }
    if (_jumpBusy) {
      // A jump from the panel is doing its own look; don't start another.
      _watchedPos = pos;
      _wasPlaying = false;
      return;
    }
    final moved = (pos - _watchedPos).abs() > 200;
    _watchedPos = pos;
    if (_wasPlaying || moved) {
      _wasPlaying = false;
      _stillTimer?.cancel();
      // A look at the moment we just left may still be on its way: its answer would be drawn on
      // this one. Drop it.
      _request++;
      _slowTimer?.cancel();
      _poll?.cancel();
      _cancelPending();
      _looking = false;
      // Faces from another moment don't belong on this one.
      _faces = const [];
      _selectedFace = null;
      _stillTimer = Timer(const Duration(milliseconds: 450), () => _lookAt(_controller.value.position.inMilliseconds));
    }
  }

  void _leaveStill() {
    _jumpBusy = false;
    _ringEntry = null;
    _instantMs = null;
    _jumpId++;
    _flight = null;
    _stillTimer?.cancel();
    _stillTimer = null;
    _slowTimer?.cancel();
    _poll?.cancel();
    _request++;
    _cancelPending();
    _faces = const [];
    _selectedFace = null;
    _looking = false;
  }

  void _cancelPending() {
    final token = _pendingToken;
    _pendingToken = null;
    if (token != null) NativeServices().cancelPhotoFaces(token).catchError((_) {});
  }

  // [merge]: a quiet second look at a moment whose outlines are already up (from the scan): it
  // only adds people the scan hadn't stored, without a glow or restarting anything.
  Future<void> _lookAt(int pos, {bool merge = false}) async {
    _stillTimer = null;
    if (!mounted || _controller.value.isPlaying || _pickingFrame) return;
    _cancelPending();
    final id = ++_request;
    final token = _token + id;
    _pendingToken = token;

    // Quick answers need no fanfare; a slower one gets the quiet glow and progress text.
    _slowTimer?.cancel();
    _poll?.cancel();
    if (!merge) {
      _slowTimer = Timer(const Duration(milliseconds: 450), () {
        if (!mounted || id != _request) return;
        setState(() {
          _looking = true;
          _scanMessage = 'Looking for faces';
        });
        _poll?.cancel();
        _poll = Timer.periodic(const Duration(milliseconds: 250), (_) async {
          try {
            final status = await NativeServices().photoScanStatus('${widget.videoUri}#$pos');
            if (mounted && id == _request && _looking && status != null && status.message != _scanMessage) {
              setState(() => _scanMessage = status.message);
            }
          } catch (_) {}
        });
      });
    }

    var found = const <PhotoFace>[];
    try {
      found = await NativeServices().videoFaces(widget.videoUri, pos, token: token);
    } catch (_) {
      // Nothing to tap - the video is still fully usable.
    }
    _slowTimer?.cancel();
    _poll?.cancel();
    if (!mounted || id != _request) return;
    _pendingToken = null;

    if (merge) {
      final have = _faces.map((f) => f.person.id).toSet();
      final extras = found.where((f) => !have.contains(f.person.id)).toList();
      if (extras.isNotEmpty) setState(() => _faces = [..._faces, ...extras]);
      _loadPeople(); // whoever was named there joins the video's list of people
      return;
    }

    // Arrived here from the strip: point at that person's head.
    final want = _autoSelect;
    _autoSelect = null;
    setState(() {
      _ringEntry = null;
      _faces = found;
      _layerKey++;
      _selectedFace = want == null ? null : found.where((f) => f.person.id == want).firstOrNull;
      _looking = false;
    });
    // Whoever was named in this frame joins the video's list of people (the scan may have missed them).
    _loadPeople();
  }

  Future<void> _openPerson(Person person) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonScreen(person: person)));
    // They may have been renamed, merged or hidden there.
    if (mounted) _loadPeople();
  }

  bool _jumpBusy = false; // a jump from the panel is under way (the ordinary look at a paused frame waits)

  // A face in the panel: jump to where they appear (and on again to their next moment) and point at
  // them. Where the scan stored their position it is used at once; where it didn't (an older scan,
  // or a moment only noted) the frame itself is looked at - so it always ends with them pointed out,
  // or says why it couldn't.
  Future<void> _jumpToPerson(VideoPerson p, Rect fromOnScreen) async {
    // Prefer the moments that have a stored position to point at.
    final moments = p.storedTimes.isNotEmpty ? p.storedTimes : p.times;
    if (moments.isEmpty) return;
    final pos = _controller.value.position.inMilliseconds;
    final int target;
    if (_focusPerson == p.person.id) {
      target = moments.firstWhere((t) => t > pos + 800, orElse: () => moments.first);
    } else {
      target = moments.first;
    }
    if (_peopleOpen) setState(() => _peopleOpen = false);

    // Already paused right there with the faces found: just point at them.
    if (!_controller.value.isPlaying && _faces.isNotEmpty && (target - pos).abs() < 250) {
      final here = _faces.where((f) => f.person.id == p.person.id).firstOrNull;
      if (here != null) {
        _autoSelect = null;
        setState(() {
          _focusPerson = p.person.id;
          _selectedFace = here;
        });
        return;
      }
    }

    setState(() {
      _focusPerson = p.person.id;
      _selectedFace = null;
    });
    final jump = ++_jumpId;
    _jumpBusy = true;
    _autoSelect = null;
    // Whatever was being looked for at another moment is off.
    _stillTimer?.cancel();
    _stillTimer = null;
    _slowTimer?.cancel();
    _poll?.cancel();
    _request++;
    _cancelPending();
    _controller.pause();
    final seeking = _controller.seekTo(Duration(milliseconds: target));

    try {
      // 1. Who is where at that moment: from the scan if it stored their position...
      var faces = const <PhotoFace>[];
      PhotoFace? want;
      var fromScan = false;
      try {
        final stored = await NativeServices().videoFrameFaces(widget.videoUri, target);
        final mine = stored.faces.where((f) => f.person.id == p.person.id).firstOrNull;
        if (stored.exact && mine != null) {
          faces = stored.faces;
          want = mine;
          fromScan = true;
        }
      } catch (_) {}
      if (!mounted || jump != _jumpId) return;

      // ...or by looking at the frame itself once it is on screen.
      if (!fromScan) {
        await seeking;
        await _waitForFrame(target, jump);
        if (!mounted || jump != _jumpId) return;
        setState(() {
          _looking = true;
          _scanMessage = 'Looking for faces';
        });
        try {
          faces = await NativeServices().videoFaces(widget.videoUri, target, token: _token + jump + 1000000);
        } catch (_) {}
        if (!mounted || jump != _jumpId) return;
        setState(() => _looking = false);
        want = faces.where((f) => f.person.id == p.person.id).firstOrNull;
        // That look was stored (see the native side): next time this moment has a position to use.
        _loadPeople();
      }

      if (want == null) {
        // Not found in the picture: show whoever was, and say so instead of doing nothing.
        setState(() {
          _faces = faces;
          _layerKey++;
          _ringEntry = null;
          _selectedFace = null;
        });
        _say(
          "Couldn't point out ${p.person.name ?? 'them'} here",
          subtitle: "Their face isn't clear at this moment. Tap them again to go to another.",
        );
        return;
      }

      // 2. Their face flies to the head and becomes the outline.
      Future<void>? flying;
      final box = _videoBox.currentContext?.findRenderObject() as RenderBox?;
      final spot = (box != null && box.hasSize) ? headSpotFor(want, box.size) : null;
      if (box != null && spot != null) {
        final to = box.localToGlobal(spot.center);
        final entry = RingEntry.random();
        setState(() {
          _ringEntry = entry;
          _flight = FaceFlight(
            faceId: p.person.coverFaceId,
            from: fromOnScreen.center,
            to: to,
            endRadius: spot.radius,
            entry: entry,
          );
        });
        // It travels to just short of landing, then hovers until the new picture is really on
        // screen (however long the video takes to get there) before the hand-over.
        _flightCtrl.value = 0;
        flying = _flightCtrl
            .animateTo(FaceFlightOverlay.landingAt, duration: const Duration(milliseconds: 620), curve: Curves.linear)
            .orCancel
            .then((_) {}, onError: (_) {});
      } else {
        _ringEntry = null;
      }

      await seeking;
      if (flying != null) await flying;
      if (fromScan) await _waitForFrame(target, jump);
      if (!mounted || jump != _jumpId) return;
      if (_controller.value.isPlaying) {
        if (_flight != null) setState(() => _flight = null);
        return;
      }

      // 3. The outline takes over.
      _request++;
      _cancelPending();
      setState(() {
        _looking = false;
        _faces = faces;
        _layerKey++;
        _instantMs = target;
        _selectedFace = want;
      });
      // A quiet look afterwards for anyone else in the picture that wasn't stored.
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted && _instantMs == target && !_controller.value.isPlaying) _lookAt(target, merge: true);
      });
      // The outline is drawing in now; the circle-turned-band melts into it.
      if (_flight != null) {
        await _flightCtrl
            .animateTo(1.0, duration: const Duration(milliseconds: 160), curve: Curves.easeOut)
            .orCancel
            .then((_) {}, onError: (_) {});
        if (mounted && jump == _jumpId) setState(() => _flight = null);
      }
    } catch (_) {
      // Whatever went wrong, the video is where it was asked to be and the ordinary look still works.
    } finally {
      if (jump == _jumpId) _jumpBusy = false;
    }
  }

  // Until the picture at the new moment has really reached the screen: the position says so a
  // little before the frame does, so this waits for both.
  Future<void> _waitForFrame(int target, int jump) async {
    for (var i = 0; i < 30; i++) {
      if (!mounted || jump != _jumpId) return;
      final v = _controller.value;
      if ((v.position.inMilliseconds - target).abs() < 200 && !v.isBuffering) break;
      await Future.delayed(const Duration(milliseconds: 40));
    }
    await Future.delayed(const Duration(milliseconds: 140));
  }

  void _toggleControls() {
    // Hiding the scrubber mid-pick would strand the user with a hint about
    // something they can no longer see.
    if (_pickingFrame) return;
    setState(() {
      _showControls = !_showControls;
      _peopleOpen = false;
    });
  }

  // "Search with this" for video: unlike a photo there's no single image to
  // use, so this pauses and turns the playback bar into a proper scrubber -
  // the user picks whichever moment they want, then confirms. See
  // _showSimilarForFrame.
  void _enterFramePicking(NativeController nativeController) {
    nativeController.hideMetadata();
    _controller.pause();
    setState(() {
      _pickingFrame = true;
      _showControls = true;
      _peopleOpen = false;
      if (_similarOpen) {
        _similarOpen = false;
        nativeController.clearSimilar();
      }
    });
  }

  void _cancelFramePicking() {
    setState(() => _pickingFrame = false);
  }

  // The frame is picked: rather than jumping straight to a full results screen, show the
  // "similar to this" strip for it - _confirmFrameSearch (the strip's own "search with this"
  // button) is still there for whoever wants the full results.
  void _showSimilarForFrame(NativeController nativeController) {
    final positionMs = _controller.value.position.inMilliseconds;
    setState(() {
      _pickingFrame = false;
      _similarOpen = true;
      _similarFrameMs = positionMs;
    });
    nativeController.loadSimilar(uri: widget.videoUri, timestampMs: positionMs);
  }

  void _closeSimilar(NativeController nativeController) {
    setState(() => _similarOpen = false);
    nativeController.clearSimilar();
  }

  void _confirmFrameSearch(NativeController nativeController) {
    final positionMs = _similarFrameMs ?? _controller.value.position.inMilliseconds;
    // All the way back to the home screen (this may have been opened from
    // inside a collection, not straight from the results), on the Search
    // tab, then search - not awaited, the results grid shows its own
    // loading state.
    Navigator.of(context).popUntil((route) => route.isFirst);
    nativeController.searchWithVideoFrame(uri: widget.videoUri, timestampMs: positionMs);
  }

  // How long the strip takes to fade away, here and in build()'s AnimatedSwitcher - shared so
  // the two always agree, since _openSimilarItem below times the navigation off this same value.
  static const _similarCloseDuration = Duration(milliseconds: 200);

  // A tile in the "similar to this" strip: SimilarItemsBar only wires a tile's tap up once its
  // thumbnail has actually arrived, but bytes stays nullable here to match its callback type.
  void _openSimilarItem(Map<String, dynamic> item, Uint8List? bytes) {
    if (bytes == null) return;
    final itemUri = item['path'] as String;
    final isVideo = item['isVideo'] as bool? ?? false;
    final timestampMs = (item['timestampMs'] as num?)?.toInt() ?? 0;

    void push() {
      if (isVideo) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => VideoViewScreen(videoUri: itemUri, timestampMs: timestampMs, thumbnailBytes: bytes),
          ),
        );
      } else {
        // Plain Navigator, not Get.to: Get.to's default preventDuplicates treats pushing the
        // same widget type as "already here" and quietly does nothing, which would only ever
        // bite for VideoViewScreen -> VideoViewScreen - not this branch - but Navigator.push
        // has no such trap either way, so it's the one to use consistently here too.
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ImageViewScreen(imageBytes: bytes, uri: itemUri, loadFullRes: true),
          ),
        );
      }
    }

    if (_similarOpen) {
      // Closed first, not left open behind the new screen - see the same note in
      // image_full_screen.dart's _openSimilarItem for why that matters (the shared cache on
      // the controller can end up holding another screen's results by the time this one's
      // visible again).
      setState(() => _similarOpen = false);
      Future.delayed(_similarCloseDuration, () {
        if (mounted) push();
      });
    } else {
      push();
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final ready = _initialized && _initError == null;

    // Only wraps the chrome in a reactive builder - the player itself
    // (_controller, _initialized, _showControls) still lives entirely in
    // this State's own setState calls, untouched, just like before.
    return GetBuilder<NativeController>(
      builder: (nativeController) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: kMediaOverlayStyle,
        child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onTap: () {
                if (_peopleOpen) {
                  setState(() => _peopleOpen = false);
                } else if (_similarOpen) {
                  _closeSimilar(nativeController);
                } else if (_selectedFace != null) {
                  setState(() => _selectedFace = null);
                } else {
                  _toggleControls();
                }
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: ready
                        ? AspectRatio(
                            key: _videoBox,
                            aspectRatio: _controller.value.aspectRatio,
                            child: VideoPlayer(_controller),
                          )
                        : Image.memory(widget.thumbnailBytes, fit: BoxFit.contain),
                  ),

                  if (!_initialized && _initError == null)
                    const Center(child: CircularProgressIndicator(color: Colors.white)),

                  if (_initError != null)
                    Center(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(AppRadius.xl),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              color: Colors.white70,
                              size: 36,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              _initError!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // The paused frame's people, over exactly the picture. Beneath the controls, so a head that
                  // lies under the seek bar or a button never takes a tap meant for it; everywhere else a
                  // tap on a head is theirs, and any other tap falls through to the video.
                  if (ready && _faces.isNotEmpty && !_controller.value.isPlaying && !_pickingFrame)
                    Positioned.fill(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: _controller.value.aspectRatio,
                          child: PhotoFacesLayer(
                            key: ValueKey(_layerKey),
                            entry: _ringEntry,
                            faces: _faces,
                            transform: _still,
                            selected: _selectedFace,
                            onSelect: (face) => setState(() => _selectedFace = face),
                            onOpen: _openPerson,
                            bottomInset: 96,
                          ),
                        ),
                      ),
                    ),

                  if (_showControls)
                    AnimatedOpacity(
                      opacity: _showControls ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // The top scrim: only a picture, never in the way of a tap.
                          if (ready)
                            IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.black.withValues(alpha: 0.36),
                                      Colors.transparent,
                                      Colors.transparent,
                                    ],
                                    stops: const [0, 0.16, 1],
                                  ),
                                ),
                              ),
                            ),
                          Column(
                          children: [
                            SafeArea(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.sm,
                                  vertical: AppSpacing.xs,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    MediaChromeButton(
                                      icon: Icons.close,
                                      tooltip: 'Close',
                                      onTap: () => Navigator.of(context).pop(),
                                    ),
                                    Row(
                                      children: [
                                        // Find the people in this whole video (videos only).
                                        if (_scanState != null && _scanState != 'unavailable') ...[
                                          MediaChromeButton(
                                            icon: Icons.face_retouching_natural,
                                            tooltip: _scanState == 'done'
                                                ? (_lastFaces == 0 ? 'Scan again, less strictly' : 'Scan this video again')
                                                : 'Find people in this video',
                                            active: _scanningVideo || _scanState == 'done',
                                            onTap: _onScanButton,
                                          ),
                                          const SizedBox(width: AppSpacing.sm),
                                        ],
                                        MediaChromeButton(
                                          icon: (_pickingFrame || _similarOpen)
                                              ? Icons.image_search
                                              : Icons.image_search_rounded,
                                          tooltip: _pickingFrame
                                              ? 'Cancel frame search'
                                              : (_similarOpen ? 'Hide similar' : 'Search with a frame from this video'),
                                          active: _similarOpen,
                                          onTap: () {
                                            if (_pickingFrame) {
                                              _cancelFramePicking();
                                            } else if (_similarOpen) {
                                              _closeSimilar(nativeController);
                                            } else {
                                              _enterFramePicking(nativeController);
                                            }
                                          },
                                        ),
                                        const SizedBox(width: AppSpacing.sm),
                                        MediaChromeButton(
                                          icon: Icons.ios_share_rounded,
                                          tooltip: 'Share and save',
                                          onTap: () => showMediaActionsSheet(
                                            context,
                                            uri: widget.videoUri,
                                            isVideo: true,
                                            controller: nativeController,
                                          ),
                                        ),
                                        const SizedBox(width: AppSpacing.sm),
                                        MediaChromeButton(
                                          icon: nativeController.showMetadata
                                              ? Icons.info
                                              : Icons.info_outline,
                                          tooltip: 'Details',
                                          onTap: nativeController.toggleMetadata,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            if (_pickingFrame) const _FramePickHint(),

                            const Spacer(),

                            if (ready && _pickingFrame)
                              _FramePickBar(
                                controller: _controller,
                                formatDuration: _formatDuration,
                                onCancel: _cancelFramePicking,
                                onSearch: () => _showSimilarForFrame(nativeController),
                              ),

                            if (ready && !_pickingFrame)
                              _VideoControlsBar(
                                controller: _controller,
                                formatDuration: _formatDuration,
                                markers: _people.where((p) => p.person.id == _focusPerson).firstOrNull?.times ?? const [],
                                peopleCount: _people.length,
                                peopleOpen: _peopleOpen,
                                peoplePulse: _peoplePulse,
                                onPlayPause: () {
                                  _autoSelect = null;
                                  _controller.value.isPlaying ? _controller.pause() : _controller.play();
                                },
                                onPeople: () => setState(() {
                                  _peopleOpen = !_peopleOpen;
                                  if (_peopleOpen && _similarOpen) {
                                    _similarOpen = false;
                                    nativeController.clearSimilar();
                                  }
                                }),
                              ),
                          ],
                        ),
                        ],
                      ),
                    ),

                  // The quiet "looking" glow and what it is doing.
                  if (ready)
                    Positioned.fill(
                      child: PhotoScanGlow(
                        visible: _scanningVideo || _looking,
                        // The whole-video scan is the bigger thing: it speaks first.
                        message: _scanningVideo ? _videoMessage : _scanMessage,
                        bottomInset: 96,
                      ),
                    ),

                  // The people in this video (from the button): above the picture's outlines, so its taps
                  // are never taken by a head underneath.
                  if (ready && _people.isNotEmpty && _peopleOpen && _showControls)
                    Positioned(
                      left: AppSpacing.base,
                      right: AppSpacing.base,
                      bottom: MediaQuery.of(context).padding.bottom + 112,
                      child: VideoPeoplePanel(people: _people, focusedId: _focusPerson, onTap: _jumpToPerson),
                    ),

                  // "Similar to this frame": shown once a frame has been picked, above the
                  // controls bar the same way the people panel is. AnimatedSwitcher rather than
                  // gating the whole Positioned on _similarOpen: closing (by hand, or
                  // automatically before _openSimilarItem navigates away) fades it out instead
                  // of cutting it off dead.
                  if (ready && _showControls)
                    Positioned(
                      left: AppSpacing.base,
                      right: AppSpacing.base,
                      bottom: MediaQuery.of(context).padding.bottom + 112,
                      child: AnimatedSwitcher(
                        duration: _similarCloseDuration,
                        child: _similarOpen
                            ? SimilarItemsBar(
                                key: const ValueKey('similar-open'),
                                items: nativeController.similarResults,
                                bytesFor: (item) => nativeController.similarThumbCache[nativeController.cacheKeyForResult(item)],
                                loading: nativeController.isLoadingSimilar,
                                label: 'Similar to this frame',
                                onTapItem: (item, bytes) => _openSimilarItem(item, bytes),
                                onSearchFull: () => _confirmFrameSearch(nativeController),
                              )
                            : const SizedBox.shrink(key: ValueKey('similar-closed')),
                      ),
                    ),

                  // Their face, flying from the panel to their head while the video jumps there.
                  if (_flight != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedBuilder(
                          animation: _flightCtrl,
                          builder: (context, _) => FaceFlightOverlay(flight: _flight!, t: _flightCtrl.value),
                        ),
                      ),
                    ),

                  // Messages: above the controls when they are showing, low on the screen when not.
                  Positioned(
                    left: AppSpacing.base,
                    right: AppSpacing.base,
                    bottom: MediaQuery.of(context).padding.bottom + (_showControls ? (_peopleOpen ? 268 : 178) : AppSpacing.xxl),
                    child: IgnorePointer(
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 320),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder: (child, animation) => FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(animation),
                              child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(animation), child: child),
                            ),
                          ),
                          child: _toast == null
                              ? const SizedBox.shrink(key: ValueKey('no-toast'))
                              : _ToastCard(key: ValueKey(_toast), data: _toast!),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            DraggableMetadataSheet(
              visible: nativeController.showMetadata,
              onDismissed: nativeController.hideMetadata,
              heightFactor: 0.5,
              child: _VideoMetadataContent(
                metadata: nativeController.selectedMetadata,
                isLoading: nativeController.isFetchingMetadata,
                matchExplanation: nativeController.matchExplanation,
                matchedFrameBytes: widget.thumbnailBytes,
                matchedTimestampMs: widget.timestampMs,
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

// Tells the user what the mode they just entered is for - without it, a
// paused video and a slightly different bar wouldn't say anything about
// searching.
class _FramePickHint extends StatelessWidget {
  const _FramePickHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swipe_rounded, color: Colors.white, size: 16),
            SizedBox(width: AppSpacing.sm),
            Text(
              'Drag the bar to any moment, then see what looks similar',
              style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

// The playback bar while picking a frame: a real Slider with a big thumb
// (unlike the thin, thumbless bar normally shown), so it reads as
// draggable at a glance, seeking live so the frame on screen is the frame
// that gets searched.
class _FramePickBar extends StatefulWidget {
  const _FramePickBar({
    required this.controller,
    required this.formatDuration,
    required this.onCancel,
    required this.onSearch,
  });

  final VideoPlayerController controller;
  final String Function(Duration) formatDuration;
  final VoidCallback onCancel;
  final VoidCallback onSearch;

  @override
  State<_FramePickBar> createState() => _FramePickBarState();
}

class _FramePickBarState extends State<_FramePickBar> {
  // Seeking on every drag event floods the player with requests it can't
  // keep up with (the picture lags behind the thumb); this lets one through
  // every ~90ms while dragging and always lands exactly on release.
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  void _seek(double v, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastSeek) < const Duration(milliseconds: 90)) return;
    _lastSeek = now;
    widget.controller.seekTo(Duration(milliseconds: v.round()));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final formatDuration = widget.formatDuration;
    final onCancel = widget.onCancel;
    final onSearch = widget.onSearch;
    final durationMs = controller.value.duration.inMilliseconds;
    final positionMs = controller.value.position.inMilliseconds.clamp(0, durationMs > 0 ? durationMs : 1);

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.base, 0, AppSpacing.base, AppSpacing.xxl),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              activeTrackColor: AppColors.primary,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 11),
              overlayColor: AppColors.primary.withValues(alpha: 0.25),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
            ),
            child: Slider(
              min: 0,
              max: durationMs > 0 ? durationMs.toDouble() : 1,
              value: positionMs.toDouble(),
              onChanged: _seek,
              onChangeEnd: (v) => _seek(v, force: true),
            ),
          ),
          Row(
            children: [
              TextButton(
                onPressed: onCancel,
                child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
              ),
              const Spacer(),
              Text(
                formatDuration(controller.value.position),
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const Spacer(),
              InkWell(
                onTap: onSearch,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.base,
                    vertical: AppSpacing.md,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.image_search_rounded, color: AppColors.onPrimary, size: 18),
                      SizedBox(width: AppSpacing.sm),
                      Text(
                        'Show similar',
                        style: TextStyle(
                          color: AppColors.onPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VideoMetadataContent extends StatelessWidget {
  const _VideoMetadataContent({
    required this.metadata,
    required this.isLoading,
    required this.matchExplanation,
    required this.matchedFrameBytes,
    required this.matchedTimestampMs,
  });

  final ImageMetadata metadata;
  final bool isLoading;
  final List<MapEntry<String, double>> matchExplanation;
  final Uint8List matchedFrameBytes;
  final int matchedTimestampMs;

  String _formatTimestamp(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Absent unless this was actually opened from a text search
          // result - same guard as the image viewer.
          if (matchExplanation.isNotEmpty) ...[
            const InfoGroupLabel('Why this matched'),
            const SizedBox(height: AppSpacing.sm),
            _MatchedFrameRow(
              bytes: matchedFrameBytes,
              label: 'Matched at ${_formatTimestamp(matchedTimestampMs)}',
            ),
            const SizedBox(height: AppSpacing.base),
            MatchStrengthBars(entries: matchExplanation),
            const SizedBox(height: AppSpacing.xl),
          ],
          const InfoGroupLabel('File information'),
          const SizedBox(height: AppSpacing.sm),
          InfoGroupCard(
            children: [
              InfoRow(
                icon: Icons.videocam_outlined,
                label: 'File name',
                value: metadata.fileName.isNotEmpty ? metadata.fileName : 'Unknown',
              ),
              InfoRow(
                icon: Icons.folder_outlined,
                label: 'File path',
                value: metadata.imagePath.isNotEmpty ? metadata.imagePath : 'Unknown',
              ),
              if (metadata.durationMs > 0)
                InfoRow(
                  icon: Icons.timer_outlined,
                  label: 'Duration',
                  value: metadata.durationFormatted,
                ),
              InfoRow(
                icon: Icons.straighten_rounded,
                label: 'Resolution',
                value: metadata.resolution,
              ),
              InfoRow(
                icon: Icons.storage_rounded,
                label: 'File size',
                value: metadata.fileSizeFormatted,
              ),
              InfoRow(
                icon: Icons.type_specimen_outlined,
                label: 'Format',
                value: metadata.mimeType.split('/').last.toUpperCase(),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }
}

// A small preview of the exact frame CLIP matched, not just the words that
// matched it - the same information the search grid's thumbnail already
// used (see search_results.dart), just surfaced here too so "why this
// matched" reads as concretely as the image viewer's does.
class _MatchedFrameRow extends StatelessWidget {
  const _MatchedFrameRow({required this.bytes, required this.label});

  final Uint8List bytes;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Image.memory(bytes, width: 56, height: 56, fit: BoxFit.cover),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.ink48, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _ToastData {
  const _ToastData(this.title, this.subtitle, this.faces);

  final String title;
  final String? subtitle;

  /// Faces to show at the left (a scan's result): up to three, overlapping.
  final List<int> faces;
}

/// A message over the video: a bold title, a quieter line under it, and - for a scan result - the
/// faces that were found, overlapping at the left. Near-black, no coloured edge or icon.
class _ToastCard extends StatelessWidget {
  const _ToastCard({super.key, required this.data});

  final _ToastData data;

  static const double _face = 34;
  static const double _overlap = 20;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    const surface = Color(0xEE15171A);
    final faces = data.faces.take(3).toList();

    return Container(
      constraints: const BoxConstraints(maxWidth: 400),
      padding: EdgeInsets.fromLTRB(faces.isEmpty ? AppSpacing.base : AppSpacing.md, AppSpacing.md, AppSpacing.base, AppSpacing.md),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (faces.isNotEmpty) ...[
            SizedBox(
              width: _face + (faces.length - 1) * (_face - _overlap) + 4,
              height: _face + 4,
              child: Stack(
                children: [
                  for (var i = 0; i < faces.length; i++)
                    Positioned(
                      left: i * (_face - _overlap),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(color: surface, shape: BoxShape.circle),
                        child: FaceAvatar(faceId: faces[i], size: _face),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.title,
                  style: textTheme.titleSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                ),
                if (data.subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    data.subtitle!,
                    style: textTheme.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.66), height: 1.35),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The bottom bar: one calm rounded surface holding play / pause, the seek bar with the times under
/// it, and - when there are people in the video - the People button. Same near-black surface and
/// hairline edge as the rest of the viewer's floating pieces; no gradient wash over the picture.
class _VideoControlsBar extends StatelessWidget {
  const _VideoControlsBar({
    required this.controller,
    required this.formatDuration,
    required this.markers,
    required this.peopleCount,
    required this.peopleOpen,
    required this.peoplePulse,
    required this.onPlayPause,
    required this.onPeople,
  });

  final VideoPlayerController controller;
  final String Function(Duration) formatDuration;
  final List<int> markers;
  final int peopleCount;
  final bool peopleOpen;
  final int peoplePulse;
  final VoidCallback onPlayPause;
  final VoidCallback onPeople;

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    final label = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Colors.white.withValues(alpha: 0.72),
          fontFeatures: const [FontFeature.tabularFigures()],
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.base, 0, AppSpacing.base, AppSpacing.xxl),
      child: Container(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xs + 2, AppSpacing.xs + 2, AppSpacing.md, AppSpacing.xs + 2),
        decoration: BoxDecoration(
          color: const Color(0xCC121413),
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
        ),
        child: Row(
          children: [
            MediaChromeButton(
              icon: value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              tooltip: value.isPlaying ? 'Pause' : 'Play',
              onTap: onPlayPause,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _VideoScrubber(controller: controller, markers: markers),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Row(
                      children: [
                        Text(formatDuration(value.position), style: label),
                        const Spacer(),
                        Text(formatDuration(value.duration), style: label),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (peopleCount > 0) ...[
              const SizedBox(width: AppSpacing.md),
              PeopleChipButton(count: peopleCount, pulse: peoplePulse, open: peopleOpen, onTap: onPeople),
            ],
          ],
        ),
      ),
    );
  }
}

/// A thin seek bar: a rounded track, a small thumb that grows while you hold it, and (for a person
/// picked in the People panel) small dots where they appear. Tap anywhere on it to jump there, or
/// drag; the video pauses while you drag and carries on afterwards if it was playing.
class _VideoScrubber extends StatefulWidget {
  const _VideoScrubber({required this.controller, required this.markers});

  final VideoPlayerController controller;
  final List<int> markers;

  @override
  State<_VideoScrubber> createState() => _VideoScrubberState();
}

class _VideoScrubberState extends State<_VideoScrubber> {
  bool _dragging = false;
  bool _wasPlaying = false;
  double _dragFraction = 0;
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  double _fractionAt(double dx, double width) => (dx / width).clamp(0.0, 1.0);

  void _seek(double fraction, {bool force = false}) {
    // Seeking on every drag event floods the player; one every ~70 ms is plenty, and the last one always lands.
    final now = DateTime.now();
    if (!force && now.difference(_lastSeek) < const Duration(milliseconds: 70)) return;
    _lastSeek = now;
    final ms = widget.controller.value.duration.inMilliseconds;
    widget.controller.seekTo(Duration(milliseconds: (fraction * ms).round()));
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.controller.value;
    final durationMs = value.duration.inMilliseconds;
    final positionMs = value.position.inMilliseconds;
    final playedFraction = durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _seek(_fractionAt(d.localPosition.dx, width), force: true),
          onHorizontalDragStart: (d) {
            _wasPlaying = widget.controller.value.isPlaying;
            widget.controller.pause();
            setState(() {
              _dragging = true;
              _dragFraction = _fractionAt(d.localPosition.dx, width);
            });
            _seek(_dragFraction, force: true);
          },
          onHorizontalDragUpdate: (d) {
            setState(() => _dragFraction = _fractionAt(d.localPosition.dx, width));
            _seek(_dragFraction);
          },
          onHorizontalDragEnd: (_) {
            _seek(_dragFraction, force: true);
            setState(() => _dragging = false);
            if (_wasPlaying) widget.controller.play();
          },
          child: SizedBox(
            height: 30,
            width: double.infinity,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: _dragging ? 1.0 : 0.0),
              duration: const Duration(milliseconds: 140),
              builder: (context, grow, _) => CustomPaint(
                painter: _ScrubberPainter(
                  fraction: _dragging ? _dragFraction : playedFraction,
                  grow: grow,
                  markers: widget.markers,
                  durationMs: durationMs,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ScrubberPainter extends CustomPainter {
  _ScrubberPainter({required this.fraction, required this.grow, required this.markers, required this.durationMs});

  final double fraction; // 0..1
  final double grow; // 0..1 while held
  final List<int> markers;
  final int durationMs;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final trackHeight = 3.5 + 2.5 * grow;
    final left = 7.0; // room for the thumb at both ends
    final right = size.width - 7.0;
    final span = right - left;
    final x = left + span * fraction;

    final radius = Radius.circular(trackHeight / 2);
    canvas.drawRRect(
      RRect.fromLTRBR(left, y - trackHeight / 2, right, y + trackHeight / 2, radius),
      Paint()..color = Colors.white.withValues(alpha: 0.24),
    );
    canvas.drawRRect(
      RRect.fromLTRBR(left, y - trackHeight / 2, x, y + trackHeight / 2, radius),
      Paint()..color = Colors.white,
    );

    // Where the picked person appears.
    if (durationMs > 0) {
      for (final t in markers) {
        final mx = left + span * (t / durationMs).clamp(0.0, 1.0);
        canvas.drawCircle(Offset(mx, y), 4.4, Paint()..color = const Color(0xFF121413));
        canvas.drawCircle(Offset(mx, y), 3.0, Paint()..color = const Color(0xFF5FE0CF));
      }
    }

    // The thumb.
    final thumb = 6.0 + 3.0 * grow;
    canvas.drawCircle(Offset(x, y), thumb + 1.2, Paint()..color = Colors.black.withValues(alpha: 0.32));
    canvas.drawCircle(Offset(x, y), thumb, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _ScrubberPainter old) =>
      old.fraction != fraction || old.grow != grow || old.durationMs != durationMs || !identical(old.markers, markers);
}
