import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter/material.dart';

import 'texts.dart';

/// Kolory rozładunków (1, 2, 3…) – te same w widoku z góry i z boku.
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

  bool contains(double mx, double my) => mx >= x && mx <= x + length && my >= y && my <= y + width;
}

/// Widok przestrzeni ładunkowej z góry i z boku (przód – po lewej), z osiami i naciskami.
///
/// [moving] – przeciąganie palet (z góry: wzdłuż i w poprzek, z boku: wzdłuż); inaczej
/// przeciąganie obraca naczepę (dwa palce – obrót, przybliżenie i przesunięcie). Przybliżanie
/// i oddalanie myszą: Shift + kółko (samo kółko przewija stronę). Po puszczeniu palety –
/// [onMoved] z nowym ułożeniem.
class DeckView extends StatefulWidget {
  const DeckView({super.key, required this.plan, required this.moving, required this.onMoved});

  final Map<String, dynamic> plan;
  final bool moving;
  final ValueChanged<List<Map<String, dynamic>>> onMoved;

  @override
  State<DeckView> createState() => _DeckViewState();
}

class _DeckViewState extends State<DeckView> {
  late List<Piece> _pieces = _read();
  Piece? _dragged;

  /// Widok: przybliżenie, obrót [rad] i przesunięcie (wokół środka rysunku).
  double _zoom = 1;
  double _angle = 0;
  Offset _pan = Offset.zero;
  double _startZoom = 1;
  double _startAngle = 0;

  List<Piece> _read() =>
      [for (final p in (widget.plan['placed'] as List<dynamic>).cast<Map<String, dynamic>>()) Piece(p)];

  @override
  void didUpdateWidget(DeckView old) {
    super.didUpdateWidget(old);
    if (old.plan != widget.plan) _pieces = _read();
  }

  static const minZoom = 0.4, maxZoom = 6.0;

  /// Obrót przeciągnięciem jednym palcem / myszą: pełny obrót na ok. 600 px.
  static const _radPerPx = 2 * math.pi / 600;

  void _zoomBy(double factor, Offset focus, Offset center) {
    final zoom = (_zoom * factor).clamp(minZoom, maxZoom);
    // Punkt pod kursorem zostaje w miejscu.
    final real = zoom / _zoom;
    setState(() {
      _pan = focus - center - (focus - center - _pan) * real;
      _zoom = zoom;
    });
  }

  void _rotateBy(double radians) => setState(() => _angle = (_angle + radians) % (2 * math.pi));

  void _reset() => setState(() {
        _zoom = 1;
        _angle = 0;
        _pan = Offset.zero;
      });

  Matrix4 _matrix(Offset center) => Matrix4.identity()
    ..translate(center.dx + _pan.dx, center.dy + _pan.dy)
    ..rotateZ(_angle)
    ..scale(_zoom)
    ..translate(-center.dx, -center.dy);

  double get _length => _num(widget.plan['deck_length_m']);
  double get _width => _num(widget.plan['deck_width_m']);
  double get _inner => widget.plan['inner_height_m'] == null ? 2.7 : _num(widget.plan['inner_height_m']);

  Offset? _last;

  void _start(Offset local, double scale, {required bool top}) {
    _last = local;
    final mx = local.dx / scale - _margin, my = local.dy / scale - _margin;
    for (final piece in _pieces.reversed) {
      final hit = top ? piece.contains(mx, my) : mx >= piece.x && mx <= piece.x + piece.length;
      if (hit) return setState(() => _dragged = piece);
    }
  }

  /// Pozycje lokalne (po przybliżeniu obrazu – już w układzie rysunku), nie przesunięcie ekranu.
  void _move(Offset local, double scale, {required bool top}) {
    final piece = _dragged, last = _last;
    if (piece == null || last == null) return;
    final delta = local - last;
    _last = local;
    setState(() {
      piece.x = (piece.x + delta.dx / scale).clamp(0.0, _length - piece.length);
      if (top) piece.y = (piece.y + delta.dy / scale).clamp(0.0, _width - piece.width);
    });
  }

  void _end() {
    if (_dragged == null) return;
    setState(() => _dragged = null);
    widget.onMoved([for (final p in _pieces) p.toJson()]);
  }

  /// Odstęp rysunku od brzegu [m] (miejsce na oś przednią solówki i podpisy).
  static const _margin = 1.6;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, size) {
      final scale = size.maxWidth / (_length + 2 * _margin);
      final topHeight = (_width + 2 * _margin) * scale;
      final sideHeight = (_inner + 2.2) * scale;
      Widget view(bool top, double height) => GestureDetector(
            // Paleta pod palcem w chwili dotknięcia, nie po przesunięciu o próg rozpoznania.
            dragStartBehavior: DragStartBehavior.down,
            onPanStart: widget.moving ? (d) => _start(d.localPosition, scale, top: top) : null,
            onPanUpdate: widget.moving ? (d) => _move(d.localPosition, scale, top: top) : null,
            onPanEnd: widget.moving ? (_) => _end() : null,
            child: CustomPaint(
              key: ValueKey(top ? 'deck-top' : 'deck-side'),
              size: Size(size.maxWidth, height),
              painter: top
                  ? TopPainter(_pieces, _length, _width, scale, _margin, colors, _dragged)
                  : SidePainter(_pieces, widget.plan, _inner, scale, _margin, colors, t, _dragged),
            ),
          );
      final content = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.topView, style: Theme.of(context).textTheme.labelMedium),
        view(true, topHeight),
        Text(t.sideView, style: Theme.of(context).textTheme.labelMedium),
        view(false, sideHeight),
      ]);
      final height = topHeight + sideHeight + 40;
      final center = Offset(size.maxWidth / 2, height / 2);
      // Przesuwanie towaru: obraz stoi (z tym samym obrotem i przybliżeniem), palce przeciągają
      // palety – pozycje dotyku są przeliczane na układ rysunku przez obrót.
      final drawing = Transform(transform: _matrix(center), child: content);
      final viewer = widget.moving
          ? drawing
          : GestureDetector(
              key: const ValueKey('deck-view'),
              onScaleStart: (_) {
                _startZoom = _zoom;
                _startAngle = _angle;
              },
              onScaleUpdate: (d) => setState(() {
                if (d.pointerCount > 1) {
                  _zoom = (_startZoom * d.scale).clamp(minZoom, maxZoom);
                  _angle = _startAngle + d.rotation;
                  _pan += d.focalPointDelta;
                } else {
                  _angle += d.focalPointDelta.dx * _radPerPx;
                }
              }),
              child: drawing,
            );
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          IconButton(
              tooltip: t.rotateLeft, onPressed: () => _rotateBy(-math.pi / 2), icon: const Icon(Icons.rotate_left)),
          IconButton(
              tooltip: t.rotateRight, onPressed: () => _rotateBy(math.pi / 2), icon: const Icon(Icons.rotate_right)),
          IconButton(
              tooltip: t.zoomIn, onPressed: () => _zoomBy(1.25, center, center), icon: const Icon(Icons.zoom_in)),
          IconButton(
              tooltip: t.zoomOut, onPressed: () => _zoomBy(0.8, center, center), icon: const Icon(Icons.zoom_out)),
          IconButton(tooltip: t.resetView, onPressed: _reset, icon: const Icon(Icons.fit_screen_outlined)),
          Text('${(_angle * 180 / math.pi).round() % 360}° · ${(_zoom * 100).round()}%',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
        Listener(
          // Shift + kółko myszy: przybliżenie / oddalenie w miejscu kursora (bez przewijania strony).
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent || !HardwareKeyboard.instance.isShiftPressed) return;
            GestureBinding.instance.pointerSignalResolver.register(event, (event) {
              final scroll = event as PointerScrollEvent;
              final delta = scroll.scrollDelta.dy != 0 ? scroll.scrollDelta.dy : scroll.scrollDelta.dx;
              _zoomBy(delta < 0 ? 1.1 : 1 / 1.1, event.localPosition, center);
            });
          },
          child: ClipRect(child: SizedBox(width: size.maxWidth, height: height, child: viewer)),
        ),
      ]);
    });
  }
}

void _label(Canvas canvas, String text, Offset center, Color color, {double size = 10}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: TextStyle(color: color, fontSize: size)),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
}

/// Z góry: podłoga, palety w kolorach rozładunków z numerem rozładunku.
class TopPainter extends CustomPainter {
  TopPainter(this.pieces, this.length, this.width, this.scale, this.margin, this.colors, this.dragged);

  final List<Piece> pieces;
  final double length;
  final double width;
  final double scale;
  final double margin;
  final ColorScheme colors;
  final Piece? dragged;

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(margin * scale, margin * scale);
    final deck = origin & Size(length * scale, width * scale);
    canvas.drawRect(deck, Paint()..color = colors.surfaceVariant);
    canvas.drawRect(
        deck,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = colors.outline);
    // Ściana czołowa grubszą linią.
    canvas.drawLine(
        deck.topLeft,
        deck.bottomLeft,
        Paint()
          ..color = colors.onSurface
          ..strokeWidth = 3);
    for (final p in pieces) {
      final rect =
          Rect.fromLTWH(origin.dx + p.x * scale, origin.dy + p.y * scale, p.length * scale, p.width * scale).deflate(1);
      final color = stopColors[(p.stop - 1) % stopColors.length];
      canvas.drawRect(rect, Paint()..color = color.withOpacity(identical(p, dragged) ? 0.95 : 0.7));
      if (identical(p, dragged)) {
        canvas.drawRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = colors.onSurface);
      }
      _label(canvas, '${p.stop}', rect.center, colors.onPrimary);
    }
  }

  @override
  bool shouldRepaint(TopPainter oldDelegate) => true;
}

/// Z boku: stosy na wysokość, granica wysokości przestrzeni, podpory (siodło / osie)
/// z naciskiem i dopuszczalną wartością – na czerwono przy przekroczeniu.
class SidePainter extends CustomPainter {
  SidePainter(this.pieces, this.plan, this.inner, this.scale, this.margin, this.colors, this.texts, this.dragged);

  final List<Piece> pieces;
  final Map<String, dynamic> plan;
  final double inner;
  final double scale;
  final double margin;
  final ColorScheme colors;
  final LoadTexts texts;
  final Piece? dragged;

  @override
  void paint(Canvas canvas, Size size) {
    final length = _num(plan['deck_length_m']);
    final floor = (inner + 0.4) * scale; // linia podłogi (y w pikselach)
    final left = margin * scale;
    final space = Rect.fromLTWH(left, floor - inner * scale, length * scale, inner * scale);
    canvas.drawRect(space, Paint()..color = colors.surfaceVariant.withOpacity(0.5));
    canvas.drawRect(
        space,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = colors.outline);
    canvas.drawLine(
        Offset(left, floor),
        Offset(left + length * scale, floor),
        Paint()
          ..color = colors.onSurface
          ..strokeWidth = 3);
    for (final p in pieces) {
      final rect =
          Rect.fromLTWH(left + p.x * scale, floor - p.height * scale, p.length * scale, p.height * scale).deflate(1);
      final color = stopColors[(p.stop - 1) % stopColors.length];
      canvas.drawRect(rect, Paint()..color = color.withOpacity(identical(p, dragged) ? 0.9 : 0.45));
      canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = color);
    }
    for (final axle in (plan['axles'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>()) {
      final x = left + _num(axle['x_m']) * scale;
      final over = axle['over'] == true;
      final color = over ? colors.error : colors.primary;
      canvas.drawCircle(Offset(x, floor + 0.45 * scale), 0.4 * scale, Paint()..color = color);
      final load = texts.tonnes(_num(axle['load_kg']));
      final limit = axle['limit_kg'] == null ? '' : ' / ${texts.tonnes(_num(axle['limit_kg']))}';
      _label(canvas, '${texts.axle(axle['name'] as String)}: $load$limit', Offset(x, floor + 1.2 * scale), color,
          size: 11);
    }
  }

  @override
  bool shouldRepaint(SidePainter oldDelegate) => true;
}
