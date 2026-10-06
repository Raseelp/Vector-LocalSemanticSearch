import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:twentyonevision/services/native_services.dart';
import 'package:twentyonevision/utils/app_colors.dart';
import 'package:twentyonevision/view/widget/chip_art.dart';
import 'package:twentyonevision/view/widget/library_orbit.dart';

// The Library page's scanning hero: a rounded square that is the scan, and shows what is
// happening inside it.
//
// The outline is the progress (indexing's, teal). Inside, while photos are indexed, the ones
// indexed since the last round (up to six, side by side) are read: each is cut into a grid of
// patches that light as they are read, and then drops into the strip underneath, which is the
// queue of photos waiting for their faces. The strip's own outline fills (plum) as that queue
// fills towards the next face batch. When the batch starts, the queued photos rise into the
// square and the faces of each are found: the outline of indexing dims and a thinner plum one
// shows the batch; each photo's faces get a box, landmarks and a small mesh, are lifted out one
// by one, and travel to the person they match along the bottom (a face nobody matches starts a
// new person).

/// What the chip is doing: waiting to be started, scanning, or showing that a scan is done.
enum ScanChipMode { idle, scanning, complete }

/// What a finished scan has to say.
class ScanChipSummary {
  const ScanChipSummary({required this.indexed, required this.failed, required this.people});

  final int indexed, failed, people;
}

/// The numbers a scan has to tell while it runs.
class ScanChipStats {
  const ScanChipStats({
    required this.indexed,
    required this.total,
    this.found,
    this.faceDone = 0,
    this.faceTotal = 0,
    this.people = 0,
    this.tuning = false,
    this.etaMs,
  });

  /// Items indexed so far, of [total] (0 while the folder is still being walked, when [found]
  /// says how many files it has found).
  final int indexed, total;
  final int? found;

  /// Photos done of the batch being worked on, and people found so far.
  final int faceDone, faceTotal, people;

  /// The faces are doing their one-off speed test.
  final bool tuning;

  /// How long indexing has left, in milliseconds (null until it can be told).
  final int? etaMs;
}

/// A just-indexed photo to read in the square.
class OrbitPhoto {
  const OrbitPhoto({required this.id, required this.bytes});

  final String id;
  final Uint8List? bytes;
}

// The square is drawn on a 340 x 340 sheet that is scaled to fit.
const double _sheet = 340;
const Rect _photoBox = Rect.fromLTWH(30, 34, 280, 206);
const Rect _strip = Rect.fromLTWH(30, 252, 280, 56);
// The queue strip: thumbnails from [_queueLeft] to [_queueRight] (where the last one starts).
const double _tileSize = 34;
const double _queueLeft = 36;
const double _queueRight = 270;
// Photos kept in the strip: all of a batch's while faces follow the scan, else the last few.
const int _queueMax = 12;
const int _lastMax = 5;

// Seconds the photos shown together take to be read (the more there are, the quicker - it is
// meant to look like the pace of the scan), and to have a photo's faces lifted out and placed.
const int _mosaicMax = 6;
double _cycleFor(int photos) => const [3.6, 3.6, 3.2, 2.9, 2.6, 2.3, 2.0][photos.clamp(1, 6)];
const double _faceCycle = 4.8;
const int _maxFacesShown = 5;
const int _traySlots = 5;
// Cells in the memory array along the top of the bank (two rows).
const int _memoryCellCount = 136;

double _seg(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);
double _ease(double x) => 1 - math.pow(1 - x, 3).toDouble();
double _back(double x) {
  const c = 1.70158;
  return 1 + (c + 1) * math.pow(x - 1, 3) + c * math.pow(x - 1, 2);
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

// How [n] photos read together are laid out, as parts of the photo area. Several for each
// count, and a different one is used each round, so the mosaic is never the same twice; every
// photo fills its cell (cropped to it, never stretched).
const _bentoLayouts = <List<List<Rect>>>[
  [],
  [
    [Rect.fromLTWH(0, 0, 1, 1)],
  ],
  [
    [Rect.fromLTWH(0, 0, .5, 1), Rect.fromLTWH(.5, 0, .5, 1)],
    [Rect.fromLTWH(0, 0, 1, .5), Rect.fromLTWH(0, .5, 1, .5)],
    [Rect.fromLTWH(0, 0, .62, 1), Rect.fromLTWH(.62, 0, .38, 1)],
    [Rect.fromLTWH(0, 0, .38, 1), Rect.fromLTWH(.38, 0, .62, 1)],
  ],
  [
    [Rect.fromLTWH(0, 0, .58, 1), Rect.fromLTWH(.58, 0, .42, .5), Rect.fromLTWH(.58, .5, .42, .5)],
    [Rect.fromLTWH(0, 0, .42, .5), Rect.fromLTWH(0, .5, .42, .5), Rect.fromLTWH(.42, 0, .58, 1)],
    [Rect.fromLTWH(0, 0, 1, .58), Rect.fromLTWH(0, .58, .5, .42), Rect.fromLTWH(.5, .58, .5, .42)],
    [Rect.fromLTWH(0, 0, .5, .42), Rect.fromLTWH(.5, 0, .5, .42), Rect.fromLTWH(0, .42, 1, .58)],
    [Rect.fromLTWH(0, 0, .34, 1), Rect.fromLTWH(.34, 0, .33, 1), Rect.fromLTWH(.67, 0, .33, 1)],
  ],
  [
    [
      Rect.fromLTWH(0, 0, .5, .5), Rect.fromLTWH(.5, 0, .5, .5),
      Rect.fromLTWH(0, .5, .5, .5), Rect.fromLTWH(.5, .5, .5, .5),
    ],
    [
      Rect.fromLTWH(0, 0, .55, 1), Rect.fromLTWH(.55, 0, .45, .34),
      Rect.fromLTWH(.55, .34, .45, .33), Rect.fromLTWH(.55, .67, .45, .33),
    ],
    [
      Rect.fromLTWH(0, 0, 1, .55), Rect.fromLTWH(0, .55, .34, .45),
      Rect.fromLTWH(.34, .55, .33, .45), Rect.fromLTWH(.67, .55, .33, .45),
    ],
    [
      Rect.fromLTWH(0, 0, .4, .6), Rect.fromLTWH(.4, 0, .6, .6),
      Rect.fromLTWH(0, .6, .6, .4), Rect.fromLTWH(.6, .6, .4, .4),
    ],
  ],
  [
    [
      Rect.fromLTWH(0, 0, .5, 1), Rect.fromLTWH(.5, 0, .25, .5), Rect.fromLTWH(.75, 0, .25, .5),
      Rect.fromLTWH(.5, .5, .25, .5), Rect.fromLTWH(.75, .5, .25, .5),
    ],
    [
      Rect.fromLTWH(0, 0, .6, .6), Rect.fromLTWH(.6, 0, .4, .6), Rect.fromLTWH(0, .6, .34, .4),
      Rect.fromLTWH(.34, .6, .33, .4), Rect.fromLTWH(.67, .6, .33, .4),
    ],
    [
      Rect.fromLTWH(0, 0, .34, .5), Rect.fromLTWH(.34, 0, .33, .5), Rect.fromLTWH(.67, 0, .33, .5),
      Rect.fromLTWH(0, .5, .5, .5), Rect.fromLTWH(.5, .5, .5, .5),
    ],
  ],
  [
    [
      Rect.fromLTWH(0, 0, .34, .5), Rect.fromLTWH(.34, 0, .33, .5), Rect.fromLTWH(.67, 0, .33, .5),
      Rect.fromLTWH(0, .5, .34, .5), Rect.fromLTWH(.34, .5, .33, .5), Rect.fromLTWH(.67, .5, .33, .5),
    ],
    [
      Rect.fromLTWH(0, 0, .5, .6), Rect.fromLTWH(.5, 0, .5, .3), Rect.fromLTWH(.5, .3, .25, .3),
      Rect.fromLTWH(.75, .3, .25, .3), Rect.fromLTWH(0, .6, .5, .4), Rect.fromLTWH(.5, .6, .5, .4),
    ],
    [
      Rect.fromLTWH(0, 0, .4, .5), Rect.fromLTWH(0, .5, .4, .5), Rect.fromLTWH(.4, 0, .3, .5),
      Rect.fromLTWH(.7, 0, .3, .5), Rect.fromLTWH(.4, .5, .3, .5), Rect.fromLTWH(.7, .5, .3, .5),
    ],
  ],
];

List<Rect> _bentoCells(int n, int layout) {
  final templates = _bentoLayouts[n.clamp(1, 6)];
  final template = templates[layout % templates.length];
  const b = _photoBox;
  return [
    for (final f in template)
      Rect.fromLTWH(
        b.left + f.left * b.width,
        b.top + f.top * b.height,
        f.width * b.width,
        f.height * b.height,
      ).deflate(3),
  ];
}

/// The part of [pic] that fills a box of [aspect] (width / height) without stretching it: as
/// much of the photo as fits, cut to that shape around [focus] (fractions of the photo).
Rect _coverSrc(_Pic pic, double aspect, {Offset focus = const Offset(.5, .5)}) {
  if (!aspect.isFinite || aspect <= 0) return Rect.fromLTWH(0, 0, pic.w, pic.h);
  final double w, h;
  if (pic.w / pic.h > aspect) {
    h = pic.h;
    w = h * aspect;
  } else {
    w = pic.w;
    h = w / aspect;
  }
  return Rect.fromLTWH(
    (focus.dx * pic.w - w / 2).clamp(0.0, pic.w - w),
    (focus.dy * pic.h - h / 2).clamp(0.0, pic.h - h),
    w,
    h,
  );
}

/// Where to put a photo so it fills the photo area as far as it can while keeping the faces
/// [events] in view: scaled to cover the area, centred on the faces, and pulled back only when
/// the faces would not fit otherwise. The result may be larger than the area (it is clipped).
Rect _faceView(_Pic pic, List<FaceEvent> events) {
  const box = _photoBox;
  final cover = math.max(box.width / pic.w, box.height / pic.h);
  final contain = math.min(box.width / pic.w, box.height / pic.h);
  var left = 1.0, top = 1.0, right = 0.0, bottom = 0.0;
  for (final e in events) {
    if (e.box.length != 4) continue;
    left = math.min(left, e.box[0]);
    top = math.min(top, e.box[1]);
    right = math.max(right, e.box[2]);
    bottom = math.max(bottom, e.box[3]);
  }
  if (right <= left || bottom <= top) {
    left = 0;
    top = 0;
    right = 1;
    bottom = 1;
  }
  final faceW = (right - left) * pic.w, faceH = (bottom - top) * pic.h;
  // The faces, with some room around them, must stay inside the area.
  final keep = math.min(box.width / (faceW * 1.4), box.height / (faceH * 1.5));
  final scale = math.max(contain, math.min(cover, keep));
  final w = pic.w * scale, h = pic.h * scale;
  double place(double size, double boxStart, double boxSize, double faceMid) {
    if (size <= boxSize) return boxStart + (boxSize - size) / 2;
    return (boxStart + boxSize / 2 - faceMid * size).clamp(boxStart + boxSize - size, boxStart);
  }

  return Rect.fromLTWH(
    place(w, box.left, box.width, (left + right) / 2),
    place(h, box.top, box.height, (top + bottom) / 2),
    w,
    h,
  );
}

/// A decoded photo.
class _Pic {
  _Pic(this.image);

  final ui.Image image;

  /// The average colour of each of the 7 x 7 patches of the photo's middle square (the part the
  /// model reads), row by row; null if they could not be read.
  List<Color>? tones;

  double get w => image.width.toDouble();
  double get h => image.height.toDouble();
}

Future<List<Color>?> _patchTones(ui.Image image) async {
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final w = image.width, h = image.height;
    final side = math.min(w, h);
    final ox = (w - side) ~/ 2, oy = (h - side) ~/ 2;
    // Red, green, blue and the number of pixels, for each patch.
    final sums = List<int>.filled(49 * 4, 0);
    for (var y = 0; y < side; y += 2) {
      final row = math.min<int>(6, y * 7 ~/ side);
      for (var x = 0; x < side; x += 2) {
        final k = (row * 7 + math.min<int>(6, x * 7 ~/ side)) * 4;
        final i = ((oy + y) * w + ox + x) * 4;
        sums[k] += data.getUint8(i);
        sums[k + 1] += data.getUint8(i + 1);
        sums[k + 2] += data.getUint8(i + 2);
        sums[k + 3]++;
      }
    }
    return [
      for (var k = 0; k < 49; k++)
        sums[k * 4 + 3] == 0
            ? const Color(0xFF808080)
            : Color.fromARGB(255, sums[k * 4] ~/ sums[k * 4 + 3], sums[k * 4 + 1] ~/ sums[k * 4 + 3], sums[k * 4 + 2] ~/ sums[k * 4 + 3]),
    ];
  } catch (_) {
    return null;
  }
}

// Number [i] of a photo's vector (-1..1): derived from the photo's own colours, so each photo
// gets its own list. (Illustrative: the real vector is made by the model, not by the screen.)
double _vectorValue(List<Color>? tones, int i) {
  final tone = tones == null ? const Color(0xFF808080) : tones[(i * 7) % 49];
  final v = math.sin((tone.r * 12.9898 + tone.g * 78.233 + tone.b * 37.719) * (i + 1) * 3.1) * 43758.5453;
  return ((v - v.floorToDouble()) * 2 - 1) * .98;
}

Future<_Pic?> _decodePic(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 300);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final pic = _Pic(frame.image);
    pic.tones = await _patchTones(frame.image);
    return pic;
  } catch (_) {
    return null;
  }
}

/// The photos waiting for the next face batch, as the scan reports them.
class OrbitQueueInfo {
  const OrbitQueueInfo({
    required this.count,
    required this.ms,
    required this.photos,
    required this.windowMs,
    required this.at,
  });

  /// Photos waiting, and milliseconds since the last batch ended, as of [at].
  final int count, ms;

  /// A batch starts at this many photos, or this many milliseconds, whichever comes first.
  final int photos, windowMs;
  final DateTime at;

  /// How full the queue is, 0..1.
  double get fill {
    final waited = ms + DateTime.now().difference(at).inMilliseconds;
    return math.max(count / photos, waited / windowMs).clamp(0.0, 1.0);
  }
}

// A packet of data running along a bond wire (t from the die, or bank, to the board).
class _Packet {
  _Packet(this.bar, this.wire, this.speed);

  final int bar, wire;
  final double speed;
  double t = 0;
}

// A thumbnail in the queue strip.
class _QTile {
  _QTile(this.pic, this.x);

  final _Pic pic;
  double x;
}

// The photo the square is reading now.
class _Shot {
  _Shot(this.pics, this.start, this.layout) : cycle = _cycleFor(pics.length);

  /// The photos read together, oldest first.
  final List<_Pic> pics;
  final double start;
  final double cycle;

  /// Which of the bento layouts for this many photos is used.
  final int layout;
}

// A person on the tray along the bottom.
class _Person {
  _Person({
    required this.id,
    required this.pic,
    required this.src,
    required this.count,
    required this.bornAt,
    required this.isNew,
  });

  final int id;
  final _Pic pic;
  final Rect src;
  int count;
  final double bornAt;
  final bool isNew;
  double pulseAt = -100;
  double lastUsed = 0;
}

// One face being lifted out.
class _FaceItem {
  _FaceItem(this.event, this.slot, this.matched);

  final FaceEvent event;
  final int slot;
  final bool matched;
  bool committed = false;
}

// The faces of one photo, waiting for their turn (and for the photo to be read in).
class _FaceGroup {
  _FaceGroup(this.uri);

  final String uri;
  final List<FaceEvent> events = [];
  _Pic? pic;
  bool failed = false;
}

class _FaceShot {
  _FaceShot(this.pic, this.dst, this.faces, this.start);

  final _Pic pic;
  final Rect dst;
  final List<_FaceItem> faces;
  final double start;
}

class SquareScanHero extends StatefulWidget {
  const SquareScanHero({
    super.key,
    required this.progress,
    required this.photos,
    required this.semanticsLabel,
    required this.loadPhoto,
    this.faceMode = false,
    this.faceProgress,
    this.events = const [],
    this.queue,
    this.discovered,
    this.rate = 0,
    this.stats,
    this.mode = ScanChipMode.scanning,
    this.onStart,
    this.onDismiss,
    this.summary,
  });

  /// Indexing's progress, 0..1 (null while the folder is still being walked).
  final double? progress;

  /// The latest indexed photos, newest first.
  final List<OrbitPhoto> photos;
  final String semanticsLabel;
  final Future<Uint8List?> Function(String uri) loadPhoto;

  /// Indexing is paused while the faces of a batch are found.
  final bool faceMode;
  final double? faceProgress;

  /// Faces found in the batch, newest first.
  final List<FaceEvent> events;

  /// The queue of photos waiting for the next face batch (null if faces do not follow).
  final OrbitQueueInfo? queue;

  /// While the folder is still being walked: how many files it has found so far.
  final int? discovered;

  /// How fast photos are being indexed now (per second): how busy the connections look.
  final double rate;

  /// The numbers the story under the chip tells.
  final ScanChipStats? stats;

  /// Idle (a tap on the chip starts a scan), scanning, or done (a tap dismisses it).
  final ScanChipMode mode;
  final VoidCallback? onStart;
  final VoidCallback? onDismiss;
  final ScanChipSummary? summary;

  @override
  State<SquareScanHero> createState() => _SquareScanHeroState();
}

class _SquareScanHeroState extends State<SquareScanHero>
    with SingleTickerProviderStateMixin {
  // Seconds since the hero appeared (a year long, so it never runs out).
  static const _clockSeconds = 365.0 * 24 * 3600;
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(days: 365),
  )..addListener(_step);
  double get _now => _clock.value * _clockSeconds;

  bool _still = false;

  // The clock runs only while something on the chip moves: a scan, the lid, a wire fading, the
  // reflection following the phone. A chip at rest under its lid draws nothing at all.
  void _wake() {
    if (!mounted || _still || _clock.isAnimating) return;
    _clock.forward();
  }

  bool _animating() {
    if (_still) return false;
    if (_mode != ScanChipMode.idle) return true;
    if (_lid > 0 || (_bootAt >= 0 && _now - _bootAt < 3.4)) return true;
    if (_idleAmt < .998 || _scanAmt > .002 || _doneAmt > .002) return true;
    if ((_clipAlpha - 1).abs() > .002 || (_faceAlpha - .5).abs() > .002) return true;
    for (var i = 0; i < chipWireCount; i++) {
      if (_wireClip[i] > .002 || _wireFace[i] > .002) return true;
    }
    // Without a sensor the reflection drifts by itself; with one it follows the phone.
    if (!_tiltLive) return true;
    return (_tilt - _tiltTarget).distance > .002;
  }

  // ---- the three states of the chip ----
  late ScanChipMode _mode = widget.mode;
  // How much of each state is showing (they cross-fade when the state changes).
  late double _idleAmt = widget.mode == ScanChipMode.idle ? 1 : 0;
  late double _scanAmt = widget.mode == ScanChipMode.scanning ? 1 : 0;
  late double _doneAmt = widget.mode == ScanChipMode.complete ? 1 : 0;
  double _bootAt = -100;
  double _completeAt = -100;
  bool _dismissed = false;
  bool _pressed = false;
  Timer? _dismissTimer;
  // How the phone is held, for the light on the lid (from the accelerometer, while the lid is
  // on and in view; without one the lid just glints now and then).
  StreamSubscription<AccelerometerEvent>? _tiltSub;
  Offset _tilt = Offset.zero, _tiltTarget = Offset.zero;
  Offset? _tiltBase, _tiltFilter;
  bool _tiltLive = false;
  bool _inView = true;

  void _syncTilt() {
    final want = _mode != ScanChipMode.scanning && !_still && _inView;
    if (!want) {
      _tiltSub?.cancel();
      _tiltSub = null;
      _tiltLive = false;
      _wake();
      return;
    }
    if (_tiltSub != null) return;
    try {
      _tiltSub = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen(
        (e) {
          // Gravity as the phone feels it, smoothed so that shaking and small movements do not
          // reach the reflection, and a small dead band so that holding it still keeps it
          // still. The way it is held becomes the middle again over many seconds.
          final raw = Offset(e.x, e.y) / 9.81;
          _tiltFilter = _tiltFilter == null ? raw : Offset.lerp(_tiltFilter!, raw, .12);
          _tiltBase = _tiltBase == null ? _tiltFilter : Offset.lerp(_tiltBase!, _tiltFilter!, .004);
          var d = _tiltFilter! - _tiltBase!;
          double dead(double v) => v.abs() < .03 ? 0 : v - v.sign * .03;
          d = Offset(dead(d.dx), dead(d.dy));
          // Full swing at about a quarter of the way to tipping the phone on its side.
          _tiltTarget = Offset((-d.dx / .42).clamp(-1.0, 1.0), (d.dy / .42).clamp(-1.0, 1.0));
          final wasLive = _tiltLive;
          _tiltLive = true;
          if (!wasLive || (_tilt - _tiltTarget).distance > .002) _wake();
        },
        onError: (Object _) {
          _tiltLive = false;
          _tiltSub?.cancel();
          _tiltSub = null;
          _wake();
        },
        cancelOnError: true,
      );
    } catch (_) {
      _tiltLive = false;
      _wake();
    }
  }

  // How far the lid is off (0 closed, 1 gone), and what is etched on it.
  double _lid = 0;
  ChipLidText _lidIdle = const ChipLidText(above: 'ON-DEVICE', big: 'VISION', below: 'PRIVATE AI', hint: 'TAP TO SCAN');
  ChipLidText? _lidDone;

  // ---- indexing ----
  _Shot? _shot;
  // The strip: photos read and waiting for their faces, oldest first.
  final List<_QTile> _queue = [];
  double _fill = 0;
  // How much of each bond wire has been bonded, in the two rows (CLIP along the top, FACE along
  // the bottom), and how bright each row is.
  final List<double> _wireClip = List.filled(chipWireCount, 0);
  final List<double> _wireFace = List.filled(chipWireCount, 0);
  double _clipAlpha = 1, _faceAlpha = .5;
  // ---- the lanes and the memory ----
  //
  // The two rows of wires are lanes of a link between the die (or the memory bank) and the
  // board. The scan brings them up one after another (a lane that is coming up trains, with a
  // pattern running up and down it, and flashes along its length when it locks); data packets
  // run along the lanes that are up, as many as indexing really moves. And the memory array
  // along the top of the bank fills a cell at a time as items are stored: much finer than the
  // lanes, so even a big library visibly moves.
  final List<_Packet> _packets = [];
  // The lane each row is bringing up now, or -1.
  final List<int> _training = [-1, -1];
  final List<double> _trainFraction = [0, 0];
  // When each lane last locked (for the flash along it), and how many were up when last looked.
  final List<List<double>> _lockAt = [
    List.filled(chipWireCount, -100.0),
    List.filled(chipWireCount, -100.0),
  ];
  final List<int> _lanesUp = [-1, -1];
  final List<double> _packetDebt = [0, 0];
  // The cells of the memory array that have been written, and when the latest were.
  int _cellsWritten = 0;
  final Map<int, double> _cellWrittenAt = {};

  double _lastStep = 0;
  // Since when no photo has been in the square (it then shows that it is waiting).
  double _idleSince = -100;
  // When this scan began, and when the model of each kind (0: photos, 1: faces) began to load.
  double _scanAt = -100;
  // Cores to a row of the die: as many as the phone has (two rows).
  int _dieColumns = 4;
  final List<double> _loadStart = [-1, -1];
  // At the start of a face batch the strip's photos rise into the square; they are then the
  // photos the faces are looked for in.
  List<_QTile> _launch = [];
  double _launchAt = -100;
  List<_Pic> _batchPics = [];
  final Set<String> _shown = {};
  bool _starting = false;
  final Map<String, Future<_Pic?>> _pics = {};
  final math.Random _random = math.Random();
  final Map<int, int> _lastLayout = {};

  // ---- faces ----
  _FaceShot? _faceShot;
  final List<_FaceGroup> _groups = [];
  final Set<int> _seenFaces = {};
  final List<_Person?> _tray = List.filled(_traySlots, null);
  bool _wasFaceMode = false;

  @override
  void initState() {
    super.initState();
    _wasFaceMode = widget.faceMode;
    // What is already there when the hero appears is not replayed.
    for (final photo in widget.photos) {
      _shown.add(photo.id);
    }
    for (final e in widget.events) {
      _seenFaces.add(e.id);
    }
    if (_mode == ScanChipMode.complete) _completeAt = 0;
    // The core count (so the die the right size) is known after this; the pictures of everything
    // under the lid are made then, a little apart, before anyone has tapped.
    _loadMarks().whenComplete(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (mounted) await warmChipInside(_photoBox, _strip, _dieColumns);
    });
  }

  Future<void> _loadMarks() async {
    final chip = await NativeServices().deviceChip();
    if (chip == null || !mounted) return;
    String clean(Object? v) => (v as String? ?? '').trim();
    var maker = clean(chip['maker']).toUpperCase();
    if (maker == 'QTI' || maker == 'QUALCOMM TECHNOLOGIES, INC') maker = 'QUALCOMM';
    var model = clean(chip['model']).toUpperCase();
    if (model.isEmpty || model == 'UNKNOWN') model = clean(chip['hardware']).toUpperCase();
    final cores = (chip['cores'] as num?)?.toInt() ?? 0;
    final abi = switch (clean(chip['abi'])) {
      'arm64-v8a' => 'ARM64',
      'armeabi-v7a' => 'ARMV7',
      'x86_64' => 'X86-64',
      final other => other.toUpperCase(),
    };
    final parts = [if (cores > 0) '$cores CORES', if (abi.isNotEmpty) abi];
    final mhz = (chip['maxMhz'] as num?)?.toInt() ?? 0;
    final ramMb = (chip['ramMb'] as num?)?.toInt() ?? 0;
    final release = clean(chip['release']);
    final speed = [
      if (mhz > 0) '${(mhz / 1000).toStringAsFixed(mhz % 1000 == 0 ? 0 : 1)} GHZ MAX',
      if (ramMb > 0) '${(ramMb / 1024).round()} GB RAM',
    ];
    setState(() {
      if (cores > 0) _dieColumns = chipDieColumns(cores);
      _lidIdle = ChipLidText(
        above: maker.isEmpty || maker == 'UNKNOWN' ? 'ON-DEVICE' : maker,
        big: model.isEmpty ? 'VISION' : model,
        below: parts.isEmpty ? 'PRIVATE AI' : parts.join(' · '),
        extras: [
          if (speed.isNotEmpty) speed.join(' · '),
          if (release.isNotEmpty) 'ANDROID $release',
        ],
        hint: 'TAP TO SCAN',
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    _inView = TickerMode.of(context);
    // The chip's pictures are made as sharp as this screen can show.
    setChipArtScale(MediaQuery.devicePixelRatioOf(context));
    _syncTilt();
    // With reduced motion nothing moves by itself: the square only changes when the scan
    // reports something (see didUpdateWidget).
    if (_still) {
      _clock.stop();
    } else {
      _wake();
    }
  }

  // The state of the chip changed: what belonged to the last scan goes, and a finished scan
  // announces itself.
  void _changeMode(ScanChipMode to) {
    _mode = to;
    _syncTilt();
    _dismissTimer?.cancel();
    _shot = null;
    _queue.clear();
    _launch = [];
    _batchPics = [];
    _groups.clear();
    _faceShot = null;
    _fill = 0;
    _idleSince = _now;
    if (to == ScanChipMode.scanning) _scanAt = _now;
    _loadStart[0] = _loadStart[1] = -1;
    _wasFaceMode = widget.faceMode;
    _shown
      ..clear()
      ..addAll(widget.photos.map((p) => p.id));
    for (final e in widget.events) {
      _seenFaces.add(e.id);
    }
    for (var i = 0; i < _tray.length; i++) {
      _tray[i] = null;
    }
    if (to == ScanChipMode.complete) {
      _completeAt = _now;
      _dismissed = false;
      HapticFeedback.mediumImpact();
      // With reduced motion the clock does not run, so the wait is by the wall clock.
      if (_still) {
        _dismissTimer = Timer(const Duration(seconds: 8), () {
          if (mounted && _mode == ScanChipMode.complete) widget.onDismiss?.call();
        });
      }
    }
  }

  static String _thousands(int n) {
    final digits = '$n';
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  // What is etched on the lid when a scan has finished.
  ChipLidText? _doneText(ScanChipSummary? summary) {
    if (summary == null) return _lidDone;
    final extra = [
      if (summary.people > 0) '${summary.people} ${summary.people == 1 ? 'PERSON' : 'PEOPLE'}',
      if (summary.failed > 0) '${summary.failed} UNREADABLE',
    ];
    return ChipLidText(
      above: 'SCAN COMPLETE',
      big: _thousands(summary.indexed),
      below: 'ITEMS INDEXED',
      extras: extra,
      hint: 'TAP TO CLOSE',
    );
  }

  void _tap() {
    if (_mode == ScanChipMode.idle) {
      HapticFeedback.lightImpact();
      _bootAt = _now;
      _wake();
      widget.onStart?.call();
    } else if (_mode == ScanChipMode.complete) {
      widget.onDismiss?.call();
    }
  }

  @override
  void didUpdateWidget(SquareScanHero old) {
    super.didUpdateWidget(old);
    _wake();
    if (widget.mode != _mode) _changeMode(widget.mode);
    _lidDone = _doneText(widget.summary);
    if (_mode != ScanChipMode.scanning) {
      if (_still) _step();
      return;
    }
    if (widget.faceMode != _wasFaceMode) {
      _wasFaceMode = widget.faceMode;
      // Whatever was being read is finished with; a batch starts or ends.
      _finishShot();
      _groups.clear();
      _faceShot = null;
      if (widget.faceMode) {
        for (final e in widget.events) {
          _seenFaces.add(e.id);
        }
        _launch = [..._queue];
        _launchAt = _now;
        _batchPics = [for (final tile in _queue) tile.pic];
        _queue.clear();
      } else {
        _fill = 0;
        _launch = [];
        _batchPics = [];
      }
    }
    if (widget.faceMode) _ingestFaces();
    if (_still) _step();
  }

  @override
  void dispose() {
    _tiltSub?.cancel();
    _dismissTimer?.cancel();
    _clock.dispose();
    _releaseImages();
    super.dispose();
  }

  // The photos the hero decoded are freed with it (not left for the garbage collector, which
  // would hold their memory for a while). Each is freed once, whatever shows it.
  void _releaseImages() {
    final freed = <ui.Image>{};
    void free(_Pic? pic) {
      if (pic != null && freed.add(pic.image)) pic.image.dispose();
    }

    for (final group in _groups) {
      free(group.pic);
    }
    free(_faceShot?.pic);
    for (final person in _tray) {
      free(person?.pic);
    }
    for (final decoding in _pics.values) {
      decoding.then(free);
    }
    _pics.clear();
  }

  Future<_Pic?> _ensure(String id, Uint8List bytes) {
    final cached = _pics[id];
    if (cached != null) return cached;
    if (_pics.length > 24) _pics.remove(_pics.keys.first);
    return _pics[id] = _decodePic(bytes);
  }

  // ---------------------------------------------------------------- stepping

  // Where tile [i] of [m] sits: spread out, then overlapping once there are too many.
  double _layoutX(int i, int m) {
    if (m <= 1) return _queueLeft;
    final step = math.min(_tileSize + 4, (_queueRight - _queueLeft - _tileSize) / (m - 1));
    return _queueLeft + i * step;
  }

  /// Where photo [i] of the ones being read lands in the strip.
  double landingX(int i) {
    final n = _shot?.pics.length ?? 1;
    return _layoutX(_queue.length + i, _queue.length + n);
  }

  // What the two rows of bond wires show. The top row (CLIP, gold) is the indexing: wires bond
  // one after another as the scan advances, or, while the folder is still being walked, a run
  // of bonding goes back and forth. The bottom row (FACE, copper) is the faces: while indexing
  // it fills dimly with the queue of photos waiting for their faces; during a batch it bonds
  // brightly with the batch. A finished scan bonds both rows. A wire that is no longer wanted
  // is drawn back a little slower than it was drawn, which is what leaves a trail behind a
  // moving run.
  final List<double> _clipTarget = List.filled(chipWireCount, 0);
  final List<double> _faceTarget = List.filled(chipWireCount, 0);

  void _updateWires(double now, double dt) {
    final clip = _clipTarget..fillRange(0, chipWireCount, 0);
    final face = _faceTarget..fillRange(0, chipWireCount, 0);
    double fill(double n, int i) => (n - i).clamp(0.0, 1.0);
    // A run along the row, and back, with a short tail.
    double run(int i, double speed, double phase) {
      final span = chipWireCount - 1;
      final x = (now * speed + phase) % (2 * span);
      final at = x <= span ? x : 2 * span - x;
      return math.max(0.0, 1 - (i - at).abs() / 2.2);
    }

    var clipAlpha = 1.0, faceAlpha = .5;
    switch (_mode) {
      case ScanChipMode.scanning:
        final progress = widget.progress;
        final batch = widget.faceMode;
        for (var i = 0; i < chipWireCount; i++) {
          clip[i] = progress == null ? run(i, 15, 0) : fill(progress * chipWireCount, i);
          if (batch) {
            final fp = widget.faceProgress;
            face[i] = fp == null ? run(i, 15, chipWireCount.toDouble()) : fill(fp * chipWireCount, i);
          } else if (widget.queue != null) {
            face[i] = fill(_fill * chipWireCount, i);
          }
        }
        if (batch) {
          clipAlpha = .45;
          faceAlpha = 1;
        }
      case ScanChipMode.complete:
        final t = now - _completeAt;
        final n = Curves.easeOutCubic.transform((t / 1.1).clamp(0.0, 1.0)) * chipWireCount;
        for (var i = 0; i < chipWireCount; i++) {
          clip[i] = fill(n, i);
          face[i] = fill(n, i);
        }
        faceAlpha = 1;
      case ScanChipMode.idle:
        break;
    }
    // A quick test of the wires after a tap, before the lid is off: a run over both rows.
    final since = now - _bootAt;
    if (_bootAt >= 0 && since < 1.4 && _mode != ScanChipMode.complete) {
      final n = (since / .6).clamp(0.0, 1.0) * chipWireCount;
      final fade = 1 - ((since - .6) / .8).clamp(0.0, 1.0);
      for (var i = 0; i < chipWireCount; i++) {
        clip[i] = math.max(clip[i], fill(n, i) * fade);
        face[i] = math.max(face[i], fill(n, i) * fade);
      }
    }
    // Bonded at once, drawn back a little slower.
    final decay = _still ? 0.0 : math.exp(-dt * 9);
    for (var i = 0; i < chipWireCount; i++) {
      _wireClip[i] = math.max(clip[i], _wireClip[i] * decay);
      _wireFace[i] = math.max(face[i], _wireFace[i] * decay);
      if (_wireClip[i] < .001) _wireClip[i] = 0;
      if (_wireFace[i] < .001) _wireFace[i] = 0;
    }
    final k = _still ? 1.0 : 1 - math.exp(-dt * 6);
    _clipAlpha += (clipAlpha - _clipAlpha) * k;
    _faceAlpha += (faceAlpha - _faceAlpha) * k;
    if ((_clipAlpha - clipAlpha).abs() < .001) _clipAlpha = clipAlpha;
    if ((_faceAlpha - faceAlpha).abs() < .001) _faceAlpha = faceAlpha;
    _stepLanes(now, dt);
  }

  void _stepLanes(double now, double dt) {
    final working = _mode == ScanChipMode.scanning && _scanAmt > .5;
    final progress = widget.progress;
    final fp = widget.faceProgress;

    // Which lane each row is bringing up, and how many it has up.
    final up = [0, 0];
    _training[0] = _training[1] = -1;
    if (working) {
      if (progress != null && progress < 1) {
        final n = progress.clamp(0.0, 1.0) * chipWireCount;
        up[0] = n.floor();
        _training[0] = up[0].clamp(0, chipWireCount - 1);
        _trainFraction[0] = n - n.floor();
      } else if (progress != null) {
        up[0] = chipWireCount;
      }
      if (widget.faceMode) {
        if (fp != null && fp < 1) {
          final n = fp.clamp(0.0, 1.0) * chipWireCount;
          up[1] = n.floor();
          _training[1] = up[1].clamp(0, chipWireCount - 1);
          _trainFraction[1] = n - n.floor();
        } else if (fp != null) {
          up[1] = chipWireCount;
        }
      } else if (widget.queue != null) {
        up[1] = (_fill * chipWireCount).floor();
      }
    }
    // A lane that has just come up flashes along its length.
    for (var bar = 0; bar < 2; bar++) {
      if (_lanesUp[bar] >= 0 && up[bar] > _lanesUp[bar] && working) {
        for (var k = _lanesUp[bar]; k < up[bar] && k < chipWireCount; k++) {
          _lockAt[bar][k] = now;
        }
      }
      _lanesUp[bar] = working ? up[bar] : -1;
    }

    // The memory array: a cell is written for every part of the scan that is stored.
    if (working && progress != null) {
      final written = (progress.clamp(0.0, 1.0) * _memoryCellCount).floor();
      if (written > _cellsWritten) {
        for (var k = math.max(_cellsWritten, written - 40); k < written; k++) {
          _cellWrittenAt[k] = now;
        }
      }
      _cellsWritten = written;
    } else if (!working) {
      _cellsWritten = _mode == ScanChipMode.complete ? _memoryCellCount : 0;
    }
    _cellWrittenAt.removeWhere((_, at) => now - at > .8);

    // Data on the lanes that are up: more of it the faster indexing goes, and a steady trickle
    // otherwise (the scan is working, whatever its speed).
    final rate = [
      working ? (math.max(1.6, widget.rate * 1.1)).clamp(1.6, 9.0).toDouble() : 0.0,
      working ? (widget.faceMode ? 4.0 : (widget.queue != null ? .7 : 0.0)) : 0.0,
    ];
    for (var bar = 0; bar < 2; bar++) {
      _packetDebt[bar] += rate[bar] * dt;
      while (_packetDebt[bar] >= 1) {
        _packetDebt[bar] -= 1;
        if (up[bar] <= 0) continue;
        _packets.add(_Packet(bar, _random.nextInt(math.min(up[bar], chipWireCount)), 22 + _random.nextDouble() * 22));
      }
    }
    for (final packet in _packets) {
      packet.t += packet.speed * dt / 15;
    }
    _packets.removeWhere((packet) => packet.t >= 1.1);
    if (_packets.length > 40) _packets.removeRange(0, _packets.length - 40);
  }

  void _glide() {
    final now = _now;
    final dt = (now - _lastStep).clamp(0.0, .2);
    _lastStep = now;
    final k = _still ? 1.0 : 1 - math.exp(-dt * 9);
    final m = _queue.length + (_shot?.pics.length ?? 0);
    for (var i = 0; i < _queue.length; i++) {
      _queue[i].x += (_layoutX(i, m) - _queue[i].x) * k;
    }
    // The lid is off while scanning (and for a moment after a tap, whether or not a scan
    // starts), and on otherwise; it takes about a second and a quarter either way.
    final lidOpen = _mode == ScanChipMode.scanning ||
        (_mode == ScanChipMode.idle && _bootAt >= 0 && now - _bootAt < 3.2);
    final lidTarget = lidOpen ? 1.0 : 0.0;
    _lid = _still
        ? lidTarget
        : (lidTarget > _lid ? math.min(lidTarget, _lid + dt / 1.3) : math.max(lidTarget, _lid - dt / 1.3));
    _tilt = Offset.lerp(_tilt, _tiltTarget, _still ? 1.0 : 1 - math.exp(-dt * 4))!;
    if ((_tilt - _tiltTarget).distance < .001) _tilt = _tiltTarget;
    _updateWires(now, dt);
    final kAmt = _still ? 1.0 : 1 - math.exp(-dt * 7);
    _idleAmt += ((_mode == ScanChipMode.idle ? 1.0 : 0.0) - _idleAmt) * kAmt;
    _scanAmt += ((_mode == ScanChipMode.scanning ? 1.0 : 0.0) - _scanAmt) * kAmt;
    _doneAmt += ((_mode == ScanChipMode.complete ? 1.0 : 0.0) - _doneAmt) * kAmt;
    if (_idleAmt > .999) _idleAmt = 1;
    if (_scanAmt < .001) _scanAmt = 0;
    if (_doneAmt < .001) _doneAmt = 0;
    final target = widget.faceMode || _mode != ScanChipMode.scanning
        ? 0.0
        : (widget.queue?.fill ?? 0.0);
    // It fills smoothly and empties at once when a batch has started.
    _fill += (target - _fill) * (_still ? 1.0 : 1 - math.exp(-dt * (target < _fill ? 20 : 3)));
  }

  void _step() {
    if (!mounted) return;
    _glide();
    switch (_mode) {
      case ScanChipMode.scanning:
        if (widget.faceMode) {
          _stepFaces();
        } else {
          _stepIndex();
        }
      case ScanChipMode.complete:
        if (!_still && !_dismissed && _now - _completeAt > 2.2 + 8) {
          _dismissed = true;
          widget.onDismiss?.call();
        }
      case ScanChipMode.idle:
        break;
    }
    if (!_animating()) _clock.stop();
  }

  // The photo being read is done: it joins the queue in the strip.
  void _finishShot() {
    final shot = _shot;
    if (shot == null) return;
    _idleSince = _now;
    final before = _queue.length;
    for (var i = 0; i < shot.pics.length; i++) {
      _queue.add(_QTile(shot.pics[i], _layoutX(before + i, before + shot.pics.length)));
    }
    final cap = widget.queue == null ? _lastMax : _queueMax;
    while (_queue.length > cap) {
      _queue.removeAt(0);
    }
    _shot = null;
  }

  // A different layout from the last round's for the same number of photos.
  int _pickLayout(int n) {
    final count = _bentoLayouts[n.clamp(1, 6)].length;
    var layout = _random.nextInt(count);
    final last = _lastLayout[n];
    if (count > 1 && layout == last) layout = (layout + 1 + _random.nextInt(count - 1)) % count;
    _lastLayout[n] = layout;
    return layout;
  }

  void _stepIndex() {
    final now = _now;
    final shot = _shot;
    if (shot != null && !_still && now - shot.start < shot.cycle) return;
    final fresh = [
      for (final photo in widget.photos)
        if (photo.bytes != null && !_shown.contains(photo.id)) photo,
    ];
    if (shot != null && _still && fresh.isEmpty) return;
    _finishShot();
    if (_starting || fresh.isEmpty) return;
    // The photos indexed since the last round, together (the newest few if there were many;
    // the ones skipped over are not shown late).
    final take = fresh.take(_mosaicMax).toList().reversed.toList();
    _starting = true;
    for (final photo in fresh) {
      _shown.add(photo.id);
    }
    while (_shown.length > 80) {
      _shown.remove(_shown.first);
    }
    Future.wait([for (final photo in take) _ensure(photo.id, photo.bytes!)]).then((pics) {
      _starting = false;
      if (!mounted || widget.faceMode || _mode != ScanChipMode.scanning) return;
      final ok = [
        for (final pic in pics)
          if (pic != null) pic,
      ];
      if (ok.isEmpty) return;
      _shot = _Shot(ok, _now, _pickLayout(ok.length));
    });
  }

  void _ingestFaces() {
    for (final e in widget.events.reversed) {
      if (!_seenFaces.add(e.id)) continue;
      // Without a box (or landmarks) there is nothing to draw it by.
      if (e.personId == null || e.box.length != 4 || e.landmarks.length < 10) continue;
      _FaceGroup? group;
      if (_groups.isNotEmpty && _groups.last.uri == e.photoUri) group = _groups.last;
      if (group == null) {
        group = _FaceGroup(e.photoUri);
        _groups.add(group);
        // A photo that cannot be had (or takes too long) is given up on, so it never holds
        // up the ones behind it.
        widget
            .loadPhoto(e.photoUri)
            .then<Uint8List?>((bytes) => bytes)
            .timeout(const Duration(seconds: 8), onTimeout: () => null)
            .then((bytes) async {
              final pic = bytes == null ? null : await _decodePic(bytes);
              if (pic == null) {
                group!.failed = true;
              } else {
                group!.pic = pic;
              }
            })
            .catchError((_) {
              group!.failed = true;
            });
      }
      group.events.add(e);
    }
    // Faces come faster than they can be shown: the oldest waiting photos are skipped.
    while (_groups.length > 4) {
      _groups.removeAt(0);
    }
    if (_seenFaces.length > 300) _seenFaces.remove(_seenFaces.first);
  }

  void _stepFaces() {
    final now = _now;
    final shot = _faceShot;
    if (shot != null) {
      for (var i = 0; i < shot.faces.length; i++) {
        final face = shot.faces[i];
        if (!face.committed && now >= shot.start + (.86 + .03 * i) * _faceCycle) {
          _commit(shot, face);
        }
      }
      if (now - shot.start < _faceCycle) return;
      for (final face in shot.faces) {
        if (!face.committed) _commit(shot, face);
      }
      _faceShot = null;
    }
    while (_groups.isNotEmpty && _groups.first.failed) {
      _groups.removeAt(0);
    }
    if (_groups.isEmpty) return;
    final group = _groups.first;
    final pic = group.pic;
    if (pic == null) return;
    _groups.removeAt(0);
    _faceShot = _startShot(group, pic, now);
  }

  _FaceShot _startShot(_FaceGroup group, _Pic pic, double now) {
    final events = [...group.events]..sort((a, b) => b.score.compareTo(a.score));
    final shown = events.take(_maxFacesShown).toList();
    final reserved = <int>{};
    final faces = <_FaceItem>[];
    // Faces that match someone already on the tray first, so a new face never takes their place.
    for (final e in shown) {
      final slot = _tray.indexWhere((p) => p != null && p.id == e.personId);
      if (slot >= 0) {
        reserved.add(slot);
        faces.add(_FaceItem(e, slot, true));
      }
    }
    for (final e in shown) {
      if (faces.any((f) => f.event == e)) continue;
      var slot = -1;
      for (var j = 0; j < _traySlots; j++) {
        if (_tray[j] == null && !reserved.contains(j)) {
          slot = j;
          break;
        }
      }
      if (slot < 0) {
        var oldest = double.infinity;
        for (var j = 0; j < _traySlots; j++) {
          final p = _tray[j];
          if (p == null || reserved.contains(j)) continue;
          if (p.lastUsed < oldest) {
            oldest = p.lastUsed;
            slot = j;
          }
        }
      }
      if (slot < 0) continue;
      reserved.add(slot);
      faces.add(_FaceItem(e, slot, false));
    }
    faces.sort((a, b) => shown.indexOf(a.event).compareTo(shown.indexOf(b.event)));
    return _FaceShot(pic, _faceView(pic, [for (final f in faces) f.event]), faces, now);
  }

  void _commit(_FaceShot shot, _FaceItem face) {
    face.committed = true;
    final now = _now;
    final e = face.event;
    final existing = _tray[face.slot];
    if (existing != null && existing.id == e.personId) {
      existing
        ..count = e.personPhotos
        ..pulseAt = now
        ..lastUsed = now;
    } else {
      _tray[face.slot] = _Person(
        id: e.personId!,
        pic: shot.pic,
        src: _faceCrop(shot.pic, e),
        count: e.personPhotos,
        bornAt: now,
        isNew: e.isNew,
      )..lastUsed = now;
    }
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(constraints.maxWidth, 320.0);
        final interactive = widget.mode != ScanChipMode.scanning;
        Widget chip = TweenAnimationBuilder<double>(
          tween: Tween(end: widget.progress ?? 0),
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeOutCubic,
          builder: (context, p, _) {
            return TweenAnimationBuilder<double>(
              tween: Tween(end: widget.faceMode ? 1 : 0),
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeInOut,
              builder: (context, faceAmount, _) {
                return TweenAnimationBuilder<double>(
                  tween: Tween(end: widget.faceProgress ?? 0),
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOutCubic,
                  builder: (context, fp, _) {
                    return RepaintBoundary(
                      child: CustomPaint(
                        size: Size(side, side),
                        painter: _SquarePainter(
                          scene: this,
                          repaint: _clock,
                          progress: p,
                          indeterminate: widget.progress == null,
                          faceAmount: faceAmount,
                          faceProgress: fp,
                          faceIndeterminate: widget.faceMode && widget.faceProgress == null,
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
        if (interactive) {
          chip = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = widget.mode == ScanChipMode.idle),
            onTapCancel: () => setState(() => _pressed = false),
            onTapUp: (_) => setState(() => _pressed = false),
            onTap: _tap,
            child: chip,
          );
        }
        return Center(
          child: SizedBox(
            width: side,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  button: interactive,
                  label: widget.semanticsLabel,
                  child: chip,
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: _below(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // What is written under the chip.
  Widget _below() {
    switch (widget.mode) {
      case ScanChipMode.idle:
        return const SizedBox(key: ValueKey('idle'), width: double.infinity);
      case ScanChipMode.complete:
        final summary = widget.summary;
        if (summary == null) return const SizedBox(key: ValueKey('done'), width: double.infinity);
        return _CompleteTexts(key: const ValueKey('done'), summary: summary);
      case ScanChipMode.scanning:
        final stats = widget.stats;
        if (stats == null) return const SizedBox(key: ValueKey('scan'), width: double.infinity);
        return _ScanStory(
          key: const ValueKey('scan'),
          stats: stats,
          queue: widget.queue,
          facesNow: widget.faceMode,
        );
    }
  }
}

/// What a finished scan says, under the chip.
class _CompleteTexts extends StatelessWidget {
  const _CompleteTexts({super.key, required this.summary});

  final ScanChipSummary summary;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: child),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          children: [
            Text('Scan complete', style: textTheme.titleMedium),
            const SizedBox(height: 2),
            TweenAnimationBuilder<int>(
              tween: IntTween(begin: 0, end: summary.indexed),
              duration: const Duration(milliseconds: 1400),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => Text(
                '$v indexed and searchable',
                style: textTheme.bodyMedium?.copyWith(color: AppColors.ink80),
              ),
            ),
            if (summary.people > 0) ...[
              const SizedBox(height: 2),
              Text(
                '${summary.people} ${summary.people == 1 ? 'person' : 'people'} found',
                style: textTheme.bodySmall?.copyWith(
                  color: orbitFaceAccent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (summary.failed > 0) ...[
              const SizedBox(height: 2),
              Text(
                "${summary.failed} couldn't be read",
                style: textTheme.bodySmall?.copyWith(color: AppColors.ink48),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- geometry

// The part of the photo that is the face, as a square, in the photo's own pixels.
Rect _faceCrop(_Pic pic, FaceEvent e) {
  final b = e.box.length == 4 ? e.box : const [.3, .3, .7, .7];
  final cx = (b[0] + b[2]) / 2 * pic.w, cy = (b[1] + b[3]) / 2 * pic.h;
  var side = math.max((b[2] - b[0]) * pic.w, (b[3] - b[1]) * pic.h) * 1.35;
  final shortSide = math.min(pic.w, pic.h);
  side = side.clamp(math.min(8.0, shortSide), shortSide);
  final left = (cx - side / 2).clamp(0.0, pic.w - side);
  final top = (cy - side / 2).clamp(0.0, pic.h - side);
  return Rect.fromLTWH(left, top, side, side);
}

// ----------------------------------------------------------------- painter

class _SquarePainter extends CustomPainter {
  _SquarePainter({
    required this.scene,
    required Listenable repaint,
    required this.progress,
    required this.indeterminate,
    required this.faceAmount,
    required this.faceProgress,
    required this.faceIndeterminate,
  }) : super(repaint: repaint);

  final _SquareScanHeroState scene;
  final double progress;
  final bool indeterminate;
  final double faceAmount;
  final double faceProgress;
  final bool faceIndeterminate;

  Canvas get _c => _canvas!;
  Canvas? _canvas;

  @override
  void paint(Canvas canvas, Size size) {
    _canvas = canvas;
    canvas.save();
    canvas.scale(size.width / _sheet);
    final now = scene._now;

    final scan = scene._scanAmt, done = scene._doneAmt;
    // The board, and the bond wires that are the loading of the scan.
    paintChipBoard(canvas);
    // With the lid on, everything under it is hidden (it covers the die, the bank and the wires
    // with room to spare, even when pressed), so none of it is drawn.
    if (scene._lid > 0 || scan > .01) {
      _wires(now);
      // The die and the memory bank, with everything that happens on them, a little smaller than
      // the board so it has parts of its own round it.
      canvas.save();
      canvas.translate(chipSheet / 2, chipSheet / 2);
      canvas.scale(chipDieScale);
      canvas.translate(-chipSheet / 2, -chipSheet / 2);
      paintChipDie(canvas, _photoBox, scene._dieColumns);
      paintChipMemory(canvas, _strip);

      // What is on the die.
      if (scan > .01) {
        _withAlpha(scan, () {
          if (scene.widget.faceMode) {
            _faces(now);
          } else {
            _index(now);
          }
        });
      }

      canvas.restore();
    }

    // The steel lid, over all of it (and off it while scanning).
    paintChipLid(
      canvas,
      open: scene._lid,
      now: now,
      pressed: scene._pressed,
      idle: scene._lidIdle,
      done: scene._lidDone,
      doneAmt: done,
      tilt: scene._tilt,
      tiltLive: scene._tiltLive,
    );
    canvas.restore();
    _canvas = null;
  }

  // Draws [body] at [alpha] (as one picture, so overlapping parts do not show through).
  void _withAlpha(double alpha, void Function() body) {
    if (alpha >= .99) {
      body();
      return;
    }
    _c.saveLayer(
      const Rect.fromLTWH(0, 0, _sheet, _sheet),
      Paint()..color = Colors.white.withValues(alpha: alpha.clamp(0.0, 1.0)),
    );
    body();
    _c.restore();
  }

  // ---- the lanes ----

  // The loading of the scan: two rows of lanes between the die (top, gold, CLIP) or the memory
  // bank (bottom, copper, FACE) and the board. They are brought up one after another with the
  // scan. The one coming up trains (a pattern runs up and down it), a lane that has just locked
  // flashes along its length, and packets of data run along the lanes that are up.
  void _wires(double now) {
    const gold = Color(0xFFE9C65C);
    const copper = Color(0xFFD98F5E);
    final scene = this.scene;
    for (var bar = 0; bar < 2; bar++) {
      final training = scene._training[bar];
      final fraction = scene._trainFraction[bar];
      final wires = bar == 0 ? scene._wireClip : scene._wireFace;
      paintChipLanes(
        _c,
        bar,
        color: bar == 0 ? gold : copper,
        alpha: bar == 0 ? scene._clipAlpha : scene._faceAlpha,
        level: (i) {
          if (i == training) {
            // Coming up: it brightens as more of it is done, and flickers as it trains.
            return (.25 + .5 * fraction + .15 * math.sin(now * 24)).clamp(0.0, 1.0);
          }
          return wires[i];
        },
      );
      // A lane that has just locked: a bright flash runs along it from the die to the board.
      for (var i = 0; i < chipWireCount; i++) {
        final age = now - scene._lockAt[bar][i];
        if (age < 0 || age > .5) continue;
        final f = age / .5;
        _c.drawPath(
          chipLaneSegment(bar, i, f - .35, f),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.8
            ..strokeCap = StrokeCap.round
            ..color = Colors.white.withValues(alpha: .9 * (1 - f * .6)),
        );
      }
      // The lane being trained: a short bright pattern running up it and down again.
      if (training >= 0) {
        for (var k = 0; k < 2; k++) {
          final f = ((now * 1.5 + k * .5) % 1);
          final pos = chipLanePoint(bar, training, f);
          _c.drawCircle(pos, 3.2, Paint()..color = Colors.white.withValues(alpha: .22));
          _c.drawCircle(pos, 1.4, Paint()..color = Colors.white.withValues(alpha: .85));
        }
      }
    }
    _packetsOnLanes();
  }

  // A packet is a short bright dash running along its lane from the die (or the bank) to the
  // board, leaving the lane lit behind it.
  void _packetsOnLanes() {
    final c = _c;
    for (final packet in scene._packets) {
      final t = packet.t.clamp(0.0, 1.0);
      final color = packet.bar == 0 ? const Color(0xFFFFF1B8) : const Color(0xFFFFD2B0);
      final fade = packet.t > 1 ? 1 - (packet.t - 1) / .1 : 1.0;
      c.drawPath(
        chipLaneSegment(packet.bar, packet.wire, t - .2, t),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: .55 * fade),
      );
      final b = chipLanePoint(packet.bar, packet.wire, t);
      c.drawCircle(b, 3.4, Paint()..color = color.withValues(alpha: .25 * fade));
      c.drawCircle(b, 1.5, Paint()..color = Colors.white.withValues(alpha: .95 * fade));
    }
  }

  // The memory array along the top of the bank: a cell is written for every bit of the scan
  // that has been stored. The cell being written next pulses, and the ones just written flash.
  void _memoryCells(double now) {
    final c = _c;
    const cols = _memoryCellCount ~/ 2;
    const left = 8.0;
    final pitch = (_strip.width - 2 * left) / cols;
    final written = scene._cellsWritten;
    final dim = Paint()..color = Colors.white.withValues(alpha: .1);
    final lit = Paint()..color = _glow.withValues(alpha: .8);
    for (var k = 0; k < _memoryCellCount; k++) {
      final row = k ~/ cols, col = k % cols;
      final cell = Rect.fromLTWH(
        _strip.left + left + col * pitch + .5,
        _strip.top + 2.2 + row * 3.8,
        pitch - 1.1,
        2.6,
      );
      c.drawRRect(RRect.fromRectAndRadius(cell, const Radius.circular(.6)), k < written ? lit : dim);
      final at = scene._cellWrittenAt[k];
      if (at != null) {
        final f = (now - at) / .8;
        c.drawRRect(
          RRect.fromRectAndRadius(cell.inflate(1.2 * (1 - f)), const Radius.circular(1)),
          Paint()..color = Colors.white.withValues(alpha: .9 * (1 - f)),
        );
      }
    }
    if (written < _memoryCellCount && scene._scanAmt > .5) {
      final row = written ~/ cols, col = written % cols;
      final cell = Rect.fromLTWH(_strip.left + left + col * pitch + .5, _strip.top + 2.2 + row * 3.8, pitch - 1.1, 2.6);
      c.drawRRect(
        RRect.fromRectAndRadius(cell.inflate(.8), const Radius.circular(1)),
        Paint()..color = _glow.withValues(alpha: .25 + .55 * (.5 + .5 * math.sin(now * 9))),
      );
    }
  }

  // ---- helpers ----

  Paint _imagePaint(double alpha) =>
      Paint()..color = Colors.white.withValues(alpha: alpha.clamp(0.0, 1.0));

  void _text(
    String text,
    Offset center,
    double size,
    Color color, {
    FontWeight weight = FontWeight.w600,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: size, color: color, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(_c, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _thumb(_Pic pic, Rect slot, double alpha) {
    final c = _c;
    final side = math.min(pic.w, pic.h);
    final src = Rect.fromCenter(
      center: Offset(pic.w / 2, pic.h / 2),
      width: side,
      height: side,
    );
    c.save();
    c.clipRRect(RRect.fromRectAndRadius(slot, const Radius.circular(6)));
    c.drawImageRect(pic.image, src, slot, _imagePaint(alpha));
    c.restore();
    c.drawRRect(
      RRect.fromRectAndRadius(slot, const Radius.circular(6)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: alpha),
    );
  }

  Rect _tileRect(double x) => Rect.fromLTWH(x, _strip.top + 11, _tileSize, _tileSize);

  // The strip: the photos waiting for their faces (the FACE bar fills as the queue does).
  void _queueStrip(double now) {
    final loadStart = scene._loadStart[0];
    if (loadStart >= 0) _memoryWeights(now, ((now - loadStart) / _loadSeconds).clamp(0.0, 1.0), _glow, 1);
    _memoryCells(now);
    for (final tile in scene._queue) {
      _thumb(tile.pic, _tileRect(tile.x), 1);
    }
  }

  // The data bus between the die and the memory bank: a row of fine lines, lit while a picture
  // goes down into memory.
  void _bus(double now, double energy) {
    final c = _c;
    final y0 = _photoBox.bottom + 3.4, y1 = _strip.top - 0.5;
    for (var i = 0; i < 7; i++) {
      final x = _strip.left + 6 + 17 + i * 38;
      c.drawLine(Offset(x, y0), Offset(x, y1), Paint()..strokeWidth = 1.4..color = const Color(0xFFD6B85A).withValues(alpha: .35));
      if (energy > .02) {
        // A short run of light, starting a little apart on each line.
        final f = ((now * 2.2 + i * .17) % 1);
        final yy = y0 + (y1 - y0) * f;
        c.drawLine(
          Offset(x, yy),
          Offset(x, math.min(y1, yy + 3.5)),
          Paint()
            ..strokeWidth = 1.8
            ..strokeCap = StrokeCap.round
            ..color = _glow.withValues(alpha: .95 * energy),
        );
      }
    }
  }

  // ---- waiting ----

  // The light of things working on the dark die.
  static const Color _glow = Color(0xFF7FE3CC);

  static final Map<int, List<Rect>> _blockCache = {};
  List<Rect> get _blocks => _blockCache.putIfAbsent(scene._dieColumns, () => chipDieBlocks(_photoBox, scene._dieColumns));

  // While the folder is still being walked: the chip powers up, block by block, the way a real
  // processor does: the clock generator and the power management first, then the memory
  // controller and its interface, the fabric, the shared cache, the cores one after another and
  // last the outside interfaces. The more files have been found, the more of it is awake. A
  // block that has just come on flashes and then settles to a working glow that flickers a
  // little, as parts of it switch. What lights is the die's own structure (its memory cells,
  // its logic, its registers), so the light is coming from inside the silicon.
  void _discovering(double now, int? found) {
    final unit = found != null ? found / 10.0 : (now - scene._scanAt) * 1.2;
    final regions = <(Rect, double)>[];
    for (var i = 0; i < _blocks.length; i++) {
      final on = _ease((unit - i).clamp(0.0, 1.0));
      if (on <= 0) continue;
      final settled = unit - i - 1;
      final flash = settled < 0 ? 0.0 : math.max(0.0, 1 - settled / 1.2);
      final activity = .5 + .2 * math.sin(now * (1.7 + i * .29) + i * 1.9) + .1 * math.sin(now * 7.3 + i * 3.1);
      regions.add((_blocks[i], (on * (activity + .5 * flash)).clamp(0.0, 1.0)));
    }
    paintChipDieLit(_c, _photoBox, scene._dieColumns, regions, _glow);
  }

  // How long the model takes to be loaded in the picture (the chip's part of the story).
  static const double _loadSeconds = 4.6;

  // Where the chips of the memory bank are (one under each place a picture lands).
  Rect _memoryChip(int k) => Rect.fromLTWH(_strip.left + 6 + k * 38, _strip.top + 11, 34, 34);

  static int _hash(int a) {
    a = (a ^ 61) ^ (a >> 16);
    a *= 9;
    a ^= a >> 4;
    a *= 0x27d4eb2d;
    a ^= a >> 15;
    return a & 0x7fffffff;
  }

  // The model, as it lands in memory: chip after chip of the bank fills with rows of data, from
  // the top down, the newest row bright. When it is all in, the data stays, dimmer: the model is
  // in memory.
  void _memoryWeights(double now, double f, Color color, double alpha) {
    // Once it is all in, the data does not change: it is one picture, not hundreds of rectangles
    // every frame.
    if (f >= 1 && alpha == 1 && color == _glow) {
      paintChipCached(_c, 'weights', _strip.inflate(4), (canvas) {
        final saved = _canvas;
        _canvas = canvas;
        _drawWeights(1, color, 1);
        _canvas = saved;
      });
      return;
    }
    _drawWeights(f, color, alpha);
  }

  void _drawWeights(double f, Color color, double alpha) {
    final c = _c;
    final settle = _ease(_seg(f, .94, 1.0));
    final paint = Paint();
    for (var k = 0; k < 7; k++) {
      final u = (f * 7.4 - k * .9).clamp(0.0, 1.0);
      if (u <= 0) continue;
      final chip = _memoryChip(k);
      final inner = chip.deflate(3.2);
      const rows = 12;
      final rowH = inner.height / rows;
      final level = (1 - .6 * settle) * alpha;
      final head = u * rows;
      for (var r = 0; r < rows && r < head + 1; r++) {
        var x = inner.left;
        var h = _hash(k * 131 + r * 17 + 5);
        final newest = r + 1 > head && u < 1;
        while (x < inner.right - .5) {
          h = _hash(h + 7);
          final w = 2.0 + h % 7;
          final shade = .4 + .5 * ((h >> 8) % 100) / 100;
          paint.color = (newest ? Colors.white : color).withValues(alpha: (newest ? .95 : shade) * level);
          c.drawRect(Rect.fromLTWH(x, inner.top + r * rowH + .3, math.min(w, inner.right - x), rowH - .8), paint);
          x += w + 1 + (h >> 4) % 2;
        }
      }
      c.drawRRect(
        RRect.fromRectAndRadius(chip.deflate(.6), const Radius.circular(4)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: (u < 1 ? .7 : .25) * alpha),
      );
    }
  }

  // The data going up from the memory into the die while the model loads: a run of light up each
  // line of the bus, from every chip of the bank that has begun to fill.
  void _busUp(double now, double f, Color color, double alpha) {
    final c = _c;
    final y0 = _photoBox.bottom + 3.4, y1 = _strip.top - 0.5;
    for (var i = 0; i < 7; i++) {
      if (f * 7.4 - i * .9 <= 0) continue;
      final x = _strip.left + 6 + 17 + i * 38;
      for (var k = 0; k < 2; k++) {
        final p = (now * 1.9 + i * .23 + k * .5) % 1;
        final yy = y1 - (y1 - y0) * p;
        c.drawLine(
          Offset(x, yy),
          Offset(x, math.min(y1, yy + 4)),
          Paint()
            ..strokeWidth = 1.9
            ..strokeCap = StrokeCap.round
            ..color = color.withValues(alpha: .95 * alpha),
        );
      }
    }
  }

  // The chip with nothing to read yet. The first time, the model is being loaded into memory:
  // it comes from the bank, up the bus, into the die, where the shared cache and then each core
  // fill from the top down with a bright edge. After that the chip waits for the next picture
  // with a quiet glow, as a loaded processor idles.
  void _waiting(double now, Color color, double alpha, {int kind = 0}) {
    if (alpha <= .01) return;
    final c = _c;
    if (scene._loadStart[kind] < 0) scene._loadStart[kind] = now;
    final f = ((now - scene._loadStart[kind]) / _loadSeconds).clamp(0.0, 1.0);
    final standby = .3 + .1 * math.sin(now * 1.3);
    final regions = <(Rect, double)>[];
    final blocks = _blocks;
    final (workFrom, workCount) = chipDieWorkRange(scene._dieColumns);
    for (var i = 0; i < blocks.length; i++) {
      final activity = .8 + .2 * math.sin(now * (1.5 + i * .31) + i * 2.1);
      // The shared cache and the cores are what the model is loaded into.
      final j = i - workFrom;
      final receiving = j >= 0 && j < workCount;
      final s = receiving ? (f * (workCount + .5) - j).clamp(0.0, 1.0) : 1.0;
      final idle = (receiving ? standby * activity : (.4 + .2 * (1 - f)) * activity) * alpha;
      regions.add((blocks[i], idle));
      if (receiving && s > 0 && s < 1) {
        final r = blocks[i];
        regions.add((Rect.fromLTRB(r.left, r.top, r.right, r.top + r.height * s), .9 * alpha));
        c.drawLine(
          Offset(r.left + 1, r.top + r.height * s),
          Offset(r.right - 1, r.top + r.height * s),
          Paint()
            ..strokeWidth = 1.2
            ..color = Colors.white.withValues(alpha: .85 * alpha),
        );
      } else if (receiving && s >= 1 && f < 1) {
        regions.add((blocks[i], .6 * alpha));
      }
    }
    paintChipDieLit(c, _photoBox, scene._dieColumns, regions, color);
    if (f < 1) _busUp(now, f, color, alpha);
    if (kind != 0) _memoryWeights(now, f, color, alpha);
  }

  // The corners of a square, like the frame of a viewfinder.
  void _brackets(Rect r, double alpha, bool small, {Color color = Colors.white}) {
    if (alpha <= .01) return;
    final len = r.width * .15;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = small ? 1.4 : 2
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: alpha.clamp(0.0, 1.0));
    for (final sx in [-1.0, 1.0]) {
      for (final sy in [-1.0, 1.0]) {
        final corner = Offset(sx < 0 ? r.left : r.right, sy < 0 ? r.top : r.bottom);
        _c.drawPath(
          Path()
            ..moveTo(corner.dx - sx * len, corner.dy)
            ..lineTo(corner.dx, corner.dy)
            ..lineTo(corner.dx, corner.dy - sy * len),
          p,
        );
      }
    }
  }

  // ---- indexing: the photos read together, then queued for their faces ----

  void _index(double now) {
    _queueStrip(now);

    final shot = scene._shot;
    if (shot == null) {
      // Nothing to show yet: the frame waits, or - while the folder is still being walked -
      // looks for photos.
      if (indeterminate) {
        _discovering(now, scene.widget.discovered);
      } else {
        _waiting(now, _glow, _ease(_seg(now - scene._idleSince, .3, .9)));
      }
      return;
    }
    final n = shot.pics.length;
    final t = scene._still ? .6 : ((now - shot.start) / shot.cycle).clamp(0.0, 1.0);
    final cells = _bentoCells(n, shot.layout);
    // The bus carries the vectors down into memory as the pictures land.
    final stagger0 = n > 1 ? .05 : 0.0;
    var energy = 0.0;
    for (var i = 0; i < n; i++) {
      final u = ((t - stagger0 * i) / (1 - stagger0 * (n - 1))).clamp(0.0, 1.0);
      energy = math.max(energy, math.sin(math.pi * _seg(u, .85, .99)));
    }
    _bus(now, energy);
    // They are read side by side, each starting a little after the one before.
    final stagger = n > 1 ? .05 : 0.0;
    final span = 1 - stagger * (n - 1);
    for (var i = 0; i < n; i++) {
      final u = ((t - stagger * i) / span).clamp(0.0, 1.0);
      _readOne(shot.pics[i], cells[i], u, _tileRect(scene.landingX(i)), n > 1, now);
    }
  }

  // Where a photo of [aspect] sits whole inside [box].
  Rect _contain(double aspect, Rect box) {
    return aspect > box.width / box.height
        ? Rect.fromCenter(center: box.center, width: box.width, height: box.width / aspect)
        : Rect.fromCenter(center: box.center, width: box.height * aspect, height: box.height);
  }

  // One photo of the round, the way the model reads it: the photo is shown whole and cut to its
  // middle square (the model only sees a square), the square is cut into the 7 x 7 patches the
  // model reads, each patch is boiled down to a single colour (a patch becomes one number
  // vector), the patches look at each other (attention), and what comes out is one vector that
  // goes down the bus into memory while the photo itself goes to the strip.
  void _readOne(_Pic pic, Rect cell, double t, Rect slot, bool small, double now) {
    final c = _c;
    final a = _ease(_seg(t, 0, .08));
    final whole = _contain(pic.w / pic.h, cell);
    final side = math.min(whole.width, whole.height);
    final crop = Rect.fromCenter(center: whole.center, width: side, height: side);
    final workSide = math.min(cell.width, cell.height);
    final work = Rect.fromCenter(center: cell.center, width: workSide, height: workSide);
    final cut = _ease(_seg(t, .17, .27));
    final grow = _ease(_seg(t, .25, .37));
    final q = _ease(_seg(t, .88, .99));
    final square = Rect.lerp(Rect.lerp(crop, work, grow)!, slot, q)!;
    final radius = _lerp(small ? 5 : 7, 6, q);
    final squareShape = RRect.fromRectAndRadius(square, Radius.circular(radius));
    final plain = _imagePaint(a);

    // The part of the photo the model never sees dims and goes.
    if (cut < 1) {
      final dim = _ease(_seg(t, .08, .17));
      c.save();
      c.clipRect(crop, clipOp: ui.ClipOp.difference);
      c.clipRRect(RRect.fromRectAndRadius(whole, Radius.circular(radius)));
      c.drawImageRect(pic.image, Rect.fromLTWH(0, 0, pic.w, pic.h), whole, _imagePaint(a * (1 - cut)));
      c.drawRect(whole, Paint()..color = Colors.black.withValues(alpha: .55 * dim * (1 - cut) * a));
      c.restore();
    }
    // The square.
    c.save();
    c.clipRRect(squareShape);
    c.drawImageRect(pic.image, _coverSrc(pic, 1), square, plain);
    c.restore();

    final overlay = 1 - _ease(_seg(q, .5, 1));
    if (overlay <= .01) return;
    _brackets(square, _ease(_seg(t, .08, .17)) * (1 - _ease(_seg(t, .34, .42))) * overlay, small);

    // The patches pull apart, and one after another are boiled down to their average colour.
    final split = _ease(_seg(t, .36, .46)) * (1 - _ease(_seg(t, .78, .88)));
    final read = _seg(t, .46, .68) * 49;
    final mosaic = 1 - _ease(_seg(t, .76, .86));
    final tones = pic.tones;
    final cw = square.width / 7;
    if (split > .01 || (read > 0 && mosaic > .01)) {
      final src = _coverSrc(pic, 1);
      final sw = src.width / 7;
      final gap = split * (small ? .6 : 1);
      c.save();
      c.clipRRect(squareShape);
      c.drawRect(square, Paint()..color = const Color(0xFF0B1210).withValues(alpha: .55 * split * a * overlay));
      final tint = Paint();
      for (var k = 0; k < 49; k++) {
        final r = Rect.fromLTWH(square.left + (k % 7) * cw, square.top + (k ~/ 7) * cw, cw, cw);
        final inner = r.deflate(gap);
        c.drawImageRect(
          pic.image,
          Rect.fromLTWH(src.left + (k % 7) * sw, src.top + (k ~/ 7) * sw, sw, sw),
          inner,
          _imagePaint(a * overlay),
        );
        if (k < read) {
          final fresh = (1 - (read - k) / 6).clamp(0.0, 1.0);
          final base = tones?[k] ?? AppColors.primary;
          tint.color = Color.lerp(base, Colors.white, fresh * .55)!.withValues(alpha: (mosaic * a * overlay).clamp(0.0, 1.0));
          c.drawRect(inner, tint);
        }
      }
      if (read > 0 && read < 49 && overlay > .3) {
        final k = read.floor();
        c.drawRect(
          Rect.fromLTWH(square.left, square.top + (k ~/ 7) * cw, square.width, cw),
          Paint()..color = Colors.white.withValues(alpha: .1 * overlay),
        );
        c.drawRect(
          Rect.fromLTWH(square.left + (k % 7) * cw, square.top + (k ~/ 7) * cw, cw, cw).deflate(.5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = small ? 1.2 : 2
            ..color = Colors.white.withValues(alpha: overlay),
        );
      }
      c.restore();
    }

    // The patches look at each other: lines run between patches, a few at a time.
    final look = math.sin(math.pi * _seg(t, .64, .8));
    if (look > .02) {
      c.save();
      c.clipRRect(squareShape);
      final bucket = (now * 12).floor();
      final seed = pic.image.hashCode;
      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = small ? .7 : 1
        ..color = Colors.white.withValues(alpha: .6 * look * overlay);
      final dot = Paint()..color = Colors.white.withValues(alpha: .9 * look * overlay);
      Offset center(int k) => Offset(square.left + (k % 7 + .5) * cw, square.top + (k ~/ 7 + .5) * cw);
      for (var j = 0; j < (small ? 7 : 12); j++) {
        final r = math.Random(seed ^ (bucket * 31 + j * 7919));
        final p = r.nextInt(49), o = r.nextInt(49);
        if (p == o) continue;
        final from = center(p), to = center(o);
        final control = Offset.lerp((from + to) / 2, square.center, .6)!;
        c.drawPath(Path()..moveTo(from.dx, from.dy)..quadraticBezierTo(control.dx, control.dy, to.dx, to.dy), line);
        c.drawCircle(from, small ? 1.1 : 1.6, dot);
        c.drawCircle(to, small ? 1.1 : 1.6, dot);
      }
      c.restore();
    }

    // What comes out: one vector, which is a list of numbers. They appear over the lower half of
    // the square flickering (not yet worked out), then lock one after another, each flashing as
    // it does. The list rides down with the photo and is gone into memory by the time the
    // photo lands.
    final vector = _ease(_seg(t, .72, .8));
    if (vector > .01) {
      final cols = small ? 3 : 4, rows = small ? 4 : 6;
      final panel = Rect.fromLTWH(
        square.left + square.width * .06,
        square.bottom - square.height * .5 - square.height * .04,
        square.width * .88,
        square.height * .5,
      );
      final fontSize = math.max(4.6, square.width * (small ? .055 : .05));
      final fade = (vector * overlay).clamp(0.0, 1.0);
      c.save();
      c.clipRRect(squareShape);
      c.saveLayer(panel.inflate(4), Paint()..color = Colors.white.withValues(alpha: fade));
      c.drawRRect(
        RRect.fromRectAndRadius(panel, Radius.circular(small ? 3 : 5)),
        Paint()..color = Colors.black.withValues(alpha: .62),
      );
      final cellW = panel.width / cols, cellH = panel.height / rows;
      final n = cols * rows;
      final seed = pic.image.hashCode;
      final frame = (now * 16).floor();
      for (var i = 0; i < n; i++) {
        final lockAt = .76 + .11 * i / (n - 1);
        final centre = Offset(panel.left + (i % cols + .5) * cellW, panel.top + (i ~/ cols + .5) * cellH);
        if (t >= lockAt) {
          final just = t - lockAt < .025;
          _number(_signed(_vectorValue(tones, i)), centre, fontSize, just ? 2 : 1);
        } else {
          final v = (_hash(seed + i * 977 + frame * 131) % 1000) / 500 - 1;
          _number(_signed(v * .99), centre, fontSize, 0);
        }
      }
      c.restore();
      c.restore();
    }
  }

  static final Map<String, TextPainter> _numberText = {};

  // A number of the vector, centred at [at]: [look] 0 is still flickering, 1 is locked, 2 is the
  // flash as it locks.
  void _number(String text, Offset at, double size, int look) {
    final key = '$text|${size.toStringAsFixed(1)}|$look';
    var painter = _numberText[key];
    if (painter == null) {
      if (_numberText.length > 700) _numberText.clear();
      painter = _numberText[key] = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: size,
            fontWeight: FontWeight.w600,
            height: 1,
            color: switch (look) {
              0 => Colors.white.withValues(alpha: .5),
              1 => _glow,
              _ => Colors.white,
            },
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    }
    painter.paint(_c, at - Offset(painter.width / 2, painter.height / 2));
  }

  static String _signed(double v) => '${v < 0 ? '-' : '+'}${v.abs().toStringAsFixed(2)}';

  // ---- faces ----

  Offset _slotCenter(int j) => Offset(_strip.left + 6 + 17 + (j + 1) * 38, _strip.top + 11 + 17);

  void _faces(double now) {
    final c = _c;
    // The tray (on the memory bank).
    for (var j = 0; j < _traySlots; j++) {
      _bubble(j, now);
    }
    _memoryCells(now);
    _launching(now);

    final shot = scene._faceShot;
    if (shot == null) {
      _lookingForFaces(now);
      return;
    }
    final t = ((now - shot.start) / _faceCycle).clamp(0.0, 1.0);
    final dst = shot.dst; // the photo, scaled to fill the area (it may run past it)
    const area = _photoBox;
    final a = _ease(_seg(t, 0, .08)) * (1 - _ease(_seg(t, .92, .98)));
    Offset at(double fx, double fy) =>
        Offset(dst.left + fx * dst.width, dst.top + fy * dst.height);
    Rect boxOf(FaceEvent e) {
      final b = e.box;
      final p = at(b[0], b[1]), q = at(b[2], b[3]);
      return Rect.fromPoints(p, q);
    }

    double lift(int i) => _ease(_seg(t, .42 + .03 * i, .5 + .03 * i));

    // The photo, dimmed except around the faces still in it.
    if (a > 0.001) {
      c.save();
      c.clipRRect(RRect.fromRectAndRadius(area, const Radius.circular(14)));
      c.drawImageRect(
        shot.pic.image,
        Rect.fromLTWH(0, 0, shot.pic.w, shot.pic.h),
        dst,
        _imagePaint(a),
      );
      final dim = .5 * _ease(_seg(t, .12, .26));
      if (dim > 0) {
        final path = Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(area);
        for (var i = 0; i < shot.faces.length; i++) {
          if (lift(i) < .5) {
            path.addRRect(
              RRect.fromRectAndRadius(
                boxOf(shot.faces[i].event).inflate(4),
                const Radius.circular(10),
              ),
            );
          }
        }
        c.drawPath(
          path,
          Paint()..color = const Color(0xFF181234).withValues(alpha: dim * a),
        );
      }
      for (var i = 0; i < shot.faces.length; i++) {
        final e = shot.faces[i].event;
        final box = boxOf(e).inflate(3);
        final l = lift(i);
        final centre = box.center;
        final rad = math.max(box.width, box.height) * .7;
        if (l > 0) {
          // The hole where the face was lifted out.
          c.drawCircle(
            centre,
            rad,
            Paint()
              ..shader = ui.Gradient.radial(centre, rad, [
                const Color(0xFF70689E).withValues(alpha: .97 * l * a),
                const Color(0xFF70689E).withValues(alpha: .95 * l * a),
                const Color(0xFF70689E).withValues(alpha: 0),
              ], [0, .72, 1]),
          );
        }
        final bp = _ease(_seg(t, .1 + .05 * i, .24 + .05 * i));
        if (bp > 0 && l < .5) {
          final al = (1 - l * 2) * a;
          final len = math.min(box.width, box.height) * .3 * bp + 3;
          final stroke = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeCap = StrokeCap.round
            ..color = Colors.white.withValues(alpha: al);
          for (final corner in [
            (box.topLeft, 1.0, 1.0),
            (box.topRight, -1.0, 1.0),
            (box.bottomLeft, 1.0, -1.0),
            (box.bottomRight, -1.0, -1.0),
          ]) {
            final p = corner.$1;
            c.drawPath(
              Path()
                ..moveTo(p.dx + corner.$2 * len, p.dy)
                ..lineTo(p.dx, p.dy)
                ..lineTo(p.dx, p.dy + corner.$3 * len),
              stroke,
            );
          }
          final la = _ease(_seg(t, .2 + .05 * i, .27 + .05 * i));
          final pill = RRect.fromRectAndRadius(
            Rect.fromLTWH(box.left, box.top - 17, 32, 14),
            const Radius.circular(7),
          );
          c.drawRRect(
            pill,
            Paint()..color = orbitFaceAccent.withValues(alpha: al * la),
          );
          if (al * la > .01) {
            _text(
              e.score.toStringAsFixed(2),
              pill.outerRect.center,
              9,
              Colors.white.withValues(alpha: al * la),
            );
          }
          if (e.landmarks.length >= 10) {
            _mesh(e, at, _ease(_seg(t, .33 + .03 * i, .42 + .03 * i)), al);
            for (var j = 0; j < 5; j++) {
              final s = _back(_seg(t, .27 + j * .014 + .03 * i, .32 + j * .014 + .03 * i));
              if (s <= 0) continue;
              final p = at(e.landmarks[j * 2], e.landmarks[j * 2 + 1]);
              final r = 2.6 * math.max(0.0, s);
              c.drawCircle(p, r, Paint()..color = Colors.white.withValues(alpha: al));
              c.drawCircle(
                p,
                r,
                Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.6
                  ..color = orbitFaceAccent.withValues(alpha: al),
              );
            }
          }
        }
      }
      c.restore();
    }

    // Lifted faces, the way the app really treats them: cut out as a square, straightened onto the
    // standard 112 x 112 template (its landmarks moved onto the template's marks), checked for how
    // far the head is turned, and sent to the tray (the square rounds into the person's circle).
    for (var i = 0; i < shot.faces.length; i++) {
      final face = shot.faces[i];
      final e = face.event;
      final l = lift(i);
      if (l <= 0) continue;
      final box = boxOf(e);
      final tr = _ease(_seg(t, .68 + .03 * i, .84 + .03 * i));
      if (tr > .97) continue;
      final end = _slotCenter(face.slot);
      final start = box.center;
      final pos = Offset(
        _lerp(start.dx, end.dx, tr),
        _lerp(start.dy, end.dy, tr) - math.sin(tr * math.pi) * 24,
      );
      final baseR = (math.max(box.width, box.height) / 2 * 1.05).clamp(12.0, 46.0);
      final full = (baseR * 2.3).clamp(52.0, 92.0);
      final side = _lerp(_lerp(baseR * 2, full, l), 31.0, tr);
      if (face.matched && tr > 0 && tr < 1) {
        _dashed(pos, end, orbitFaceAccent.withValues(alpha: .55 * math.sin(tr * math.pi)));
      }
      _alignedFace(
        shot.pic,
        e,
        pos,
        side,
        l: l,
        straighten: _ease(_seg(t, .5 + .03 * i, .62 + .03 * i)),
        gauge: _ease(_seg(t, .56 + .03 * i, .62 + .03 * i)),
        needle: _ease(_seg(t, .6 + .03 * i, .68 + .03 * i)),
        travel: tr,
      );
    }
  }

  // ArcFace's reference landmarks on a 112 x 112 face (what the app's FaceAligner moves every
  // face onto): left eye, right eye, nose tip, left and right mouth corner.
  static const List<Offset> _template = [
    Offset(38.2946, 51.6963),
    Offset(73.5318, 51.5014),
    Offset(56.0252, 71.7366),
    Offset(41.5493, 92.3655),
    Offset(70.7299, 92.2041),
  ];

  // How far the nose sits off the line between the eyes, as a fraction of the eye distance and
  // signed (the app's FaceQuality.yaw, which only keeps its size): about 0 facing the camera, 0.3
  // at 45 degrees, 0.6 or more in profile. Faces turned more than 0.55 are not matched.
  static double _signedYaw(List<Offset> lm) {
    final d = lm[1] - lm[0];
    final eye = d.distance;
    if (eye <= 0) return 1;
    final mid = (lm[0] + lm[1]) / 2;
    final offset = ((lm[2].dx - mid.dx) * d.dx + (lm[2].dy - mid.dy) * d.dy) / eye;
    return offset / eye;
  }

  // One face in its square frame of [side] centred at [centre]. [straighten] (0..1) turns it from
  // the plain crop onto the template, by the same least-squares rotate, scale and shift the app's
  // FaceAligner uses; [gauge] reveals the head-turn gauge under it and [needle] swings its needle
  // to this face's turn; [travel] rounds the square into a circle as it goes to the tray.
  void _alignedFace(
    _Pic pic,
    FaceEvent e,
    Offset centre,
    double side, {
    required double l,
    required double straighten,
    required double gauge,
    required double needle,
    required double travel,
  }) {
    final c = _c;
    final k = side / 112;
    final frame = Rect.fromCenter(center: centre, width: side, height: side);
    final shape = RRect.fromRectAndRadius(frame, Radius.circular(_lerp(5, side / 2, travel)));
    final calm = 1 - travel;
    c.drawRRect(shape.shift(const Offset(0, 2)).inflate(1), Paint()..color = const Color(0xFF1E1446).withValues(alpha: .22 * calm));
    c.drawRRect(shape.shift(const Offset(0, 4)).inflate(2), Paint()..color = const Color(0xFF1E1446).withValues(alpha: .1 * calm));
    c.drawRRect(shape, Paint()..color = const Color(0xFF181234));

    // The landmarks in the photo's pixels, and the transform that lands them on the template.
    final lm = [
      for (var j = 0; j < 5; j++) Offset(e.landmarks[j * 2] * pic.w, e.landmarks[j * 2 + 1] * pic.h),
    ];
    var smx = 0.0, smy = 0.0, dmx = 0.0, dmy = 0.0;
    for (var j = 0; j < 5; j++) {
      smx += lm[j].dx;
      smy += lm[j].dy;
      dmx += _template[j].dx * k;
      dmy += _template[j].dy * k;
    }
    smx /= 5;
    smy /= 5;
    dmx /= 5;
    dmy /= 5;
    var dot = 0.0, cross = 0.0, norm = 0.0;
    for (var j = 0; j < 5; j++) {
      final sx = lm[j].dx - smx, sy = lm[j].dy - smy;
      final dx = _template[j].dx * k - dmx, dy = _template[j].dy * k - dmy;
      dot += sx * dx + sy * dy;
      cross += sx * dy - sy * dx;
      norm += sx * sx + sy * sy;
    }
    final a = norm > 0 ? dot / norm : 1.0, b = norm > 0 ? cross / norm : 0.0;
    final scaleEnd = math.max(math.sqrt(a * a + b * b), 1e-3), angleEnd = math.atan2(b, a);

    // From the plain crop (no turn) to the template, about the middle of the landmarks.
    final crop = _faceCrop(pic, e);
    final scaleStart = side / crop.width;
    final centreStart = (Offset(smx, smy) - crop.center) * scaleStart + Offset(side / 2, side / 2);
    final scale = scaleStart * math.pow(scaleEnd / scaleStart, straighten);
    final angle = angleEnd * straighten;
    final at = Offset.lerp(centreStart, Offset(dmx, dmy), straighten)!;

    c.save();
    c.clipRRect(shape);
    c.translate(frame.left + at.dx, frame.top + at.dy);
    c.rotate(angle);
    c.scale(scale.toDouble());
    c.translate(-smx, -smy);
    c.drawImage(pic.image, Offset.zero, Paint()..filterQuality = FilterQuality.medium);
    c.restore();

    final shown = (l * (1 - travel * 2)).clamp(0.0, 1.0);
    if (shown > .01) {
      // The eye line of the template, the marks the landmarks are moved onto, and the landmarks.
      c.save();
      c.clipRRect(shape);
      c.drawLine(
        Offset(frame.left, frame.top + _template[0].dy * k),
        Offset(frame.right, frame.top + _template[0].dy * k),
        Paint()
          ..strokeWidth = .8
          ..color = Colors.white.withValues(alpha: .4 * shown),
      );
      final locked = _seg(straighten, .88, 1);
      final mark = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = orbitFaceAccent.withValues(alpha: shown);
      final dotPaint = Paint();
      final turn = Offset(math.cos(angle), math.sin(angle)) * scale.toDouble();
      for (var j = 0; j < 5; j++) {
        final target = frame.topLeft + _template[j] * k;
        c.drawCircle(target, 2.6, mark);
        if (locked > 0) {
          c.drawCircle(target, 2.6 * locked, dotPaint..color = Colors.white.withValues(alpha: .9 * locked * shown));
        }
        final d = lm[j] - Offset(smx, smy);
        final p = frame.topLeft + at + Offset(d.dx * turn.dx - d.dy * turn.dy, d.dx * turn.dy + d.dy * turn.dx);
        c.drawCircle(p, 1.7, dotPaint..color = Colors.white.withValues(alpha: shown));
        c.drawCircle(p, 1.7, mark..strokeWidth = 1.2);
      }
      c.restore();
    }
    c.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = Colors.white.withValues(alpha: .95),
    );

    // The head-turn gauge: the track runs from a turn of -1 to +1 (as a fraction of the eye
    // distance), the violet part is the turn that is accepted for matching, and the needle shows
    // this face's turn.
    final gaugeShown = gauge * (1 - travel * 2).clamp(0.0, 1.0);
    if (gaugeShown > .01) {
      final half = side * .46 * gauge;
      final y = frame.bottom + 7;
      final yaw = _signedYaw(lm).clamp(-1.0, 1.0);
      final centreX = centre.dx;
      c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(centreX - half, y, centreX + half, y + 4), const Radius.circular(2)),
        Paint()..color = Colors.white.withValues(alpha: .28 * gaugeShown),
      );
      c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(centreX - half * .55, y, centreX + half * .55, y + 4), const Radius.circular(2)),
        Paint()..color = orbitFaceAccent.withValues(alpha: .9 * gaugeShown),
      );
      c.drawLine(
        Offset(centreX, y - 1),
        Offset(centreX, y + 5),
        Paint()
          ..strokeWidth = .8
          ..color = Colors.white.withValues(alpha: .7 * gaugeShown),
      );
      final x = centreX + yaw * half * needle;
      c.drawPath(
        Path()
          ..moveTo(x, y + 4.6)
          ..lineTo(x - 2.6, y + 9.4)
          ..lineTo(x + 2.6, y + 9.4)
          ..close(),
        Paint()..color = Colors.white.withValues(alpha: gaugeShown),
      );
    }
  }

  // The 5 landmarks joined into a small mesh over the face, just before it is lifted out.
  void _mesh(FaceEvent e, Offset Function(double, double) at, double grow, double alpha) {
    if (grow <= 0) return;
    final c = _c;
    final p = [for (var j = 0; j < 5; j++) at(e.landmarks[j * 2], e.landmarks[j * 2 + 1])];
    // Eyes, nose, mouth corners (left eye 0, right eye 1, nose 2, mouth 3 and 4).
    final fill = Path()
      ..moveTo(p[0].dx, p[0].dy)
      ..lineTo(p[1].dx, p[1].dy)
      ..lineTo(p[2].dx, p[2].dy)
      ..close()
      ..moveTo(p[2].dx, p[2].dy)
      ..lineTo(p[3].dx, p[3].dy)
      ..lineTo(p[4].dx, p[4].dy)
      ..close();
    c.drawPath(fill, Paint()..color = orbitFaceAccent.withValues(alpha: .22 * grow * alpha));
    final line = Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: .85 * alpha);
    for (final edge in const [
      [0, 1], [0, 2], [1, 2], [2, 3], [2, 4], [3, 4], [0, 3], [1, 4],
    ]) {
      c.drawLine(p[edge[0]], Offset.lerp(p[edge[0]], p[edge[1]], grow)!, line);
    }
  }

  // The strip's photos rising into the square when a batch starts.
  void _launching(double now) {
    final tiles = scene._launch;
    if (tiles.isEmpty) return;
    final age = now - scene._launchAt;
    for (var i = 0; i < tiles.length; i++) {
      final u = _ease(_seg(age - i * .05, 0, .7));
      if (u >= 1) continue;
      final from = Rect.fromLTWH(tiles[i].x, _strip.top + 11, _tileSize, _tileSize);
      final to = _photoBox.center + Offset((i % 5 - 2) * 10.0, (i ~/ 5 - 1) * 8.0);
      final size = _tileSize * (1 - .55 * u);
      final rect = Rect.fromCenter(
        center: Offset.lerp(from.center, to, u)!,
        width: size,
        height: size,
      );
      _thumb(tiles[i].pic, rect, 1 - u);
    }
  }

  // While no photo with faces is being shown: the batch's photos go by under a scan line.
  void _lookingForFaces(double now) {
    final history = scene._batchPics;
    if (history.isEmpty) {
      _waiting(now, orbitFaceAccent, 1, kind: 1);
      return;
    }
    final pic = history[(now / 1.3).floor() % history.length];
    final dst = _photoBox;
    final f = (now / 1.3) % 1;
    final c = _c;
    c.save();
    c.clipRRect(RRect.fromRectAndRadius(dst, const Radius.circular(14)));
    c.drawImageRect(
      pic.image,
      _coverSrc(pic, dst.width / dst.height),
      dst,
      _imagePaint(.55),
    );
    final y = dst.top + dst.height * f;
    c.drawRect(
      Rect.fromLTRB(dst.left, y - 18, dst.right, y),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, y - 18),
          Offset(0, y),
          [orbitFaceAccent.withValues(alpha: 0), orbitFaceAccent.withValues(alpha: .35)],
        ),
    );
    c.drawLine(
      Offset(dst.left, y),
      Offset(dst.right, y),
      Paint()
        ..strokeWidth = 2
        ..color = orbitFaceAccent,
    );
    c.restore();
  }

  void _dashed(Offset from, Offset to, Color color) {
    final paint = Paint()
      ..strokeWidth = 1.6
      ..color = color;
    final d = to - from;
    final n = (d.distance / 8).floor();
    for (var k = 0; k < n; k += 2) {
      _c.drawLine(from + d * (k / n), from + d * ((k + 1) / n), paint);
    }
  }

  void _crop(_Pic pic, Rect src, Offset center, double r, double alpha) {
    final c = _c;
    c.save();
    c.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
    c.drawImageRect(pic.image, src, Rect.fromCircle(center: center, radius: r), _imagePaint(alpha));
    c.restore();
  }

  void _bubble(int j, double now) {
    final c = _c;
    final centre = _slotCenter(j);
    final p = scene._tray[j];
    if (p == null) {
      c.drawCircle(
        centre,
        16.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..color = Colors.white.withValues(alpha: .2),
      );
      return;
    }
    final age = now - p.bornAt;
    final pop = p.isNew || age < .4 ? math.max(.01, _back(_seg(age, 0, .4))) : 1.0;
    c.save();
    c.translate(centre.dx, centre.dy);
    c.scale(pop);
    c.translate(-centre.dx, -centre.dy);
    c.drawCircle(centre, 17, Paint()..color = Colors.white);
    _crop(p.pic, p.src, centre, 15.5, 1);
    c.restore();
    final pulse = _seg(now - p.pulseAt, 0, .7);
    if (pulse > 0 && pulse < 1) {
      c.drawCircle(
        centre,
        17 + 11 * _ease(pulse),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = orbitFaceAccent.withValues(alpha: (1 - pulse) * .9),
      );
    }
    final badge = centre + const Offset(12.5, 12.5);
    c.drawCircle(badge, 7.2, Paint()..color = orbitFaceAccent);
    c.drawCircle(
      badge,
      7.2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
    _text('${p.count}', badge, p.count > 99 ? 6.5 : 8.5, Colors.white);
    if (p.isNew && age < 3) {
      final pill = RRect.fromRectAndRadius(
        Rect.fromLTWH(centre.dx - 4, centre.dy + 8, 22, 12),
        const Radius.circular(6),
      );
      final fade = 1 - _ease(_seg(age, 2.5, 3));
      c.drawRRect(pill, Paint()..color = orbitFaceAccent.withValues(alpha: fade));
      _text('NEW', pill.outerRect.center, 8, Colors.white.withValues(alpha: fade));
    }
  }

  // The painter reads the hero's state as well as its own fields (the press, the lid's text, the
  // core count...), and is only made again when the hero is built, which is when one of them
  // may have changed: so it always repaints (the frame was going to be drawn anyway).
  @override
  bool shouldRepaint(_SquarePainter old) => true;
}

/// What a scan tells the user under the chip: one gauge that shows whatever the scan is doing
/// now. While photos are made searchable it is gold (the top row of wires on the chip); there
/// is no bar for faces until a batch starts. When a batch of faces starts the
/// gauge fades to copper (the bottom row of wires) and shows that batch's progress, and when
/// the batch ends it fades back to gold and the photos' progress.
class _ScanStory extends StatefulWidget {
  const _ScanStory({super.key, required this.stats, required this.queue, required this.facesNow});

  final ScanChipStats stats;
  final OrbitQueueInfo? queue;

  /// Indexing waits while the faces of a batch are found.
  final bool facesNow;

  @override
  State<_ScanStory> createState() => _ScanStoryState();
}

class _Channel {
  const _Channel({
    required this.label,
    required this.color,
    required this.fraction,
    this.figure,
    this.left,
    this.right,
  });

  final String label;
  final Color color;

  /// How far it is, 0..1 (null when that cannot be told yet: a sweep is shown instead).
  final double? fraction;
  final String? figure;

  /// The line under the ruler: what is done / found on the left, what is left on the right.
  final String? left, right;

}

class _ScanStoryState extends State<_ScanStory> with SingleTickerProviderStateMixin {
  static const _photosColor = Color(0xFFD9A93A);
  static const _facesColor = orbitFaceAccent;

  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  static String _count(int n) {
    final digits = '$n';
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  // Time left, rounded the way people say it (a figure that changes every second is noise).
  static String _left(int ms) {
    final minutes = ms / 60000;
    if (minutes < .75) return 'under a minute left';
    if (minutes < 1.5) return 'about a minute left';
    if (minutes < 20) return 'about ${minutes.round()} min left';
    if (minutes < 90) return 'about ${(minutes / 5).round() * 5} min left';
    final hours = minutes / 60;
    if (hours < 10) {
      final halves = (hours * 2).round() / 2;
      return 'about ${halves == halves.roundToDouble() ? halves.round() : halves} h left';
    }
    return 'about ${hours.round()} h left';
  }

  _Channel _current() {
    final stats = widget.stats;
    final queue = widget.queue;
    final people = stats.people;
    final peopleNote = people > 0 ? '${_count(people)} ${people == 1 ? 'person' : 'people'} found so far' : null;

    if (stats.tuning) {
      return _Channel(
        label: 'Preparing face search for this phone',
        color: _facesColor,
        fraction: null,
        left: 'One time only, about a minute',
      );
    }
    if (widget.facesNow) {
      final total = stats.faceTotal > 0 ? stats.faceTotal : (queue?.photos ?? 60);
      return _Channel(
        label: 'Grouping faces in the last ${_count(total)} photos',
        color: _facesColor,
        fraction: stats.faceTotal > 0 ? (stats.faceDone / stats.faceTotal).clamp(0.0, 1.0) : null,
        figure: stats.faceTotal > 0 ? '${_count(stats.faceDone)} / ${_count(stats.faceTotal)}' : null,
        left: peopleNote,
      );
    }
    if (stats.total == 0) {
      return _Channel(
        label: 'Looking through your folders',
        color: _photosColor,
        fraction: null,
        figure: stats.found != null ? '${_count(stats.found!)} found' : null,
      );
    }
    if (stats.indexed == 0) {
      return _Channel(
        label: 'Loading the search model into memory',
        color: _photosColor,
        fraction: null,
      );
    }
    return _Channel(
      label: 'Making your media searchable offline',
      color: _photosColor,
      fraction: (stats.indexed / stats.total).clamp(0.0, 1.0),
      figure: '${(stats.indexed * 100 / stats.total).floor()}%',
      left: '${_count(stats.indexed)} of ${_count(stats.total)}',
      right: stats.etaMs != null ? _left(stats.etaMs!) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final channel = _current();
    final sweeping = channel.fraction == null;
    if (sweeping && !_sweep.isAnimating) _sweep.repeat();
    if (!sweeping && _sweep.isAnimating) _sweep.stop();
    final textTheme = Theme.of(context).textTheme;
    final label = textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w600, color: AppColors.ink);
    final figure = textTheme.bodyMedium!.copyWith(
      fontWeight: FontWeight.w700,
      color: AppColors.ink,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final detail = textTheme.bodySmall!.copyWith(
      color: AppColors.ink80,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return ExcludeSemantics(
      // Lined up with the edges of the chip's board.
      child: FractionallySizedBox(
        widthFactor: 296 / 340,
        child: Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _channel(channel, label, figure, detail),
            ],
          ),
        ),
      ),
    );
  }

  Widget _channel(_Channel c, TextStyle label, TextStyle figure, TextStyle detail) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...previous, if (current != null) current],
                ),
                child: Text(c.label, key: ValueKey(c.label), style: label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
            if (c.figure != null) Padding(padding: const EdgeInsets.only(left: 12), child: Text(c.figure!, style: figure)),
          ],
        ),
        const SizedBox(height: 8),
        TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: c.color),
          duration: reduced ? Duration.zero : const Duration(milliseconds: 900),
          curve: Curves.easeInOut,
          builder: (context, color, _) => TweenAnimationBuilder<double>(
            tween: Tween(end: c.fraction ?? 0),
            duration: reduced ? Duration.zero : const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => CustomPaint(
              size: const Size(double.infinity, 15),
              painter: _RulerPainter(
                fraction: c.fraction == null ? null : value,
                color: color ?? c.color,
                sweep: reduced ? null : _sweep,
              ),
            ),
          ),
        ),
        if (c.left != null || c.right != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Flexible(child: Text(c.left ?? '', style: detail, maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (c.right != null)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(c.right!, style: detail, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                )
              else
                const Spacer(),
            ],
          ),
        ],
      ],
    );
  }
}

/// A thin gauge with a ruler under it: the bar fills in the channel's colour and the ticks it
/// has passed take the colour too. When how far it is cannot be told, a short run goes to and fro.
class _RulerPainter extends CustomPainter {
  _RulerPainter({required this.fraction, required this.color, required this.sweep}) : super(repaint: sweep);

  final double? fraction;
  final Color color;
  final Animation<double>? sweep;

  static const double _track = 6;
  static const int _ticks = 50;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, _track), const Radius.circular(_track / 2));
    canvas.drawRRect(track, Paint()..color = AppColors.ink.withValues(alpha: .08));

    double reach = 0;
    canvas.save();
    canvas.clipRRect(track);
    if (fraction == null) {
      final t = sweep?.value ?? .3;
      final swing = t < .5 ? t * 2 : 2 - t * 2;
      final run = w * .22;
      final from = (w - run) * Curves.easeInOut.transform(swing);
      canvas.drawRect(Rect.fromLTWH(from, 0, run, _track), Paint()..color = color);
      reach = -1;
    } else {
      reach = w * fraction!;
      if (reach > 0) canvas.drawRect(Rect.fromLTWH(0, 0, reach, _track), Paint()..color = color);
    }
    canvas.restore();

    final tick = Paint()..strokeWidth = 1;
    for (var i = 0; i <= _ticks; i++) {
      final x = (w * i / _ticks).clamp(.5, w - .5);
      final major = i % 5 == 0;
      final passed = reach >= 0 && w * i / _ticks <= reach + .5;
      tick.color = passed ? color.withValues(alpha: .75) : AppColors.ink.withValues(alpha: major ? .28 : .16);
      canvas.drawLine(Offset(x, _track + 3), Offset(x, _track + (major ? 9 : 6)), tick);
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.fraction != fraction || old.color != color || old.sweep != sweep;
}
