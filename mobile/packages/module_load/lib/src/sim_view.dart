import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'texts.dart';

/// Widok symulatora załadunku.
enum SimView { iso, top, section }

/// Grupa ładunku wg masy sztuki (jak w PDF z serwera).
enum CargoGroup { heavy, medium, light, bulk }

const heavyKg = 900.0;
const mediumKg = 500.0;

const groupColors = {
  CargoGroup.heavy: Color(0xFF1E4FD8),
  CargoGroup.medium: Color(0xFF16A34A),
  CargoGroup.light: Color(0xFF38BDF8),
  CargoGroup.bulk: Color(0xFFF59E0B),
};

const strapColor = Color(0xFFE5532D);
const beamColor = Color(0xFFD62828);
const cogColor = Color(0xFFE11D2E);

double _d(Object? value, [double fallback = 0]) => value is num ? value.toDouble() : fallback;

/// Sztuka na planie (z odpowiedzi serwera) z grupą.
class SimPiece {
  SimPiece(Map<String, dynamic> json, List<String> kinds)
      : x = _d(json['x_m']),
        y = _d(json['y_m']),
        length = _d(json['length_m']),
        width = _d(json['width_m']),
        height = _d(json['height_m'], 1.2),
        pieces = (json['pieces'] as int?) ?? 1,
        stop = (json['stop'] as int?) ?? 1,
        weight = _d(json['weight_kg']),
        group = _group(json, kinds);

  final double x, y, length, width, height, weight;
  final int pieces, stop;
  final CargoGroup group;

  static CargoGroup _group(Map<String, dynamic> json, List<String> kinds) {
    final item = (json['item'] as int?) ?? 0;
    if (item < kinds.length && kinds[item] == 'custom') return CargoGroup.bulk;
    final each = _d(json['weight_kg']) / math.max(1, (json['pieces'] as int?) ?? 1);
    return each >= heavyKg
        ? CargoGroup.heavy
        : each >= mediumKg
            ? CargoGroup.medium
            : CargoGroup.light;
  }
}

/// Dane rysunku wyciągnięte z planu.
class SimScene {
  SimScene(Map<String, dynamic> plan, List<String> kinds)
      : length = _d(plan['deck_length_m'], 13.6),
        width = _d(plan['deck_width_m'], 2.48),
        inner = _d(plan['inner_height_m'], 2.7),
        cog = plan['cog_m'] == null ? null : _d(plan['cog_m']),
        pieces = [
          for (final p in (plan['placed'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
            SimPiece(p, kinds)
        ],
        rows = (plan['rows'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>(),
        axles = (plan['axles'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>(),
        tractor = plan['tractor'] != null;

  final double length, width, inner;
  final double? cog;
  final List<SimPiece> pieces;
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> axles;
  final bool tractor;

  /// Położenia pasów wzdłuż przestrzeni (równo w każdym rzędzie).
  List<double> get straps => [
        for (final r in rows)
          for (var k = 0; k < ((r['straps'] as int?) ?? 0); k++)
            _d(r['x_m']) + _d(r['length_m']) * (k + 1) / (((r['straps'] as int?) ?? 0) + 1),
      ];

  /// Belki rozporowe: za każdym rozładunkiem poza ostatnim (granica rozładunków).
  List<double> get beams {
    final sorted = [...pieces]..sort((a, b) => a.x.compareTo(b.x));
    final found = <double>[];
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i].stop != sorted[i - 1].stop && sorted[i].x > sorted[i - 1].x) found.add(sorted[i].x);
    }
    return found;
  }

  /// Wysokość ładunku w miejscu środka ciężkości (do kuli w izometrii i przekroju).
  double get cogHeight {
    final c = cog;
    if (c == null || pieces.isEmpty) return 0.6;
    final weight = pieces.fold<double>(0, (s, p) => s + p.weight);
    if (weight <= 0) return 0.6;
    return pieces.fold<double>(0, (s, p) => s + p.height / 2 * p.weight) / weight;
  }

  /// Środek zespołu osi naczepy (do kół na rysunku).
  double? get trailerAxles {
    for (final a in axles) {
      if (a['name'] == 'trailer_axles' || a['name'] == 'rear_axles') return _d(a['x_m']);
    }
    return null;
  }
}

/// Rysunek symulatora: izometria, rzut z góry albo przekrój (z boku).
class SimPainter extends CustomPainter {
  SimPainter({
    required this.scene,
    required this.view,
    required this.straps,
    required this.vectors,
    required this.texts,
    required this.dark,
  });

  final SimScene scene;
  final SimView view;
  final bool straps;
  final bool vectors;
  final LoadTexts texts;
  final bool dark;

  Color get _ink => dark ? const Color(0xFFE2E8F0) : const Color(0xFF334155);
  Color get _frame => dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
  Color get _floor => dark ? const Color(0xFF334155) : const Color(0xFFCBD5E1);

  @override
  void paint(Canvas canvas, Size size) {
    switch (view) {
      case SimView.iso:
        _iso(canvas, size);
      case SimView.top:
        _top(canvas, size);
      case SimView.section:
        _section(canvas, size);
    }
  }

  // ---------------------------------------------------------------- izometria

  static const _ex = Offset(0.93, 0.36); // wzdłuż (w prawo w dół)
  static const _ey = Offset(-0.62, 0.42); // w poprzek (w stronę patrzącego)
  static const _ez = Offset(0, -1); // w górę

  Offset _p(double x, double y, double z) => _ex * x + _ey * y + _ez * z;

  void _iso(Canvas canvas, Size size) {
    final s = scene;
    const floorZ = 1.2; // podłoga nad jezdnią
    // Dopasowanie: skrajne punkty naczepy z kołami i dachem.
    final corners = [
      for (final x in [-1.0, s.length + 0.3])
        for (final y in [0.0, s.width])
          for (final z in [-floorZ, s.inner + 0.2]) _p(x, y, z),
    ];
    final minX = corners.map((o) => o.dx).reduce(math.min), maxX = corners.map((o) => o.dx).reduce(math.max);
    final minY = corners.map((o) => o.dy).reduce(math.min), maxY = corners.map((o) => o.dy).reduce(math.max);
    final scale = math.min(size.width / (maxX - minX), size.height / (maxY - minY)) * 0.94;
    final origin = Offset(
      (size.width - (maxX - minX) * scale) / 2 - minX * scale,
      (size.height - (maxY - minY) * scale) / 2 - minY * scale,
    );
    Offset pt(double x, double y, double z) => origin + _p(x, y, z) * scale;
    Path poly(List<Offset> points) => Path()..addPolygon(points, true);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = _frame;

    // Cień i podwozie.
    canvas.drawPath(
      poly([
        pt(-0.2, -0.2, -floorZ),
        pt(s.length + 0.3, -0.2, -floorZ),
        pt(s.length + 0.3, s.width + 0.3, -floorZ),
        pt(-0.2, s.width + 0.3, -floorZ)
      ]),
      Paint()..color = Colors.black.withOpacity(dark ? 0.35 : 0.10),
    );
    final chassis = Paint()..color = dark ? const Color(0xFF1E293B) : const Color(0xFF475569);
    canvas.drawPath(
        poly([pt(0, s.width, 0), pt(s.length, s.width, 0), pt(s.length, s.width, -0.35), pt(0, s.width, -0.35)]),
        chassis);
    // Koła (strona bliższa) w zespole osi.
    final axle = s.trailerAxles ?? s.length * 0.7;
    final wheel = Paint()..color = const Color(0xFF111827);
    final rim = Paint()..color = const Color(0xFFCBD5E1);
    for (final dx in [-1.31, 0.0, 1.31]) {
      final c = pt(axle + dx, s.width, -0.65);
      canvas.drawOval(Rect.fromCenter(center: c, width: 0.95 * scale, height: 1.0 * scale), wheel);
      canvas.drawOval(Rect.fromCenter(center: c, width: 0.45 * scale, height: 0.5 * scale), rim);
    }
    // Podpora (nogi) z przodu.
    canvas.drawLine(pt(2.4, s.width, -0.35), pt(2.4, s.width, -floorZ), line..strokeWidth = 2.5);
    line.strokeWidth = 1.2;

    // Podłoga, ściana czołowa i dalsza burta (rama).
    canvas.drawPath(
        poly([pt(0, 0, 0), pt(s.length, 0, 0), pt(s.length, s.width, 0), pt(0, s.width, 0)]), Paint()..color = _floor);
    canvas.drawPath(
      poly([pt(0, 0, 0), pt(0, s.width, 0), pt(0, s.width, s.inner), pt(0, 0, s.inner)]),
      Paint()..color = dark ? const Color(0xFF475569) : const Color(0xFFF1F5F9),
    );
    canvas.drawPath(poly([pt(0, 0, 0), pt(0, s.width, 0), pt(0, s.width, s.inner), pt(0, 0, s.inner)]), line);
    canvas.drawPath(
      poly([pt(0, 0, 0), pt(s.length, 0, 0), pt(s.length, 0, s.inner), pt(0, 0, s.inner)]),
      Paint()..color = (dark ? Colors.white : const Color(0xFF94A3B8)).withOpacity(0.12),
    );
    for (var x = 0.0; x <= s.length + 0.01; x += s.length / 4) {
      canvas.drawLine(pt(x, 0, 0), pt(x, 0, s.inner), line);
    }
    canvas.drawLine(pt(0, 0, s.inner), pt(s.length, 0, s.inner), line);

    // Ładunek: od najdalszych (mały x + y) do najbliższych.
    final order = [...s.pieces]..sort((a, b) => (a.x + a.y * 3).compareTo(b.x + b.y * 3));
    for (final p in order) {
      _box(canvas, pt, p);
    }

    // Pasy: przez górę ładunku i w dół po bliższej burcie.
    if (straps) {
      final strap = Paint()
        ..color = strapColor
        ..strokeWidth = math.max(1.5, 0.06 * scale)
        ..style = PaintingStyle.stroke;
      for (final x in s.straps) {
        final h = _heightAt(x);
        if (h <= 0) continue;
        canvas.drawPath(
          Path()
            ..moveTo(pt(x, 0, h).dx, pt(x, 0, h).dy)
            ..lineTo(pt(x, s.width, h).dx, pt(x, s.width, h).dy)
            ..lineTo(pt(x, s.width, 0).dx, pt(x, s.width, 0).dy),
          strap,
        );
      }
    }
    // Belki rozporowe na granicach rozładunków.
    for (final x in s.beams) {
      canvas.drawLine(
          pt(x, 0, 1.0),
          pt(x, s.width, 1.0),
          Paint()
            ..color = beamColor
            ..strokeWidth = 4);
    }

    // Rama dachu i bliższa burta (cienko, żeby nie zasłaniać ładunku).
    final roof = Paint()
      ..color = _frame.withOpacity(0.7)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
        poly([pt(0, 0, s.inner), pt(s.length, 0, s.inner), pt(s.length, s.width, s.inner), pt(0, s.width, s.inner)]),
        roof);
    for (var x = 0.0; x <= s.length + 0.01; x += s.length / 6) {
      canvas.drawLine(pt(x, 0, s.inner), pt(x, s.width, s.inner), roof);
    }
    canvas.drawLine(pt(s.length, s.width, 0), pt(s.length, s.width, s.inner), roof);
    canvas.drawLine(pt(s.length, 0, 0), pt(s.length, 0, s.inner), roof);
    canvas.drawLine(pt(0, s.width, s.inner), pt(0, s.width, 0), roof);

    if (vectors && s.cog != null) {
      final c = pt(s.cog!, s.width / 2, s.cogHeight);
      _cogBall(canvas, c, math.max(7, 0.32 * scale));
      final arrow = 1.8 * scale;
      _arrow(canvas, c, c - _ex / _ex.distance * arrow, '0.8 g');
      _arrow(canvas, c, c + _ey / _ey.distance * arrow * 0.7, '0.5 g');
      _arrow(canvas, c, c - _ey / _ey.distance * arrow * 0.7, '0.5 g');
      _arrow(canvas, c, c + const Offset(0, 1) * arrow * 0.7, '1 g');
    }
  }

  double _heightAt(double x) {
    var h = 0.0;
    for (final p in scene.pieces) {
      if (x >= p.x && x <= p.x + p.length) h = math.max(h, p.height);
    }
    return h;
  }

  void _box(Canvas canvas, Offset Function(double, double, double) pt, SimPiece p) {
    final base = groupColors[p.group]!;
    const pallet = 0.14;
    final x0 = p.x + 0.02, x1 = p.x + p.length - 0.02, y0 = p.y + 0.02, y1 = p.y + p.width - 0.02;
    void face(List<Offset> points, Color color) {
      canvas.drawPath(Path()..addPolygon(points, true), Paint()..color = color);
      canvas.drawPath(
        Path()..addPolygon(points, true),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = Colors.black.withOpacity(0.25),
      );
    }

    final wood = p.group == CargoGroup.bulk ? null : const Color(0xFFC08A4A);
    final bottom = wood == null ? 0.0 : pallet;
    if (wood != null) {
      face([pt(x0, y1, 0), pt(x1, y1, 0), pt(x1, y1, pallet), pt(x0, y1, pallet)], wood);
      face([pt(x1, y0, 0), pt(x1, y1, 0), pt(x1, y1, pallet), pt(x1, y0, pallet)], _shade(wood, 0.8));
    }
    final top = p.height;
    face([pt(x0, y1, bottom), pt(x1, y1, bottom), pt(x1, y1, top), pt(x0, y1, top)], base);
    face([pt(x1, y0, bottom), pt(x1, y1, bottom), pt(x1, y1, top), pt(x1, y0, top)], _shade(base, 0.78));
    face([pt(x0, y0, top), pt(x1, y0, top), pt(x1, y1, top), pt(x0, y1, top)], _shade(base, 1.18));
    // Warstwy w stosie.
    for (var k = 1; k < p.pieces; k++) {
      final z = top * k / p.pieces;
      canvas.drawLine(
          pt(x0, y1, z),
          pt(x1, y1, z),
          Paint()
            ..color = const Color(0xFFC08A4A)
            ..strokeWidth = 2);
    }
  }

  static Color _shade(Color c, double f) => Color.fromARGB(
        c.alpha,
        (c.red * f).round().clamp(0, 255),
        (c.green * f).round().clamp(0, 255),
        (c.blue * f).round().clamp(0, 255),
      );

  void _cogBall(Canvas canvas, Offset c, double r) {
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.35, -0.35),
          colors: [Color(0xFFFF8A8A), cogColor, Color(0xFF8B0000)],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
  }

  void _arrow(Canvas canvas, Offset from, Offset to, String label) {
    final paint = Paint()
      ..color = dark ? Colors.white : const Color(0xFF0F172A)
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(from, to, paint);
    final dir = (to - from) / (to - from).distance;
    final normal = Offset(-dir.dy, dir.dx);
    canvas.drawPath(
      Path()
        ..moveTo(to.dx, to.dy)
        ..lineTo((to - dir * 9 + normal * 5).dx, (to - dir * 9 + normal * 5).dy)
        ..lineTo((to - dir * 9 - normal * 5).dx, (to - dir * 9 - normal * 5).dy)
        ..close(),
      Paint()..color = paint.color,
    );
    _text(canvas, label, to + dir * 12, paint.color, bold: true);
  }

  void _text(Canvas canvas, String text, Offset center, Color color, {double size = 11, bool bold = false}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w500),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
  }

  // ---------------------------------------------------------------- rzut z góry

  void _top(Canvas canvas, Size size) {
    final s = scene;
    final cab = s.tractor ? 2.3 : 0.0;
    final total = cab + s.length + 0.6;
    final scale = math.min(size.width / total, size.height / (s.width + 2.0));
    final left = (size.width - total * scale) / 2 + cab * scale;
    final top = (size.height - s.width * scale) / 2 + 0.2 * scale;
    Offset pt(double x, double y) => Offset(left + x * scale, top + y * scale);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = _frame;

    // Siatka tła (jak na planie technicznym).
    final grid = Paint()
      ..color = _frame.withOpacity(0.12)
      ..strokeWidth = 0.6;
    for (var x = 0.0; x < size.width; x += 0.5 * scale) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 0.5 * scale) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (s.tractor) {
      final body = RRect.fromRectAndRadius(
        Rect.fromLTWH(left - 2.2 * scale, top + 0.05 * scale, 2.0 * scale, (s.width - 0.1) * scale),
        Radius.circular(0.35 * scale),
      );
      canvas.drawRRect(body, Paint()..color = dark ? const Color(0xFF475569) : Colors.white);
      canvas.drawRRect(body, line);
      canvas.drawRect(
        Rect.fromLTWH(left - 1.6 * scale, top + 0.7 * scale, 0.7 * scale, (s.width - 1.4) * scale),
        Paint()..color = _frame.withOpacity(0.4),
      );
    }
    canvas.drawRect(Rect.fromPoints(pt(0, 0), pt(s.length, s.width)), Paint()..color = _floor.withOpacity(0.6));
    canvas.drawRect(Rect.fromPoints(pt(0, 0), pt(s.length, s.width)), line..strokeWidth = 2);
    line.strokeWidth = 1.2;
    for (final p in s.pieces) {
      final rect = Rect.fromPoints(pt(p.x + 0.02, p.y + 0.02), pt(p.x + p.length - 0.02, p.y + p.width - 0.02));
      canvas.drawRect(rect, Paint()..color = groupColors[p.group]!);
      // Deski palety.
      if (p.group != CargoGroup.bulk) {
        final slat = Paint()
          ..color = Colors.black.withOpacity(0.22)
          ..strokeWidth = 1;
        for (var k = 1; k < 5; k++) {
          final y = rect.top + rect.height * k / 5;
          canvas.drawLine(Offset(rect.left + 3, y), Offset(rect.right - 3, y), slat);
        }
      }
      if (p.pieces > 1) _text(canvas, '${p.pieces}L', rect.center, Colors.white, size: 10, bold: true);
    }
    if (straps) {
      final strap = Paint()
        ..color = strapColor
        ..strokeWidth = math.max(2, 0.07 * scale);
      for (final x in s.straps) {
        canvas.drawLine(pt(x, -0.05), pt(x, s.width + 0.05), strap);
      }
    }
    for (final x in s.beams) {
      _beam(canvas, pt(x, 0), pt(x, s.width), scale);
    }
    // Wymiary.
    final dim = _ink;
    _dimension(canvas, pt(0, -0.75), pt(s.length, -0.75), texts.metres(s.length), dim);
    _dimension(canvas, pt(s.length + 0.35, 0), pt(s.length + 0.35, s.width), texts.metres(s.width), dim,
        vertical: true);
    if (vectors && s.cog != null) {
      final c = pt(s.cog!, s.width / 2);
      final arrow = 1.6 * scale;
      _arrow(canvas, c, c - Offset(arrow, 0), '0.8 g');
      _arrow(canvas, c, c + Offset(arrow * 0.75, 0), '0.5 g');
      _arrow(canvas, c, c - Offset(0, s.width / 2 * scale - 4), '0.5 g');
      _arrow(canvas, c, c + Offset(0, s.width / 2 * scale - 4), '0.5 g');
      canvas.drawCircle(c, 0.28 * scale, Paint()..color = cogColor);
      _text(canvas, 'CoG', c, Colors.white, size: math.max(8, 0.17 * scale), bold: true);
    }
  }

  void _beam(Canvas canvas, Offset a, Offset b, double scale) {
    final paint = Paint()
      ..color = beamColor
      ..strokeWidth = math.max(3, 0.1 * scale)
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(a, b, paint);
  }

  void _dimension(Canvas canvas, Offset a, Offset b, String label, Color color, {bool vertical = false}) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(a, b, paint);
    final tick = vertical ? const Offset(5, 0) : const Offset(0, 5);
    canvas.drawLine(a - tick, a + tick, paint);
    canvas.drawLine(b - tick, b + tick, paint);
    final mid = (a + b) / 2;
    if (vertical) {
      canvas.save();
      canvas.translate(mid.dx + 12, mid.dy);
      canvas.rotate(math.pi / 2);
      _text(canvas, label, Offset.zero, color, size: 11, bold: true);
      canvas.restore();
    } else {
      _text(canvas, label, mid - const Offset(0, 10), color, size: 11, bold: true);
    }
  }

  // ---------------------------------------------------------------- przekrój (z boku)

  void _section(Canvas canvas, Size size) {
    final s = scene;
    const floor = 1.2;
    final total = s.length + 1.4;
    final scale = math.min(size.width / total, size.height / (s.inner + floor + 1.0));
    final left = (size.width - s.length * scale) / 2;
    final ground = size.height - 0.5 * scale;
    Offset pt(double x, double z) => Offset(left + x * scale, ground - (z + floor) * scale);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = _frame;

    canvas.drawLine(Offset(0, ground), Offset(size.width, ground), line);
    // Podwozie, koła, podpory.
    canvas.drawRect(Rect.fromPoints(pt(0, 0), pt(s.length, -0.3)), Paint()..color = const Color(0xFF334155));
    final axle = s.trailerAxles ?? s.length * 0.7;
    for (final dx in [-1.31, 0.0, 1.31]) {
      final c = Offset(left + (axle + dx) * scale, ground - 0.5 * scale);
      canvas.drawCircle(c, 0.5 * scale, Paint()..color = const Color(0xFF111827));
      canvas.drawCircle(c, 0.24 * scale, Paint()..color = const Color(0xFFCBD5E1));
    }
    canvas.drawLine(pt(2.4, -0.3), Offset(left + 2.4 * scale, ground), line..strokeWidth = 3);
    line.strokeWidth = 1.4;
    // Przestrzeń ładunkowa: ściana czołowa, dach, drzwi.
    canvas.drawRect(Rect.fromPoints(pt(0, 0), pt(s.length, s.inner)), Paint()..color = _floor.withOpacity(0.35));
    canvas.drawRect(Rect.fromPoints(pt(0, 0), pt(s.length, s.inner)), line);
    canvas.drawRect(Rect.fromPoints(pt(-0.08, 0), pt(0, s.inner)), Paint()..color = _frame);
    for (var x = s.length / 4; x < s.length - 0.1; x += s.length / 4) {
      canvas.drawLine(
          pt(x, 0),
          pt(x, s.inner),
          Paint()
            ..color = _frame.withOpacity(0.5)
            ..strokeWidth = 2);
    }
    // Ładunek (sztuki z bliższej strony zasłaniają dalsze – rysujemy wszystkie, przezroczyście).
    final order = [...s.pieces]..sort((a, b) => a.y.compareTo(b.y));
    for (final p in order) {
      final color = groupColors[p.group]!;
      final bottom = p.group == CargoGroup.bulk ? 0.0 : 0.14;
      if (bottom > 0) {
        canvas.drawRect(Rect.fromPoints(pt(p.x + 0.02, 0), pt(p.x + p.length - 0.02, bottom)),
            Paint()..color = const Color(0xFFC08A4A));
      }
      final rect = Rect.fromPoints(pt(p.x + 0.02, bottom), pt(p.x + p.length - 0.02, p.height));
      canvas.drawRect(rect, Paint()..color = color.withOpacity(0.9));
      canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = Colors.black.withOpacity(0.25));
      for (var k = 1; k < p.pieces; k++) {
        final z = p.height * k / p.pieces;
        canvas.drawRect(Rect.fromPoints(pt(p.x + 0.02, z - 0.07), pt(p.x + p.length - 0.02, z + 0.07)),
            Paint()..color = const Color(0xFFC08A4A));
      }
    }
    if (straps) {
      final strap = Paint()
        ..color = strapColor
        ..strokeWidth = math.max(2, 0.06 * scale);
      for (final x in s.straps) {
        final h = _heightAt(x);
        if (h > 0) canvas.drawLine(pt(x, -0.05), pt(x, h + 0.03), strap);
      }
    }
    for (final x in s.beams) {
      _beam(canvas, pt(x, 0.2), pt(x, 1.6), scale);
    }
    _dimension(canvas, pt(0, s.inner + 0.45), pt(s.length, s.inner + 0.45), texts.metres(s.length), _ink);
    _dimension(canvas, pt(s.length + 0.45, 0), pt(s.length + 0.45, s.inner), texts.metres(s.inner), _ink,
        vertical: true);
    if (vectors && s.cog != null) {
      final c = pt(s.cog!, s.cogHeight);
      final r = math.max(8.0, 0.3 * scale);
      canvas.drawCircle(c, r, Paint()..color = Colors.white);
      for (var q = 0; q < 4; q += 2) {
        canvas.drawArc(
            Rect.fromCircle(center: c, radius: r), q * math.pi / 2, math.pi / 2, true, Paint()..color = cogColor);
      }
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = cogColor
            ..strokeWidth = 1.5);
      _arrow(canvas, c - Offset(r, 0), c - Offset(r + 1.5 * scale, 0), '0.8 g');
      _arrow(canvas, c + Offset(0, r), c + Offset(0, r + 0.9 * scale), '1 g');
    }
  }

  @override
  bool shouldRepaint(SimPainter oldDelegate) =>
      oldDelegate.scene != scene ||
      oldDelegate.view != view ||
      oldDelegate.straps != straps ||
      oldDelegate.vectors != vectors ||
      oldDelegate.dark != dark;
}
