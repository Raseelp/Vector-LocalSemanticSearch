import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:twentyonevision/utils/app_colors.dart';

// The processor the Library page shows, drawn from above on a 340 x 340 sheet: a green
// substrate with rows of gold contact pads along its edges, a corner marker (pin 1) and
// retention notches; the silicon die and a memory bank on it, joined to the board by fine bond
// wires; and, over all of it while the chip is closed, the steel heat spreader (the "lid") with
// its etching and the reflection of the room. The lid is drawn last, and can slide off to show
// what is under it.
//
// Everything that does not change is drawn once into a picture and kept as an image, so a frame
// only has to place a few images.

const double chipSheet = 340;
const Rect chipBoard = Rect.fromLTWH(22, 22, 296, 296);

/// The die and the memory bank are drawn at this scale about the middle of the chip, which
/// leaves the board a margin for the bond wires and the parts round them.
const double chipDieScale = .87;

const Color _gold = Color(0xFFF2D272);
const Color _goldDull = Color(0xFF8E7A3C);
const Color _goldDullLight = Color(0xFFB59F58);

double _seg(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

// ------------------------------------------------------------------------- cached images

class _Art {
  _Art(this.bounds, this.picture, this.image);

  final Rect bounds;
  final ui.Picture picture;
  final ui.Image? image;

  void paint(Canvas canvas, [Paint? paint]) {
    final img = image;
    if (img == null) {
      canvas.drawPicture(picture);
      return;
    }
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      bounds,
      paint ?? (Paint()..filterQuality = FilterQuality.medium),
    );
  }

  /// Only the part of the picture inside [region] (sheet coordinates), drawn where it belongs:
  /// much cheaper than drawing all of it under a clip when only a small part is wanted.
  void paintRegion(Canvas canvas, Rect region, Paint paint) {
    final r = region.intersect(bounds);
    if (r.isEmpty) return;
    final img = image;
    if (img == null) {
      canvas.save();
      canvas.clipRect(r);
      canvas.drawPicture(picture);
      canvas.restore();
      return;
    }
    final sx = img.width / bounds.width, sy = img.height / bounds.height;
    canvas.drawImageRect(
      img,
      Rect.fromLTRB((r.left - bounds.left) * sx, (r.top - bounds.top) * sy, (r.right - bounds.left) * sx, (r.bottom - bounds.top) * sy),
      r,
      paint,
    );
  }

  void dispose() => image?.dispose();
}

final Map<String, _Art> _arts = {};

// Pixels per sheet unit the pictures are made at: as many as the screen can show of the chip
// (a phone with a dense screen gets a sharper chip), never fewer than 2 or more than 4.
double _artScale = 3;

/// Tells the chip how dense the screen is, so its pictures are made sharp enough for it (and
/// no larger). Call before the chip is first drawn; a change makes the pictures again.
void setChipArtScale(double devicePixelRatio) {
  final scale = ((devicePixelRatio * .94).clamp(2.0, 4.0) * 2).round() / 2;
  if (scale == _artScale) return;
  _artScale = scale;
  for (final art in _arts.values) {
    art.dispose();
  }
  _arts.clear();
}

// Forgets (and frees) the pictures whose key starts with [prefix] except [keep]: the ones for a
// text or a core count that is no longer shown.
void _evictOthers(String prefix, Set<String> keep) {
  final stale = [for (final key in _arts.keys) if (key.startsWith(prefix) && !keep.contains(key)) key];
  for (final key in stale) {
    _arts.remove(key)?.dispose();
  }
}

// [draw] paints in sheet coordinates; the result is rasterised once at [scale] pixels per unit
// and drawn as an image from then on (as a picture, if the engine cannot make the image).
_Art _art(String key, Rect bounds, void Function(Canvas canvas) draw, {double? scale}) {
  final pixels = scale ?? _artScale;
  return _arts.putIfAbsent(key, () {
    final recorder = ui.PictureRecorder();
    draw(Canvas(recorder));
    final picture = recorder.endRecording();
    ui.Image? image;
    try {
      final raster = ui.PictureRecorder();
      final c = Canvas(raster);
      c.scale(pixels);
      c.translate(-bounds.left, -bounds.top);
      c.drawPicture(picture);
      image = raster.endRecording().toImageSync(
        (bounds.width * pixels).ceil(),
        (bounds.height * pixels).ceil(),
      );
    } catch (_) {
      image = null;
    }
    return _Art(bounds, picture, image);
  });
}

// -------------------------------------------------------------- bond wires and their pads

/// The wires from the die (top) and the memory bank (bottom) to the board: 27 along the top,
/// 27 along the bottom. The top ones are the CLIP indexing, the bottom ones the faces.
const int chipWireCount = 27;

double _wireX(int i) => 67 + i * 8.0;

double _dieX(double sheetX) => chipSheet / 2 + (sheetX - chipSheet / 2) / chipDieScale;
double _dieY(double sheetY) => chipSheet / 2 + (sheetY - chipSheet / 2) / chipDieScale;

// Where a wire starts on the die (top) or the bank (bottom), and where it ends on the board, in
// sheet coordinates.
const double _dieEdgeTop = 52.6;
const double _dieEdgeBottom = 288.0;
const double _fingerTop = 42.6;
const double _fingerBottom = 298.6;

Path _wirePath(int bar, int i) {
  final fan = (i - (chipWireCount - 1) / 2) * .3;
  final a = Offset(_wireX(i), bar == 0 ? _dieEdgeTop : _dieEdgeBottom);
  final b = Offset(_wireX(i) + fan, bar == 0 ? _fingerTop : _fingerBottom);
  // A wire is never quite straight: it leaves the pad, arches and settles.
  final bow = 2.2 * math.sin(i * 1.9 + bar);
  final mid = Offset.lerp(a, b, .5)! + Offset(bow, 0);
  return Path()
    ..moveTo(a.dx, a.dy)
    ..quadraticBezierTo(mid.dx, mid.dy, b.dx, b.dy);
}

final List<List<Path>> _wirePaths = [
  for (var bar = 0; bar < 2; bar++) [for (var i = 0; i < chipWireCount; i++) _wirePath(bar, i)],
];
final List<List<ui.PathMetric>> _wireMetrics = [
  for (final bar in _wirePaths) [for (final path in bar) path.computeMetrics().first],
];

/// Where on wire [i] of [bar] (0 the top, 1 the bottom) the point [f] (0 at the die, 1 at the
/// board) is, on the sheet.
Offset chipWirePoint(int bar, int i, double f) {
  final metric = _wireMetrics[bar][i];
  return metric.getTangentForOffset(metric.length * f.clamp(0.0, 1.0))!.position;
}

/// The part of lane [i] of [bar] (0 the top, 1 the bottom) between [from] and [to] (0 at the die
/// or bank, 1 at the board).
Path chipLaneSegment(int bar, int i, double from, double to) {
  final metric = _wireMetrics[bar][i];
  return metric.extractPath(metric.length * from.clamp(0.0, 1.0), metric.length * to.clamp(0.0, 1.0));
}

/// Where on lane [i] of [bar] the point [f] (0 at the die, 1 at the board) is, on the sheet.
Offset chipLanePoint(int bar, int i, double f) {
  final metric = _wireMetrics[bar][i];
  return metric.getTangentForOffset(metric.length * f.clamp(0.0, 1.0))!.position;
}

// The wires with nothing on them: shadow, body and shine, all 27 of a row in one picture.
void _drawDullLanes(Canvas canvas, int bar) {
  final body = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 2.4
    ..color = const Color(0xFF4F5A52);
  final shine = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = .9
    ..color = Colors.white.withValues(alpha: .14);
  final shade = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 3
    ..color = Colors.black.withValues(alpha: .3);
  for (var i = 0; i < chipWireCount; i++) {
    final path = _wirePaths[bar][i];
    canvas.drawPath(path.shift(const Offset(1.1, 1.6)), shade);
    canvas.drawPath(path, body);
    canvas.drawPath(path.shift(const Offset(-.5, -.5)), shine);
  }
}

/// The 27 lanes of [bar]: each is a wire between the die (or the bank) and the board. A lane
/// that is not up is drawn dull, as a wire with nothing on it (all of those are one picture);
/// [level] is how far lane `i` is up (0..1), which brightens it to [color].
void paintChipLanes(
  Canvas canvas,
  int bar, {
  required Color color,
  required double alpha,
  required double Function(int i) level,
}) {
  _art('lanes-dull-$bar', const Rect.fromLTWH(50, 34, 250, 272), (c) => _drawDullLanes(c, bar)).paint(canvas);
  Paint? body, shine;
  for (var i = 0; i < chipWireCount; i++) {
    final up = level(i).clamp(0.0, 1.0);
    if (up <= .004) continue;
    body ??= Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.4;
    shine ??= Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = .9;
    final path = _wirePaths[bar][i];
    // Brought up, it takes on its colour (over the dull wire, which has its shadow already).
    body.color = Color.lerp(const Color(0xFF4F5A52), color, up * alpha)!;
    canvas.drawPath(path, body);
    shine.color = Colors.white.withValues(alpha: (.14 + .46 * up) * (.4 + .6 * alpha));
    canvas.drawPath(path.shift(const Offset(-.5, -.5)), shine);
  }
}

// -------------------------------------------------------------- substrate, die and memory

void _drawBoard(Canvas canvas) {
  final board = RRect.fromRectAndRadius(chipBoard, const Radius.circular(12));
  // The shadow it casts on the page.
  for (var k = 1; k <= 4; k++) {
    canvas.drawRRect(
      board.shift(Offset(0, 1.5 * k)),
      Paint()..color = const Color(0xFF1A1D1C).withValues(alpha: .04),
    );
  }
  canvas.drawRRect(
    board,
    Paint()
      ..shader = ui.Gradient.linear(chipBoard.topLeft, chipBoard.bottomRight, [
        const Color(0xFF2A604B),
        const Color(0xFF1B4535),
      ]),
  );
  canvas.save();
  canvas.clipRRect(board);
  // The weave of the board, as a faint speckle.
  final rnd = math.Random(5);
  final speck = Paint();
  for (var i = 0; i < 260; i++) {
    final at = Offset(
      chipBoard.left + rnd.nextDouble() * chipBoard.width,
      chipBoard.top + rnd.nextDouble() * chipBoard.height,
    );
    speck.color = (rnd.nextBool() ? Colors.white : Colors.black).withValues(alpha: .05 + rnd.nextDouble() * .06);
    canvas.drawCircle(at, .5 + rnd.nextDouble() * .7, speck);
  }
  // Edge light, top and left; shade, bottom and right.
  canvas.drawRRect(
    board.shift(const Offset(1.4, 1.4)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = Colors.white.withValues(alpha: .16),
  );
  canvas.drawRRect(
    board.shift(const Offset(-1.4, -1.4)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = Colors.black.withValues(alpha: .22),
  );
  canvas.restore();
  canvas.drawRRect(
    board,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFF0E2A20),
  );
  // The contact pads along the four edges (what a real chip plugs in by).
  const padFrom = 46.0, padTo = 294.0, padsPerSide = 18;
  const pitch = (padTo - padFrom) / (padsPerSide - 1);
  const near = 23.4, far = 313.4;
  final pad = Paint();
  void contact(Rect r) {
    final tall = r.height > r.width;
    pad.color = _goldDull;
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(.8)), pad);
    pad.color = _goldDullLight;
    canvas.drawRect(
      tall ? Rect.fromLTWH(r.left, r.top, r.width * .45, r.height) : Rect.fromLTWH(r.left, r.top, r.width, r.height * .45),
      pad,
    );
  }

  for (var i = 0; i < padsPerSide; i++) {
    final at = padFrom + i * pitch;
    contact(Rect.fromLTWH(at - 2.6, near, 5.2, 3.4));
    contact(Rect.fromLTWH(far, at - 2.6, 3.4, 5.2));
    contact(Rect.fromLTWH(at - 2.6, far, 5.2, 3.4));
    contact(Rect.fromLTWH(near, at - 2.6, 3.4, 5.2));
  }
  // Retention notches in the middle of the left and right edges.
  canvas.save();
  canvas.clipRRect(board);
  for (final x in [chipBoard.left, chipBoard.right]) {
    canvas.drawCircle(Offset(x, 170), 5.2, Paint()..color = AppColors.canvas);
    canvas.drawCircle(
      Offset(x, 170),
      5.2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .9
        ..color = const Color(0xFF0E2A20),
    );
  }
  canvas.restore();

  // The bond fingers the wires end on: gold lands along the top and bottom. (What each row
  // carries is printed above and below them while a scan runs: see scan_square.dart.)
  for (var bar = 0; bar < 2; bar++) {
    for (var i = 0; i < chipWireCount; i++) {
      final fan = (i - (chipWireCount - 1) / 2) * .3;
      final x = _wireX(i) + fan;
      final y = bar == 0 ? _fingerTop - 2.6 : _fingerBottom - 1.0;
      contact(Rect.fromLTWH(x - 3.2, y, 6.4, 3.8));
    }
  }
  // A few capacitors at the ends of the rows, and vias in the board.
  final cap = Paint();
  void capacitors(double x, double y, int count) {
    canvas.drawRect(
      Rect.fromLTWH(x - 1.6, y - 1.6, count * 8 + 1.2, 6.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .5
        ..color = Colors.white.withValues(alpha: .3),
    );
    for (var i = 0; i < count; i++) {
      final r = Rect.fromLTWH(x + i * 8, y, 6.2, 3.4);
      cap.color = const Color(0xFFCDB98A);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(.5)), cap);
      cap.color = const Color(0xFFB7BDBB);
      canvas.drawRect(Rect.fromLTWH(r.left, r.top, 1.4, r.height), cap);
      canvas.drawRect(Rect.fromLTWH(r.right - 1.4, r.top, 1.4, r.height), cap);
    }
  }

  capacitors(286, 35.8, 2);
  capacitors(286, 299.8, 2);
  final via = Paint()..color = const Color(0xFF9FB8AB).withValues(alpha: .55);
  for (final at in const [Offset(32, 98), Offset(32, 242), Offset(308, 98), Offset(308, 242)]) {
    canvas.drawCircle(at, 1.6, via);
    canvas.drawCircle(at, .7, Paint()..color = const Color(0xFF10261D));
  }
  // The alignment triangle in the corner.
  final marker = Path()
    ..moveTo(25.5, 25.5)
    ..lineTo(38, 25.5)
    ..lineTo(25.5, 38)
    ..close();
  canvas.drawPath(marker, Paint()..color = _gold);
  canvas.drawPath(
    marker,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..color = _goldDull,
  );
}

/// The substrate: a green board with its pads, corner marker, notches and parts.
void paintChipBoard(Canvas canvas) =>
    _art('board', const Rect.fromLTWH(0, 0, chipSheet, chipSheet), _drawBoard).paint(canvas);

// ------------------------------------------------------------------------------ the die

// Where the parts of the die are. It is laid out like a modern processor: two rows of identical
// cores (the cores of the phone, [perRow] to a row), the shared cache between the rows, the data
// fabric that joins the cores to the cache, and along the bottom the memory controller with its
// interface to the memory (at the die's edge, where the memory is reached), the storage and USB
// interfaces, the media engine, the clock generator and the power management.
class _DieLayout {
  _DieLayout(Rect a, this.perRow) {
    final gap = perRow == 4 ? 8.0 : 12.0;
    final w = (256 - (perRow - 1) * gap) / perRow;
    for (final y in [12.0, 104.0]) {
      for (var c = 0; c < perRow; c++) {
        cores.add(Rect.fromLTWH(a.left + 12 + c * (w + gap), a.top + y, w, 54));
      }
    }
    for (var c = 0; c < perRow; c++) {
      l3.add(Rect.fromLTWH(a.left + 12 + c * (w + gap), a.top + 72, w, 26));
    }
    fabricTop = Rect.fromLTWH(a.left + 12, a.top + 67, 256, 4);
    fabricBottom = Rect.fromLTWH(a.left + 12, a.top + 99, 256, 4);
    mc = Rect.fromLTWH(a.left + 12, a.top + 164, 124, 15);
    phy = Rect.fromLTWH(a.left + 12, a.top + 180, 124, 16);
    io = Rect.fromLTWH(a.left + 144, a.top + 164, 52, 32);
    media = Rect.fromLTWH(a.left + 200, a.top + 164, 36, 32);
    pll = Rect.fromLTWH(a.left + 240, a.top + 164, 28, 15);
    pmu = Rect.fromLTWH(a.left + 240, a.top + 181, 28, 15);
    columnWidth = w;
    columnGap = gap;
  }

  final int perRow;
  final List<Rect> cores = [], l3 = [];
  late final Rect fabricTop, fabricBottom, mc, phy, io, media, pll, pmu;
  late final double columnWidth, columnGap;
}

/// How many cores to a row for a phone with [cores] cores: two rows, three or four to a row.
int chipDieColumns(int cores) => (cores / 2).round().clamp(3, 4);

/// The blocks of the die in the order a chip powers up: the clock generator, power management,
/// the memory controller and its interface, the fabric (top, bottom), the slices of the shared
/// cache, the cores (top row, then bottom row), then the storage/USB interfaces and the media
/// engine. The cache slices and cores are the blocks 6 to 6 + 3 * [perRow] (see
/// [chipDieWorkRange]).
List<Rect> chipDieBlocks(Rect area, int perRow) {
  final l = _DieLayout(area, perRow);
  return [l.pll, l.pmu, l.mc, l.phy, l.fabricTop, l.fabricBottom, ...l.l3, ...l.cores, l.io, l.media];
}

/// The blocks that hold the cache and the cores (what a model is loaded into): their first
/// index and how many there are.
(int, int) chipDieWorkRange(int perRow) => (6, 3 * perRow);

// ---- the textures of silicon: each kind of block has its own look under the microscope.

// Memory (caches, tables): bit cells in a fine regular grid, cut into mats. Each mat has its
// row decoder down the left and, under it, a row of sense amplifiers (wider than the cells).
void _sramTexture(Canvas c, Rect r, Color ink) {
  final cell = Paint()..color = ink;
  final periphery = Paint()..color = ink.withValues(alpha: ink.a * .75);
  const pitch = 2.2;
  final mats = math.max(1, (r.width / 26).round());
  final matW = r.width / mats;
  final sense = r.height >= 9 ? 2.6 : 0.0;
  final rows = ((r.height - sense - 1) / pitch).floor();
  for (var m = 0; m < mats; m++) {
    final left = r.left + m * matW;
    for (var row = 0; row < rows; row++) {
      c.drawRect(Rect.fromLTWH(left + .5, r.top + .8 + row * pitch, 1.7, 1.0), periphery);
    }
    for (var x = left + 3.2; x + 1.3 < left + matW - .6; x += pitch) {
      for (var row = 0; row < rows; row++) {
        c.drawRect(Rect.fromLTWH(x, r.top + .8 + row * pitch, 1.3, 1.3), cell);
      }
    }
    if (sense > 0) {
      for (var x = left + 3.2; x + 3 < left + matW - .6; x += pitch * 2) {
        c.drawRect(Rect.fromLTWH(x, r.bottom - sense + .2, 3.0, 1.6), periphery);
      }
    }
  }
}

// Control logic (decode, schedulers): rows of standard cells, each row a string of cells of
// different widths, so it looks like placed-and-routed logic, not a pattern.
void _logicTexture(Canvas c, Rect r, Color ink, int seed, {double pitch = 2.6, double rowH = 2, double fill = .85}) {
  final rnd = math.Random(seed);
  final paint = Paint();
  for (var y = r.top + .9; y + rowH <= r.bottom - .4; y += pitch) {
    var x = r.left + .9;
    while (x < r.right - .9) {
      final len = 2.5 + rnd.nextDouble() * 11;
      final w = math.min(len, r.right - .9 - x);
      if (rnd.nextDouble() < fill) {
        paint.color = ink.withValues(alpha: ink.a * (.3 + .7 * rnd.nextDouble()));
        c.drawRect(Rect.fromLTWH(x, y, w, rowH), paint);
      }
      x += len + .55;
    }
  }
}

// Datapaths (ALUs, the vector unit): unlike control logic these are laid out as bit slices, the
// same column repeated once for every bit, with the wires of the buses running across them.
void _datapathTexture(Canvas c, Rect r, Color ink) {
  const rowAlpha = [.9, .5, 1.0, .65, .8, .45];
  final cell = Paint();
  for (var x = r.left + .9; x + 1.5 <= r.right - .6; x += 2.4) {
    var row = 0;
    for (var y = r.top + .9; y + 1.4 <= r.bottom - .5; y += 2.0) {
      cell.color = ink.withValues(alpha: ink.a * rowAlpha[row % rowAlpha.length]);
      c.drawRect(Rect.fromLTWH(x, y, 1.5, 1.4), cell);
      row++;
    }
  }
  final bus = Paint()
    ..strokeWidth = .4
    ..color = ink.withValues(alpha: ink.a * .55);
  for (var y = r.top + 2.2; y < r.bottom - 1; y += 6) {
    c.drawLine(Offset(r.left + .6, y), Offset(r.right - .6, y), bus);
  }
}

// Registers and queues (register files, reorder buffer, store buffer): multi-ported arrays,
// bigger cells than a cache's with read and write wires between the rows.
void _registerTexture(Canvas c, Rect r, Color ink) {
  final cell = Paint()..color = ink.withValues(alpha: ink.a * 1.3);
  final wire = Paint()
    ..strokeWidth = .4
    ..color = ink.withValues(alpha: ink.a * .5);
  for (var y = r.top + 1.2; y < r.bottom - 1; y += 3) {
    c.drawLine(Offset(r.left + .8, y + 1), Offset(r.right - .8, y + 1), wire);
    for (var x = r.left + 1.2; x < r.right - 2; x += 3) {
      c.drawRect(Rect.fromLTWH(x, y, 1.9, 1.9), cell);
    }
  }
}

// The interface to the outside (memory, storage, USB): the same slice repeated once per lane
// (a delay line on top and a column of drivers under it), because it is one macro placed again
// and again.
void _phyTexture(Canvas c, Rect r, Color ink) {
  final lanes = math.max(1, (r.width / 13).floor());
  final laneW = r.width / lanes;
  final delay = Paint()..color = ink.withValues(alpha: ink.a * .7);
  final driver = Paint()..color = ink;
  final seam = Paint()
    ..strokeWidth = .4
    ..color = ink.withValues(alpha: ink.a * .5);
  for (var k = 0; k < lanes; k++) {
    final x = r.left + k * laneW;
    for (var i = 0; i < 3; i++) {
      c.drawRect(Rect.fromLTWH(x + .9 + i * 3.4, r.top + .8, 2.6, 2.2), delay);
      c.drawRect(Rect.fromLTWH(x + .9 + i * 3.4, r.top + 3.6, 2.6, r.height - 4.4), driver);
    }
    if (k > 0) c.drawLine(Offset(x, r.top + .6), Offset(x, r.bottom - .6), seam);
  }
}

Path _octagon(Offset centre, double radius) {
  final path = Path();
  for (var k = 0; k < 8; k++) {
    final angle = math.pi / 8 + k * math.pi / 4;
    final p = centre + Offset(math.cos(angle), math.sin(angle)) * radius;
    if (k == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  return path..close();
}

// The clock generator: an oscillator with a spiral inductor (turns of octagon), the capacitors
// of its loop filter (an array of identical cells) and the divider logic.
void _pllTexture(Canvas c, Rect r, Color ink, int seed) {
  final centre = Offset(r.left + r.height * .55, r.center.dy);
  final turn = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = .8
    ..color = ink;
  for (var k = 1; k <= 3; k++) {
    c.drawPath(_octagon(centre, k * r.height * .13 + .9), turn);
  }
  final left = r.left + r.height * 1.15;
  final caps = Rect.fromLTWH(left, r.top + 1.5, (r.right - left - 1.5) * .5, r.height - 3);
  _registerTexture(c, caps, ink);
  final divider = Rect.fromLTWH(caps.right + 1, r.top + 1.5, r.right - caps.right - 2.5, r.height - 3);
  _logicTexture(c, divider, ink, seed, pitch: 2.4, rowH: 1.7);
}

// The data fabric: bundles of parallel wires (the buses) with a router, a small block of
// logic, at the foot of each column of cores.
void _fabricTexture(Canvas c, Rect r, Color ink, int seed, List<double> routers) {
  final wire = Paint()
    ..strokeWidth = .45
    ..color = ink.withValues(alpha: ink.a * .8);
  for (var k = 0; k < 3; k++) {
    final y = r.top + .8 + k * 1.2;
    c.drawLine(Offset(r.left + 1, y), Offset(r.right - 1, y), wire);
  }
  for (final x in routers) {
    _logicTexture(c, Rect.fromCenter(center: Offset(x, r.center.dy), width: 9, height: r.height - 1), ink, seed++, pitch: 1.4, rowH: 1.0, fill: .9);
  }
}

// One layer of the die: its blocks and what is in them. Drawn dark, as the chip is; and once
// more in white (with no backing) to be lit block by block as the chip works (see
// [paintChipDieLit]).
void _drawDieLayer(Canvas canvas, Rect area, int perRow, {required bool lit}) {
  final l = _DieLayout(area, perRow);
  final ink = Colors.white.withValues(alpha: lit ? .8 : .11);
  final line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = .8
    ..color = Colors.white.withValues(alpha: lit ? .5 : .2);
  final hair = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = .5
    ..color = Colors.white.withValues(alpha: lit ? .32 : .1);
  final warm = Paint()..color = lit ? Colors.white.withValues(alpha: .8) : const Color(0xFFD8B35A).withValues(alpha: .35);

  void block(Rect r, [double radius = 3.5]) {
    final shape = RRect.fromRectAndRadius(r, Radius.circular(radius));
    if (!lit) canvas.drawRRect(shape, Paint()..color = Colors.black.withValues(alpha: .22));
    canvas.drawRRect(shape, line);
  }

  void unit(Rect r) => canvas.drawRect(r, hair);

  // A core, as in a real out-of-order core. The front end (instruction cache, the branch
  // predictor's tables, fetch and decode) on the left; the execution core (register rename and
  // reorder buffer, the schedulers, the integer registers and the ALUs) next to it; the vector
  // unit (its scheduler, the datapath and its registers); the load/store unit with the data
  // cache, the store buffer and the address translation; and the level-2 cache along one edge.
  // Every core is the same macro placed again: the bottom row is turned over and every other
  // core is mirrored, as real cores are, so their caches and buses meet.
  void core(Rect r, {required bool flipX, required bool flipY}) {
    canvas.save();
    if (flipX) {
      canvas.translate(r.center.dx * 2, 0);
      canvas.scale(-1, 1);
    }
    if (flipY) {
      canvas.translate(0, r.center.dy * 2);
      canvas.scale(1, -1);
    }
    block(r);
    const g = 1.5;
    final iw = r.width - 4 - 3 * g;
    final widths = [iw * .27, iw * .38, iw * .18, iw * .17];
    final xs = <double>[];
    var x = r.left + 2;
    for (final w in widths) {
      xs.add(x);
      x += w + g;
    }
    final top = r.top + 2;
    // Front end.
    final l1i = Rect.fromLTWH(xs[0], top, widths[0], 11);
    final bpu = Rect.fromLTWH(xs[0], top + 11.5, widths[0], 7);
    final decode = Rect.fromLTWH(xs[0], top + 19, widths[0], 16);
    _sramTexture(canvas, l1i, ink);
    _sramTexture(canvas, bpu, ink);
    _logicTexture(canvas, decode, ink, 31, pitch: 2.2, rowH: 1.5);
    // Execution core.
    final rob = Rect.fromLTWH(xs[1], top, widths[1], 8.5);
    final sched = Rect.fromLTWH(xs[1], top + 9, widths[1], 7.5);
    final irf = Rect.fromLTWH(xs[1], top + 17, widths[1], 8);
    final alu = Rect.fromLTWH(xs[1], top + 25.5, widths[1], 9.5);
    _registerTexture(canvas, rob, ink);
    _logicTexture(canvas, sched, ink, 41, pitch: 2.2, rowH: 1.5);
    _registerTexture(canvas, irf, ink);
    _datapathTexture(canvas, alu, ink);
    // Vector unit.
    final vsched = Rect.fromLTWH(xs[2], top, widths[2], 7);
    final vec = Rect.fromLTWH(xs[2], top + 7.5, widths[2], 17);
    final vrf = Rect.fromLTWH(xs[2], top + 25, widths[2], 10);
    _logicTexture(canvas, vsched, ink, 51, pitch: 2.1, rowH: 1.4);
    _datapathTexture(canvas, vec, ink);
    _registerTexture(canvas, vrf, ink);
    // Load/store unit.
    final l1d = Rect.fromLTWH(xs[3], top, widths[3], 14);
    final lsu = Rect.fromLTWH(xs[3], top + 14.5, widths[3], 11);
    final tlb = Rect.fromLTWH(xs[3], top + 26, widths[3], 9);
    _sramTexture(canvas, l1d, ink);
    _logicTexture(canvas, lsu, ink, 61, pitch: 2.2, rowH: 1.5);
    _registerTexture(canvas, tlb, ink);
    for (final u in [l1i, bpu, decode, rob, sched, irf, alu, vsched, vec, vrf, l1d, lsu, tlb]) {
      unit(u);
    }
    // Level-2 cache.
    final l2 = Rect.fromLTWH(r.left + 2, r.bottom - 15, r.width - 4, 13);
    _sramTexture(canvas, l2, ink);
    unit(l2);
    canvas.drawCircle(Offset(r.center.dx, r.top + 1), .9, warm);
    canvas.restore();
  }

  for (var i = 0; i < l.cores.length; i++) {
    final column = i % perRow;
    core(l.cores[i], flipX: column.isOdd, flipY: i >= perRow);
  }

  // The shared cache: a slice for each column of cores, memory above and below a strip of tags
  // and control.
  for (final r in l.l3) {
    block(r, 3);
    final upper = Rect.fromLTWH(r.left + 2, r.top + 1.5, r.width - 4, 10);
    final tags = Rect.fromLTWH(r.left + 2, r.top + 12, r.width - 4, 3);
    final lower = Rect.fromLTWH(r.left + 2, r.top + 15.5, r.width - 4, 9.5);
    _sramTexture(canvas, upper, ink);
    _logicTexture(canvas, tags, ink, 71, pitch: 1.6, rowH: 1.1);
    _sramTexture(canvas, lower, ink);
  }

  // The fabric: the buses between the cores and the cache, with a router at each column.
  final routers = [for (final r in l.l3) r.center.dx];
  block(l.fabricTop, 1.5);
  _fabricTexture(canvas, l.fabricTop, ink, 81, routers);
  block(l.fabricBottom, 1.5);
  _fabricTexture(canvas, l.fabricBottom, ink, 81, routers);

  // Memory controller: a buffer for reordered requests, the scheduler, the registers that hold
  // the timings, and the error correction. Its interface under it, at the edge of the die.
  block(l.mc);
  final mcBuffer = Rect.fromLTWH(l.mc.left + 2, l.mc.top + 1.5, 26, l.mc.height - 3);
  final mcSched = Rect.fromLTWH(l.mc.left + 29.5, l.mc.top + 1.5, 36, l.mc.height - 3);
  final mcRegs = Rect.fromLTWH(l.mc.left + 67, l.mc.top + 1.5, 24, l.mc.height - 3);
  final mcEcc = Rect.fromLTWH(l.mc.left + 92.5, l.mc.top + 1.5, l.mc.width - 94.5, l.mc.height - 3);
  _sramTexture(canvas, mcBuffer, ink);
  _logicTexture(canvas, mcSched, ink, 91, pitch: 2.2, rowH: 1.5);
  _registerTexture(canvas, mcRegs, ink);
  _logicTexture(canvas, mcEcc, ink, 92, pitch: 2.2, rowH: 1.5);
  for (final u in [mcBuffer, mcSched, mcRegs, mcEcc]) {
    unit(u);
  }
  block(l.phy);
  _phyTexture(canvas, Rect.fromLTWH(l.phy.left + 2, l.phy.top + 1, l.phy.width - 4, 8.5), ink);
  for (var k = 0; k < 14; k++) {
    canvas.drawCircle(Offset(l.phy.left + 9 + k * 8.2, l.phy.bottom - 3.8), 1.5, warm);
  }

  // The outside interfaces: storage and USB (a controller above its lanes), the media engine
  // (a datapath with the memory for its lines), the clock generator and the power management
  // (a small controller beside the rows of power switches).
  block(l.io);
  _logicTexture(canvas, Rect.fromLTWH(l.io.left + 2, l.io.top + 1.5, l.io.width - 4, 8), ink, 101, pitch: 2.2, rowH: 1.5);
  _phyTexture(canvas, Rect.fromLTWH(l.io.left + 2, l.io.top + 11, l.io.width - 4, 12), ink);
  for (var k = 0; k < 6; k++) {
    canvas.drawCircle(Offset(l.io.left + 6 + k * 8.2, l.io.bottom - 4), 1.5, warm);
  }
  block(l.media);
  _datapathTexture(canvas, Rect.fromLTWH(l.media.left + 2, l.media.top + 1.5, l.media.width - 4, 14), ink);
  _logicTexture(canvas, Rect.fromLTWH(l.media.left + 2, l.media.top + 16.5, l.media.width - 4, 6), ink, 111, pitch: 2.1, rowH: 1.4);
  _sramTexture(canvas, Rect.fromLTWH(l.media.left + 2, l.media.top + 23.5, l.media.width - 4, 7), ink);
  block(l.pll, 2.5);
  _pllTexture(canvas, l.pll.deflate(.5), ink, 121);
  block(l.pmu, 2.5);
  _logicTexture(canvas, Rect.fromLTWH(l.pmu.left + 2, l.pmu.top + 1.5, 13, l.pmu.height - 3), ink, 131, pitch: 2.2, rowH: 1.5);
  final switches = Paint()..color = ink.withValues(alpha: ink.a * .8);
  for (var y = l.pmu.top + 2; y + 1.6 < l.pmu.bottom - 1; y += 2.6) {
    canvas.drawRect(Rect.fromLTWH(l.pmu.left + 16.5, y, l.pmu.width - 18.5, 1.6), switches);
  }

  if (!lit) {
    // Routing channels between the columns of cores, and the clock spine across.
    final channel = Paint()
      ..strokeWidth = .5
      ..color = Colors.white.withValues(alpha: .07);
    for (var c = 0; c < perRow - 1; c++) {
      final x = area.left + 12 + (c + 1) * l.columnWidth + c * l.columnGap + l.columnGap / 2;
      canvas.drawLine(Offset(x, area.top + 12), Offset(x, area.top + 158), channel);
    }
    final spine = Paint()
      ..strokeWidth = .8
      ..color = Colors.white.withValues(alpha: .12);
    canvas.drawLine(Offset(area.left + 6, area.top + 160.5), Offset(area.right - 6, area.top + 160.5), spine);
  }
}

void _drawDie(Canvas canvas, Rect area, int perRow) {
  final rim = RRect.fromRectAndRadius(area.inflate(3.4), const Radius.circular(18));
  // The seal round the die.
  canvas.drawRRect(rim, Paint()..color = const Color(0xFF14181A));
  canvas.drawRRect(
    rim.deflate(.5),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..color = Colors.white.withValues(alpha: .08),
  );
  final die = RRect.fromRectAndRadius(area.inflate(1.8), const Radius.circular(16));
  canvas.drawRRect(
    die,
    Paint()
      ..shader = ui.Gradient.linear(die.outerRect.topLeft, die.outerRect.bottomRight, [
        const Color(0xFF58606A),
        const Color(0xFF30363D),
      ]),
  );
  canvas.save();
  canvas.clipRRect(die);
  // The sheen of silicon: thin metal layers split the light into soft bands of colour.
  canvas.drawRect(
    area,
    Paint()
      ..shader = ui.Gradient.sweep(
        area.center,
        [
          const Color(0x2E8A6BC4),
          const Color(0x2E4FA6A3),
          const Color(0x2EC2A24E),
          const Color(0x2EB26A8E),
          const Color(0x2E8A6BC4),
        ],
        [0, .28, .52, .78, 1],
      ),
  );
  // A fine dot matrix over everything, as of the finest metal layer.
  final dot = Paint()..color = Colors.white.withValues(alpha: .07);
  for (var y = area.top + 3; y < area.bottom; y += 4) {
    for (var x = area.left + 3; x < area.right; x += 4) {
      canvas.drawRect(Rect.fromLTWH(x, y, .8, .8), dot);
    }
  }
  _drawDieLayer(canvas, area, perRow, lit: false);
  // The bond pads along the top edge of the die, where the wires of the CLIP row start.
  final bondPad = Paint()..color = const Color(0xFFC9CFD4);
  for (var i = 0; i < chipWireCount; i++) {
    final x = _dieX(_wireX(i));
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(x - 3.2, _dieY(_dieEdgeTop) - 1.6, 6.4, 4.2), const Radius.circular(.7)),
      bondPad,
    );
  }
  canvas.restore();
  canvas.drawRRect(
    die,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..color = Colors.white.withValues(alpha: .16),
  );
}

/// The silicon die the photos are read on, with [perRow] cores to a row (see [chipDieColumns]).
void paintChipDie(Canvas canvas, Rect area, int perRow) {
  _evictOthers('die', {'die$perRow', 'dieLit$perRow'});
  _art('die$perRow', area.inflate(8), (c) => _drawDie(c, area, perRow)).paint(canvas);
}

/// Draws what [draw] paints (in sheet coordinates, inside [bounds]) from a picture made the first
/// time and kept: for something that is drawn the same way every frame.
void paintChipCached(Canvas canvas, String key, Rect bounds, void Function(Canvas canvas) draw) =>
    _art(key, bounds, draw).paint(canvas);

/// Makes the pictures of everything that is under the lid (the die, the lit die, the memory
/// bank and the dull wires) one at a time, a little apart, so none of them is made while the lid
/// is opening or a scan is starting (it is the biggest of the chip's work).
Future<void> warmChipInside(Rect die, Rect strip, int perRow) async {
  final steps = <void Function()>[
    () => _art('die$perRow', die.inflate(8), (c) => _drawDie(c, die, perRow)),
    () => _art('dieLit$perRow', die.inflate(8), (c) => _drawDieLayer(c, die, perRow, lit: true)),
    () => _art('memory', strip.inflate(4), (c) => _drawMemory(c, strip)),
    () => _art('lanes-dull-0', const Rect.fromLTWH(50, 34, 250, 272), (c) => _drawDullLanes(c, 0)),
    () => _art('lanes-dull-1', const Rect.fromLTWH(50, 34, 250, 272), (c) => _drawDullLanes(c, 1)),
  ];
  for (final step in steps) {
    step();
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

/// Lights parts of the die as if they were working: each of [regions] is a place on the die and
/// how brightly it shows (0..1), in [tint]. What is lit is the die's own structure (its memory
/// cells, logic rows, registers), so the light looks like it comes from inside the silicon.
void paintChipDieLit(Canvas canvas, Rect area, int perRow, List<(Rect, double)> regions, Color tint) {
  final art = _art('dieLit$perRow', area.inflate(8), (c) => _drawDieLayer(c, area, perRow, lit: true));
  final paint = Paint()
    ..filterQuality = FilterQuality.medium
    ..blendMode = BlendMode.plus;
  for (final (rect, level) in regions) {
    if (level <= .01) continue;
    paint.colorFilter = ColorFilter.mode(tint.withValues(alpha: level.clamp(0.0, 1.0)), BlendMode.modulate);
    // Only the block's own part of the picture (a block's frame is .8 wide, and the next block is
    // never closer than a unit).
    art.paintRegion(canvas, rect.inflate(.45), paint);
  }
}

void _drawMemory(Canvas canvas, Rect strip) {
  // The memory bank: a small module with its own board, memory chips and a row of gold
  // contacts along the bottom edge (where the wires of the FACE row start).
  final bank = RRect.fromRectAndRadius(strip, const Radius.circular(16));
  canvas.drawRRect(
    bank,
    Paint()
      ..shader = ui.Gradient.linear(strip.topCenter, strip.bottomCenter, [
        const Color(0xFF1F3F33),
        const Color(0xFF13281F),
      ]),
  );
  canvas.save();
  canvas.clipRRect(bank);
  // The chips of the bank, one under each place a picture lands (the same places the queue
  // and the people tray use).
  final chip = Paint()..color = const Color(0xFF0E1214);
  for (var k = 0; k < 7; k++) {
    final r = Rect.fromLTWH(strip.left + 6 + k * 38, strip.top + 11, 34, 34);
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)), chip);
    canvas.drawRRect(
      RRect.fromRectAndRadius(r.deflate(.5), const Radius.circular(3.6)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .6
        ..color = Colors.white.withValues(alpha: .14),
    );
  }
  final gold = Paint()..color = const Color(0xFFD6B85A);
  for (var i = 0; i < chipWireCount; i++) {
    final x = _dieX(_wireX(i));
    canvas.drawRect(Rect.fromLTWH(x - 3.2, strip.bottom - 6.4, 6.4, 6.4), gold);
  }
  canvas.restore();
  canvas.drawRRect(
    bank.deflate(.6),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: .12),
  );
}

/// The memory bank along the bottom.
void paintChipMemory(Canvas canvas, Rect strip) =>
    _art('memory', strip.inflate(4), (c) => _drawMemory(c, strip)).paint(canvas);

// ---------------------------------------------------------------------------- the lid

/// What is etched on the lid: a small line above, a big line, a line under, some more lines,
/// and a hint.
class ChipLidText {
  const ChipLidText({required this.above, required this.big, required this.below, this.extras = const [], required this.hint});

  final String above;
  final String big;
  final String below;
  final List<String> extras;
  final String hint;

  String get key => '$above|$big|$below|${extras.join('/')}|$hint';
}

const Rect _flange = Rect.fromLTWH(34, 34, 272, 272);
const Rect _plate = Rect.fromLTWH(50, 50, 240, 240);

Path _flangePath() {
  const r = 15.0, cut = 16.0;
  return Path()
    ..moveTo(_flange.left + cut, _flange.top)
    ..lineTo(_flange.right - r, _flange.top)
    ..arcTo(Rect.fromCircle(center: Offset(_flange.right - r, _flange.top + r), radius: r), -math.pi / 2, math.pi / 2, false)
    ..lineTo(_flange.right, _flange.bottom - r)
    ..arcTo(Rect.fromCircle(center: Offset(_flange.right - r, _flange.bottom - r), radius: r), 0, math.pi / 2, false)
    ..lineTo(_flange.left + r, _flange.bottom)
    ..arcTo(Rect.fromCircle(center: Offset(_flange.left + r, _flange.bottom - r), radius: r), math.pi / 2, math.pi / 2, false)
    ..lineTo(_flange.left, _flange.top + cut)
    ..close();
}

void _drawLidBase(Canvas canvas) {
  final flange = _flangePath();
  // The flange: the lower, flat rim of the spreader.
  canvas.drawPath(
    flange,
    Paint()
      ..shader = ui.Gradient.linear(_flange.topLeft, _flange.bottomRight, [
        const Color(0xFFE4E7EA),
        const Color(0xFFB4BAC1),
      ]),
  );
  canvas.drawPath(
    flange,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFF858C94),
  );
  for (final at in const [Offset(292, 48), Offset(292, 292), Offset(48, 292)]) {
    canvas.drawCircle(at + const Offset(.6, .6), 1.8, Paint()..color = Colors.white.withValues(alpha: .6));
    canvas.drawCircle(at, 1.8, Paint()..color = const Color(0xFF8A9198));
  }
  // The step up to the raised plate.
  final ramp = RRect.fromRectAndRadius(_plate.inflate(4), const Radius.circular(15));
  canvas.drawRRect(
    ramp,
    Paint()
      ..shader = ui.Gradient.linear(ramp.outerRect.topLeft, ramp.outerRect.bottomRight, [
        const Color(0xFFFAFBFC),
        const Color(0xFF8F969D),
      ]),
  );
  // The plate: brushed steel.
  final plate = RRect.fromRectAndRadius(_plate, const Radius.circular(11));
  canvas.drawRRect(
    plate,
    Paint()
      ..shader = ui.Gradient.linear(
        _plate.topLeft,
        _plate.bottomRight,
        [
          const Color(0xFFF2F4F6),
          const Color(0xFFC7CDD3),
          const Color(0xFFEBEEF0),
          const Color(0xFFB0B7BE),
          const Color(0xFFDDE1E5),
        ],
        [0, .3, .52, .78, 1],
      ),
  );
  canvas.save();
  canvas.clipRRect(plate);
  final rnd = math.Random(11);
  final brush = Paint()..strokeWidth = .6;
  for (var i = 0; i < 120; i++) {
    final y = _plate.top + rnd.nextDouble() * _plate.height;
    final x0 = _plate.left + rnd.nextDouble() * _plate.width * .7;
    final x1 = x0 + 40 + rnd.nextDouble() * _plate.width * .6;
    brush.color = (i.isEven ? Colors.white : const Color(0xFF50575E)).withValues(alpha: .05 + rnd.nextDouble() * .07);
    canvas.drawLine(Offset(x0, y), Offset(x1, y + (rnd.nextDouble() - .5) * .8), brush);
  }
  // The bevel of the plate: light on the upper left, shade on the lower right.
  canvas.drawRRect(
    plate.shift(const Offset(1.4, 1.4)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..color = Colors.white.withValues(alpha: .95),
  );
  canvas.drawRRect(
    plate.shift(const Offset(-1.4, -1.4)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..color = const Color(0xFF3B4147).withValues(alpha: .28),
  );
  canvas.restore();
}

TextPainter _etchText(String text, double size, {double space = 1, FontWeight weight = FontWeight.w700, Color color = const Color(0xFF5B626A), double maxWidth = 200}) {
  TextPainter make(double s) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontSize: s, height: 1, letterSpacing: space, fontWeight: weight, color: color),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  var tp = make(size);
  if (tp.width > maxWidth) tp = make(size * maxWidth / tp.width);
  return tp;
}

// One line of etching: a light edge under the dark line, as if cut into the metal.
void _etchLine(Canvas canvas, String text, double centreY, double size, {double space = 1, FontWeight weight = FontWeight.w700, double maxWidth = 200}) {
  final light = _etchText(text, size, space: space, weight: weight, color: Colors.white.withValues(alpha: .85), maxWidth: maxWidth);
  final dark = _etchText(text, size, space: space, weight: weight, maxWidth: maxWidth);
  final at = Offset(170 - dark.width / 2, centreY - dark.height / 2);
  light.paint(canvas, at + const Offset(.8, .8));
  dark.paint(canvas, at);
}

void _drawLidText(Canvas canvas, ChipLidText text) {
  _etchLine(canvas, text.above, 100, 10, space: 3.2);
  _etchLine(canvas, text.big, 142, 32, space: 1, weight: FontWeight.w800, maxWidth: 190);
  _etchLine(canvas, text.below, 184, 9.5, space: 2);
  for (var k = 0; k < text.extras.length && k < 3; k++) {
    _etchLine(canvas, text.extras[k], 206 + k * 17, 8.5, space: 2);
  }
  _etchLine(canvas, text.hint, 262, 7, space: 2.6);
}

// The room, as the steel sees it: a soft grey ceiling and walls with a window, a long strip
// light, a lamp and a dark piece of furniture, all out of focus. Made once; the lid shows a
// window on it that moves as the phone is tilted, in every direction, so the reflection slides
// and turns across the plate like a real one.
const Rect _roomBounds = Rect.fromLTWH(0, 0, 560, 560);

void _drawRoom(Canvas canvas) {
  canvas.drawRect(
    _roomBounds,
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(0, 560), [
        const Color(0xFF9AA2A9),
        const Color(0xFF59616A),
      ]),
  );
  void shape(Rect rect, double angle, Color color, double blur) {
    canvas.save();
    canvas.translate(rect.center.dx, rect.center.dy);
    canvas.rotate(angle);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: rect.width, height: rect.height), const Radius.circular(6)),
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
    );
    canvas.restore();
  }

  // The window, with its frame in the middle.
  shape(const Rect.fromLTWH(160, 170, 240, 190), -.5, Colors.white, 12);
  shape(const Rect.fromLTWH(262, 170, 12, 200), -.5, const Color(0xFFB9C1C8), 5);
  shape(const Rect.fromLTWH(150, 262, 250, 12), -.5, const Color(0xFFB9C1C8), 5);
  // A strip light across the ceiling.
  shape(const Rect.fromLTWH(380, 300, 60, 380), .75, const Color(0xE6FFFFFF), 11);
  // A lamp.
  shape(const Rect.fromLTWH(70, 400, 52, 52), 0, const Color(0xE6FFFFFF), 14);
  // Something dark.
  shape(const Rect.fromLTWH(420, 70, 150, 110), .3, const Color(0xFF1E252B), 10);
  shape(const Rect.fromLTWH(60, 90, 130, 80), -.2, const Color(0xFF2A3138), 12);
}

/// The steel heat spreader. [open] is how far it has come off (0 closed, 1 gone): it lifts a
/// little, tilts and slides away to the right. Over the lid is etched [idle], or [done] when
/// [doneAmt] says a finished scan is on show. [tilt] (each way -1..1) is how the phone is held,
/// which moves the reflection of the room on the plate.
void paintChipLid(
  Canvas canvas, {
  required double open,
  required double now,
  required bool pressed,
  required ChipLidText idle,
  ChipLidText? done,
  required double doneAmt,
  Offset tilt = Offset.zero,
  bool tiltLive = false,
}) {
  if (open >= .999) return;
  final lift = Curves.easeOut.transform(_seg(open, 0, .3));
  final slide = Curves.easeInOutCubic.transform(_seg(open, .22, 1));
  canvas.save();
  canvas.clipRect(const Rect.fromLTWH(0, 0, chipSheet, chipSheet));
  canvas.translate(170 + 400 * slide, 170 + 46 * slide);
  canvas.rotate(.14 * slide);
  final scale = 1 + .05 * lift - (pressed && open == 0 ? .012 : 0);
  canvas.scale(scale);
  canvas.translate(-170, -170);

  // Its shadow on the board: tight when it sits, soft and further off as it lifts.
  final shadow = _art(
    'lid-shadow',
    _flange.inflate(34),
    (c) => c.drawPath(
      _flangePath(),
      Paint()
        ..color = const Color(0xFF000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    ),
    scale: 1.5,
  );
  canvas.save();
  canvas.translate(2 + 26 * lift, 4 + 30 * lift);
  shadow.paint(canvas, Paint()..color = Colors.white.withValues(alpha: .34 * (1 - .55 * slide)));
  canvas.restore();

  _art('lid-base', _flange.inflate(6), _drawLidBase).paint(canvas);
  final plate = _art('room', _roomBounds, _drawRoom, scale: 1);
  // The reflection of the room on the plate (before the etching, which is cut into the metal).
  var shift = Offset(tilt.dx * 150, tilt.dy * 150);
  if (!tiltLive) {
    shift = Offset(math.sin(now * .27) * 70 + math.sin(now * .09) * 40, math.cos(now * .19) * 55);
  }
  final left = (160 + shift.dx).clamp(0.0, 320.0);
  final top = (160 + shift.dy).clamp(0.0, 320.0);
  final roomImage = plate.image;
  if (roomImage != null) {
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(_plate, const Radius.circular(11)));
    canvas.drawImageRect(
      roomImage,
      Rect.fromLTWH(left, top, 240, 240),
      _plate,
      Paint()
        ..blendMode = BlendMode.overlay
        ..filterQuality = FilterQuality.low
        ..color = Colors.white.withValues(alpha: .6),
    );
    canvas.restore();
  }

  final idleKey = 'lid-text-${idle.key}';
  final doneKey = done == null ? null : 'lid-text-${done.key}';
  _evictOthers('lid-text-', {idleKey, if (doneKey != null) doneKey});
  final idleArt = _art(idleKey, _plate, (c) => _drawLidText(c, idle));
  final doneArt = doneKey == null ? null : _art(doneKey, _plate, (c) => _drawLidText(c, done!));
  final showDone = doneArt != null && doneAmt > .01;
  if (1 - doneAmt > .01) {
    idleArt.paint(canvas, Paint()..filterQuality = FilterQuality.medium..color = Colors.white.withValues(alpha: showDone ? 1 - doneAmt : 1));
  }
  if (showDone) {
    doneArt.paint(canvas, Paint()..filterQuality = FilterQuality.medium..color = Colors.white.withValues(alpha: doneAmt));
  }

  // The bevel round the plate turns towards or away from the light as the phone is tilted: the
  // edge that faces the window brightens, the one facing away darkens.
  final angleX = (tiltLive ? tilt.dx : shift.dx / 110) * .38;
  final angleY = (tiltLive ? tilt.dy : shift.dy / 110) * .38;
  final plateShape = RRect.fromRectAndRadius(_plate, const Radius.circular(11));
  final outer = RRect.fromRectAndRadius(_plate.inflate(4), const Radius.circular(15));
  double bevel(double t) => (.5 + t * 1.8).clamp(0.0, 1.0);
  canvas.drawDRRect(
    outer,
    plateShape,
    Paint()
      ..shader = ui.Gradient.linear(
        _plate.centerLeft - const Offset(4, 0),
        _plate.centerRight + const Offset(4, 0),
        [
          Colors.white.withValues(alpha: .5 * bevel(-angleX)),
          Colors.black.withValues(alpha: .1 + .25 * (1 - bevel(-angleX))),
        ],
      ),
  );
  canvas.drawDRRect(
    outer,
    plateShape,
    Paint()
      ..shader = ui.Gradient.linear(
        _plate.topCenter - const Offset(0, 4),
        _plate.bottomCenter + const Offset(0, 4),
        [
          Colors.white.withValues(alpha: .3 * bevel(-angleY)),
          Colors.black.withValues(alpha: .06 + .18 * (1 - bevel(-angleY))),
        ],
      ),
  );
  canvas.restore();
}
