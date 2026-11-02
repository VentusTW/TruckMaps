import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

import 'texts.dart';

/// Kolory rozładunków (1, 2, 3…).
const stopColors = [Colors.blue, Colors.orange, Colors.green, Colors.purple, Colors.teal, Colors.brown];

/// Krok przesuwania palety [m].
const snapM = 0.05;

double _num(Object? value) => (value as num).toDouble();

/// Sztuka ładunku na planie (kopia do przeciągania).
class Piece {
  Piece(this.json)
      : x = _num(json['x_m']),
        y = _num(json['y_m']);

  final Map<String, dynamic> json;
  double x;
  double y;

  double get length => _num(json['length_m']);
  double get width => _num(json['width_m']);
  double get height => json['height_m'] == null ? 1.2 : _num(json['height_m']);
  int get stop => json['stop'] as int;

  Map<String, dynamic> toJson() => {...json, 'x_m': _round(x), 'y_m': _round(y)};

  static double _round(double value) => (value / snapM).round() * snapM;

  /// Narożniki prostopadłościanu: x wzdłuż od ściany czołowej, y od lewej burty, z w górę.
  List<(double, double, double)> get corners => [
        for (final z in [0.0, height])
          for (final (dx, dy) in [(0.0, 0.0), (length, 0.0), (length, width), (0.0, width)]) (x + dx, y + dy, z),
      ];
}

/// Kamera rzutu równoległego: obrót wokół osi pionowej ([yaw]) i pochylenie ([pitch]:
/// 0 – z boku, π/2 – z góry), przybliżenie i przesunięcie obrazu.
class DeckCamera {
  DeckCamera({
    required this.size,
    required this.length,
    required this.width,
    required this.height,
    this.yaw = 0,
    this.pitch = math.pi / 2,
    this.zoom = 1,
    this.pan = Offset.zero,
  });

  final Size size;
  final double length;
  final double width;
  final double height;
  final double yaw;
  final double pitch;
  final double zoom;
  final Offset pan;

  /// Piksele na metr przy przybliżeniu 1: cała naczepa (z kołami) mieści się w oknie.
  double get scale => math.min(size.width / (length + 3.2), size.height / (width + height + 3)) * zoom;

  Offset get _origin => size.center(Offset.zero) + pan;

  (double, double, double) _view((double, double, double) p) {
    final x = p.$1 - length / 2, y = p.$2 - width / 2, z = p.$3 - height / 2;
    final c = math.cos(yaw), s = math.sin(yaw);
    return (x * c - y * s, x * s + y * c, z);
  }

  Offset project((double, double, double) p) {
    final (x1, y1, z1) = _view(p);
    // Ekran w górę: lewa burta (y = 0) na dole w widoku z góry – jak patrząc z góry na jadącą w lewo naczepę.
    final sy = -(y1 * math.sin(pitch) + z1 * math.cos(pitch));
    return _origin + Offset(x1, sy) * scale;
  }

  /// Odległość w stronę patrzącego (większa – bliżej): do rysowania od najdalszych.
  double toward((double, double, double) p) {
    final (_, y1, z1) = _view(p);
    return -y1 * math.cos(pitch) + z1 * math.sin(pitch);
  }

  /// Kierunek do patrzącego w układzie naczepy – do ukrywania tylnych ścian.
  (double, double, double) get viewer {
    final vy = -math.cos(pitch), vz = math.sin(pitch);
    final c = math.cos(-yaw), s = math.sin(-yaw);
    return (-vy * s, vy * c, vz);
  }

  /// Punkt podłogi (z = 0) pod punktem ekranu; `null`, gdy widok jest prawie z boku.
  (double, double)? floorAt(Offset screen) {
    if (math.sin(pitch) < 0.25) return null;
    final local = (screen - _origin) / scale;
    final z1 = -height / 2;
    final y1 = (-local.dy - z1 * math.cos(pitch)) / math.sin(pitch);
    final x1 = local.dx;
    final c = math.cos(yaw), s = math.sin(yaw);
    return (x1 * c + y1 * s + length / 2, -x1 * s + y1 * c + width / 2);
  }

  /// Przesunięcie na ekranie → przesunięcie wzdłuż naczepy (widok prawie z boku).
  double alongFromScreen(Offset delta) => delta.dx * math.cos(yaw) / scale;
}

/// Jeden widok 3D przestrzeni ładunkowej (przód – ściana czołowa), z osiami i naciskami.
///
/// Tryb „Obróć naczepę”: przeciąganie obraca (w poziomie – wokół osi pionowej, w pionie –
/// pochylenie od widoku z boku do widoku z góry), dwa palce przybliżają i przesuwają,
/// myszą Shift + kółko przybliża w miejscu kursora. [moving] – przeciąganie palet po
/// podłodze; po puszczeniu – [onMoved] z nowym ułożeniem.
class DeckView extends StatefulWidget {
  const DeckView({super.key, required this.plan, required this.moving, required this.onMoved});

  final Map<String, dynamic> plan;
  final bool moving;
  final ValueChanged<List<Map<String, dynamic>>> onMoved;

  @override
  State<DeckView> createState() => _DeckViewState();
}

/// Ustawienia widoku: 3D (z ukosa), z góry, z boku.
const view3d = (-0.5, 0.6), viewTop = (0.0, math.pi / 2), viewSide = (0.0, 0.0);

class _DeckViewState extends State<DeckView> {
  late List<Piece> _pieces = _read();
  Piece? _dragged;
  (double, double)? _grab;

  double _yaw = view3d.$1;
  double _pitch = view3d.$2;
  double _zoom = 1;
  Offset _pan = Offset.zero;
  double _startZoom = 1;
  double _startYaw = 0;

  static const minZoom = 0.4, maxZoom = 6.0;

  /// Obrót przeciągnięciem: pełny obrót na ok. 600 px.
  static const _radPerPx = 2 * math.pi / 600;

  List<Piece> _read() =>
      [for (final p in (widget.plan['placed'] as List<dynamic>).cast<Map<String, dynamic>>()) Piece(p)];

  @override
  void didUpdateWidget(DeckView old) {
    super.didUpdateWidget(old);
    if (old.plan != widget.plan) _pieces = _read();
  }

  double get _length => _num(widget.plan['deck_length_m']);
  double get _width => _num(widget.plan['deck_width_m']);
  double get _inner => widget.plan['inner_height_m'] == null ? 2.7 : _num(widget.plan['inner_height_m']);

  DeckCamera _camera(Size size) => DeckCamera(
      size: size, length: _length, width: _width, height: _inner, yaw: _yaw, pitch: _pitch, zoom: _zoom, pan: _pan);

  void _zoomBy(double factor, Offset focus, Size size) {
    final zoom = (_zoom * factor).clamp(minZoom, maxZoom);
    final real = zoom / _zoom, center = size.center(Offset.zero);
    setState(() {
      _pan = focus - center - (focus - center - _pan) * real;
      _zoom = zoom;
    });
  }

  void _preset((double, double) view) => setState(() {
        _yaw = view.$1;
        _pitch = view.$2;
        _zoom = 1;
        _pan = Offset.zero;
      });

  /// Paleta pod palcem: najbliższa patrzącemu, której rzut zawiera punkt.
  Piece? _hit(Offset point, DeckCamera camera) {
    Piece? best;
    var bestDepth = double.negativeInfinity;
    for (final piece in _pieces) {
      final hull = _hull([for (final c in piece.corners) camera.project(c)]);
      if (!(Path()..addPolygon(hull, true)).contains(point)) continue;
      final depth = camera.toward((piece.x + piece.length / 2, piece.y + piece.width / 2, piece.height / 2));
      if (depth > bestDepth) {
        best = piece;
        bestDepth = depth;
      }
    }
    return best;
  }

  void _start(Offset local, DeckCamera camera) {
    final piece = _hit(local, camera);
    if (piece == null) return;
    setState(() => _dragged = piece);
    _grab = camera.floorAt(local);
  }

  void _move(DragUpdateDetails d, DeckCamera camera) {
    final piece = _dragged;
    if (piece == null) return;
    final floor = camera.floorAt(d.localPosition), grab = _grab;
    setState(() {
      if (floor != null && grab != null) {
        piece.x += floor.$1 - grab.$1;
        piece.y += floor.$2 - grab.$2;
        _grab = floor;
      } else {
        piece.x += camera.alongFromScreen(d.delta);
      }
      piece.x = piece.x.clamp(0.0, _length - piece.length);
      piece.y = piece.y.clamp(0.0, _width - piece.width);
    });
  }

  void _end() {
    if (_dragged == null) return;
    setState(() => _dragged = null);
    widget.onMoved([for (final p in _pieces) p.toJson()]);
  }

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, (constraints.maxWidth * 0.55).clamp(240.0, 560.0));
      final camera = _camera(size);
      final painter = DeckPainter(_pieces, widget.plan, camera, colors, t, _dragged);
      final drawing = CustomPaint(key: const ValueKey('deck-3d'), size: size, painter: painter);
      // Rysunek przejmuje dotyk od razu – inaczej ruch w pionie przewijałby stronę zamiast
      // pochylać naczepę (stronę przewija się poza rysunkiem albo kółkiem myszy).
      final gestures = RawGestureDetector(
        key: const ValueKey('deck-view'),
        gestures: widget.moving
            ? {
                _EagerPan: GestureRecognizerFactoryWithHandlers<_EagerPan>(_EagerPan.new, (r) {
                  r
                    // Paleta pod palcem w chwili dotknięcia, nie po przesunięciu o próg rozpoznania.
                    ..dragStartBehavior = DragStartBehavior.down
                    ..onStart = ((d) {
                      _start(d.localPosition, camera);
                    })
                    ..onUpdate = ((d) {
                      _move(d, camera);
                    })
                    ..onEnd = ((_) {
                      _end();
                    });
                }),
              }
            : {
                _EagerScale: GestureRecognizerFactoryWithHandlers<_EagerScale>(_EagerScale.new, (r) {
                  r
                    ..onStart = (_) {
                      _startZoom = _zoom;
                      _startYaw = _yaw;
                    }
                    ..onUpdate = (d) => setState(() {
                          if (d.pointerCount > 1) {
                            _zoom = (_startZoom * d.scale).clamp(minZoom, maxZoom);
                            _yaw = _startYaw + d.rotation;
                            _pan += d.focalPointDelta;
                          } else {
                            _yaw += d.focalPointDelta.dx * _radPerPx;
                            _pitch = (_pitch - d.focalPointDelta.dy * _radPerPx).clamp(0.0, math.pi / 2);
                          }
                        });
                }),
              },
        child: drawing,
      );
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final (label, view) in [(t.view3d, view3d), (t.topView, viewTop), (t.sideView, viewSide)])
            OutlinedButton(onPressed: () => _preset(view), child: Text(label)),
          IconButton(
              tooltip: t.zoomIn,
              onPressed: () => _zoomBy(1.25, size.center(Offset.zero), size),
              icon: const Icon(Icons.zoom_in)),
          IconButton(
              tooltip: t.zoomOut,
              onPressed: () => _zoomBy(0.8, size.center(Offset.zero), size),
              icon: const Icon(Icons.zoom_out)),
          Text(
              t.viewState(
                  (_yaw * 180 / math.pi).round() % 360, (_pitch * 180 / math.pi).round(), (_zoom * 100).round()),
              style: Theme.of(context).textTheme.bodySmall),
        ]),
        Listener(
          // Shift + kółko myszy: przybliżenie / oddalenie w miejscu kursora (bez przewijania strony).
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent || !HardwareKeyboard.instance.isShiftPressed) return;
            GestureBinding.instance.pointerSignalResolver.register(event, (event) {
              final scroll = event as PointerScrollEvent;
              final delta = scroll.scrollDelta.dy != 0 ? scroll.scrollDelta.dy : scroll.scrollDelta.dx;
              _zoomBy(delta < 0 ? 1.1 : 1 / 1.1, event.localPosition, size);
            });
          },
          child: ClipRect(child: gestures),
        ),
      ]);
    });
  }
}

/// Przesuwanie i obrót bez czekania na próg ruchu – wygrywa z przewijaniem strony.
class _EagerPan extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _EagerScale extends ScaleGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// Otoczka wypukła punktów (do sprawdzenia, czy dotknięto palety).
List<Offset> _hull(List<Offset> points) {
  final sorted = [...points]..sort((a, b) => a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
  double cross(Offset o, Offset a, Offset b) => (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
  final lower = <Offset>[], upper = <Offset>[];
  for (final p in sorted) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  for (final p in sorted.reversed) {
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  return [...lower.sublist(0, lower.length - 1), ...upper.sublist(0, upper.length - 1)];
}

void _label(Canvas canvas, String text, Offset center, Color color, {double size = 10}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w600)),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
}

/// Rysunek 3D: podłoga i obrys przestrzeni, ściana czołowa, koła podpór z naciskiem
/// (na czerwono przy przekroczeniu), palety jako bryły w kolorach rozładunków.
class DeckPainter extends CustomPainter {
  DeckPainter(this.pieces, this.plan, this.camera, this.colors, this.texts, this.dragged);

  final List<Piece> pieces;
  final Map<String, dynamic> plan;
  final DeckCamera camera;
  final ColorScheme colors;
  final LoadTexts texts;
  final Piece? dragged;

  // Ściany bryły: indeksy narożników i normalna.
  static const _faces = [
    ([0, 1, 2, 3], (0.0, 0.0, -1.0)),
    ([4, 5, 6, 7], (0.0, 0.0, 1.0)),
    ([0, 1, 5, 4], (0.0, -1.0, 0.0)),
    ([3, 2, 6, 7], (0.0, 1.0, 0.0)),
    ([0, 3, 7, 4], (-1.0, 0.0, 0.0)),
    ([1, 2, 6, 5], (1.0, 0.0, 0.0)),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final l = camera.length, w = camera.width, h = camera.height;
    final viewer = camera.viewer;
    double facing((double, double, double) n) => n.$1 * viewer.$1 + n.$2 * viewer.$2 + n.$3 * viewer.$3;
    Path polygon(List<(double, double, double)> points) =>
        Path()..addPolygon([for (final p in points) camera.project(p)], true);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..color = colors.outline;

    // Koła i naciski pod podłogą.
    for (final axle in (plan['axles'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>()) {
      final x = _num(axle['x_m']);
      final color = axle['over'] == true ? colors.error : colors.primary;
      for (final y in [0.0, w]) {
        canvas.drawCircle(camera.project((x, y, -0.5)), 0.45 * camera.scale, Paint()..color = color);
      }
      final load = texts.tonnes(_num(axle['load_kg']));
      final limit = axle['limit_kg'] == null ? '' : ' / ${texts.tonnes(_num(axle['limit_kg']))}';
      _label(canvas, '${texts.axle(axle['name'] as String)}: $load$limit', camera.project((x, w / 2, -1.3)), color,
          size: 11);
    }
    // Podłoga, ściana czołowa i obrys wysokości przestrzeni.
    final floor = [(0.0, 0.0, 0.0), (l, 0.0, 0.0), (l, w, 0.0), (0.0, w, 0.0)];
    canvas.drawPath(polygon(floor), Paint()..color = colors.surfaceVariant);
    canvas.drawPath(polygon(floor), line);
    final wall = [(0.0, 0.0, 0.0), (0.0, w, 0.0), (0.0, w, h), (0.0, 0.0, h)];
    canvas.drawPath(polygon(wall), Paint()..color = colors.onSurface.withOpacity(0.12));
    canvas.drawPath(
        polygon(wall),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colors.onSurface);
    for (final (a, b) in [
      ((l, 0.0, 0.0), (l, 0.0, h)),
      ((l, w, 0.0), (l, w, h)),
      ((0.0, 0.0, h), (l, 0.0, h)),
      ((0.0, w, h), (l, w, h)),
      ((l, 0.0, h), (l, w, h)),
    ]) {
      canvas.drawLine(camera.project(a), camera.project(b), line..color = colors.outline.withOpacity(0.5));
    }
    _label(canvas, texts.front, camera.project((0, w / 2, h + 0.3)), colors.onSurface);

    // Palety od najdalszej.
    final sorted = [...pieces]..sort((a, b) => camera
        .toward((a.x + a.length / 2, a.y + a.width / 2, a.height / 2)).compareTo(
            camera.toward((b.x + b.length / 2, b.y + b.width / 2, b.height / 2))));
    for (final piece in sorted) {
      final corners = piece.corners;
      final base = stopColors[(piece.stop - 1) % stopColors.length];
      final selected = identical(piece, dragged);
      for (final (indices, normal) in _faces) {
        final light = facing(normal);
        if (light <= 1e-6) continue;
        final path = polygon([for (final i in indices) corners[i]]);
        final shade = normal.$3 > 0 ? 1.0 : 0.65 + 0.2 * light;
        final color = Color.lerp(Colors.black, base, shade)!.withOpacity(selected ? 0.95 : 0.85);
        canvas.drawPath(path, Paint()..color = color);
        canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = selected ? 2 : 0.8
              ..color = selected ? colors.onSurface : Colors.black26);
      }
      _label(canvas, '${piece.stop}',
          camera.project((piece.x + piece.length / 2, piece.y + piece.width / 2, piece.height)), Colors.white);
    }
  }

  @override
  bool shouldRepaint(DeckPainter oldDelegate) => true;
}
