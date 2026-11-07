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
const edgeColor = Color(0xFF1F2937);
const matColor = Color(0xFF7C3AED);
const airbagColor = Color(0xFFE2E8F0);
const chainColor = Color(0xFF334155);
const chockColor = Color(0xFFB45309);
const netColor = Color(0xFF0F766E);
const stakeColor = Color(0xFF374151);

/// Poświata podświetlonego zabezpieczenia (najechanie na pozycję listy sprzętu).
const glowColor = Color(0xFFFFC400);

/// Kolory towaru innego niż palety – wg grupy rodzaju towaru.
const cargoGroupColors = <String, Color>{
  'packages': Color(0xFFB45309),
  'agri': Color(0xFFD9B44A),
  'steel': Color(0xFF64748B),
  'timber': Color(0xFF9A6B3F),
  'building': Color(0xFFB91C1C),
  'paper': Color(0xFFE7E5E4),
  'machines': Color(0xFFEAB308),
  'food': Color(0xFF0EA5E9),
  'chemicals': Color(0xFFF97316),
  'glass': Color(0xFF67E8F9),
  'bulk': Color(0xFFA8A29E),
  'other': Color(0xFFF59E0B),
};

/// Wygląd pozycji ładunku: rodzaj palety (`kind`), kształt, grupa i nazwa rodzaju towaru.
class CargoLook {
  const CargoLook(this.kind,
      {this.shape = 'pallet',
      this.group = 'pallets',
      this.name = '',
      this.securing = 'top',
      this.gear = const [],
      this.stack = 2});

  /// Ile sztuk najwyżej w stosie (z rodzaju towaru).
  final int stack;

  final String kind;
  final String shape;
  final String group;
  final String name;

  /// `top` – pasy dociskowe, `direct` – łańcuchy / odciągi, `none` – w zabudowie.
  final String securing;

  /// Dodatkowy sprzęt: `chains`, `chocks`, `net`, `stakes`.
  final List<String> gear;

  /// Paleta (kolor wg masy sztuki, drewniana podstawa).
  bool get pallet => group == 'pallets' || (shape == 'pallet' && kind != 'custom');
}

double _d(Object? value, [double fallback = 0]) => value is num ? value.toDouble() : fallback;

/// Sztuka na planie (z odpowiedzi serwera) z grupą.
class SimPiece {
  SimPiece(Map<String, dynamic> json, List<CargoLook> looks)
      : x = _d(json['x_m']),
        y = _d(json['y_m']),
        length = _d(json['length_m']),
        width = _d(json['width_m']),
        height = _d(json['height_m'], 1.2),
        pieces = (json['pieces'] as int?) ?? 1,
        stop = (json['stop'] as int?) ?? 1,
        weight = _d(json['weight_kg']),
        look = _look(json, looks),
        group = _group(json, looks);

  final double x, y, length, width, height, weight;
  final int pieces, stop;
  final CargoGroup group;
  final CargoLook look;

  String get shape => look.shape;

  /// Drewniana paleta pod spodem.
  bool get palletBase => look.shape == 'pallet';

  Color get color =>
      group == CargoGroup.bulk ? cargoGroupColors[look.group] ?? groupColors[group]! : groupColors[group]!;

  static CargoLook _look(Map<String, dynamic> json, List<CargoLook> looks) {
    final item = (json['item'] as int?) ?? 0;
    return item < looks.length ? looks[item] : const CargoLook('euro');
  }

  static CargoGroup _group(Map<String, dynamic> json, List<CargoLook> looks) {
    final look = _look(json, looks);
    if (!look.pallet) return CargoGroup.bulk;
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
  SimScene(Map<String, dynamic> plan, List<CargoLook> kinds)
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
        tractor = plan['tractor'] != null,
        gear = {
          for (final g in (plan['equipment'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
            '${g['id']}': (g['required'] as int?) ?? 0,
        };

  final double length, width, inner;
  final double? cog;
  final List<SimPiece> pieces;
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> axles;
  final bool tractor;

  /// Sprzęt z listy VDI 2700: ile sztuk potrzeba.
  final Map<String, int> gear;

  bool get mats => (gear['mats'] ?? 0) > 0;

  /// Luki w poprzek rzędów (od 15 cm) – miejsca na poduszki sztauerskie: (x, długość, y, szerokość, wysokość).
  List<(double, double, double, double, double)> get gaps {
    final byX = <double, List<SimPiece>>{};
    for (final p in pieces) {
      byX.putIfAbsent((p.x * 100).roundToDouble() / 100, () => []).add(p);
    }
    return [
      for (final MapEntry(key: x, value: row) in byX.entries)
        if (width - row.fold<double>(0, (s, p) => s + p.width) >= 0.15)
          (
            x,
            row.map((p) => p.length).reduce(math.max),
            row.map((p) => p.y + p.width).reduce(math.max),
            width - row.map((p) => p.y + p.width).reduce(math.max),
            math.min(1.8, row.map((p) => p.height).reduce(math.max)),
          ),
    ];
  }

  /// Położenia pasów wzdłuż przestrzeni (równo w każdym rzędzie).
  List<double> get straps => [
        for (final r in rows)
          for (var k = 0; k < ((r['straps'] as int?) ?? 0); k++)
            _d(r['x_m']) + _d(r['length_m']) * (k + 1) / (((r['straps'] as int?) ?? 0) + 1),
      ];

  /// Belki rozporowe: za każdym rozładunkiem poza ostatnim i przed luką między rzędami
  /// (ciężki ładunek odsunięty nad osie).
  List<double> get beams {
    final sorted = [...pieces]..sort((a, b) => a.x.compareTo(b.x));
    final found = <double>{};
    var end = sorted.isEmpty ? 0.0 : sorted.first.x + sorted.first.length;
    for (var i = 1; i < sorted.length; i++) {
      final p = sorted[i], prev = sorted[i - 1];
      if (p.stop != prev.stop && p.x > prev.x) found.add(p.x);
      if (p.x - end >= 0.1 - 1e-6) found.add(p.x);
      end = math.max(end, p.x + p.length);
    }
    return found.toList()..sort();
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
    this.highlight,
  });

  final SimScene scene;
  final SimView view;
  final bool straps;
  final bool vectors;
  final LoadTexts texts;
  final bool dark;

  /// Podświetlony sprzęt (`straps`, `edges`, `beams`, `mats`, `airbags`) – pogrubiony, z poświatą.
  final String? highlight;

  bool _on(String id) => highlight == id;

  /// Pasy widać, gdy włączona nakładka albo podświetlone są pasy lub narożniki.
  bool get _showStraps => straps || _on('straps') || _on('edges');

  /// Sprzęt widoczny przy włączonej nakładce mocowania albo po podświetleniu.
  bool _show(String id) => straps || _on(id);

  Paint _gearPaint(String id, Color color, double width) => Paint()
    ..color = color
    ..strokeWidth = _w(id, width)
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;

  void _gearLine(Canvas canvas, String id, Offset a, Offset b, Color color, double width) {
    if (_on(id)) _glowLine(canvas, a, b, _w(id, width));
    canvas.drawLine(a, b, _gearPaint(id, color, width));
  }

  /// Łańcuchy, kliny, siatka i kłonice – w każdym widoku przez `pt(x, y, z)` (z = wysokość nad podłogą).
  void _gear(Canvas canvas, Offset Function(double, double, double) pt, double scale) {
    final s = scene;
    for (final p in s.pieces) {
      final x0 = p.x + 0.03, x1 = p.x + p.length - 0.03, y0 = p.y + 0.03, y1 = p.y + p.width - 0.03;
      final h = p.height;
      if (p.look.securing == 'direct' && _show('chains')) {
        // 4 odciągi ukośne od górnych narożników do punktów mocowania przy burtach.
        for (final (x, dx) in [(x0, -0.6), (x1, 0.6)]) {
          for (final (y, edge) in [(y0, 0.0), (y1, s.width)]) {
            _gearLine(canvas, 'chains', pt(x, y, h * 0.85), pt(x + dx, edge, 0), chainColor, 2);
          }
        }
      }
      if (p.look.gear.contains('chocks') && _show('chocks')) {
        final c = _on('chocks') ? 0.35 : 0.2;
        for (final (x, dir) in [(x0, -1.0), (x1, 1.0)]) {
          for (final y in [y0 + 0.15, y1 - 0.15]) {
            _shape(canvas, [pt(x, y, 0), pt(x + dir * c, y, 0), pt(x, y, c)], chockColor, 'chocks');
          }
        }
      }
      if (p.look.gear.contains('net') && _show('net')) {
        for (var x = x0; x <= x1 + 1e-6; x += (x1 - x0) / 4) {
          _gearLine(canvas, 'net', pt(x, y0, h), pt(x, y1, h), netColor, 1.2);
        }
        for (var y = y0; y <= y1 + 1e-6; y += (y1 - y0) / 4) {
          _gearLine(canvas, 'net', pt(x0, y, h), pt(x1, y, h), netColor, 1.2);
        }
      }
      if (p.look.gear.contains('stakes') && _show('stakes')) {
        for (final x in [x0 + 0.1, x1 - 0.1]) {
          for (final y in [0.0, s.width]) {
            _gearLine(canvas, 'stakes', pt(x, y, 0), pt(x, y, h + 0.25), stakeColor, 3);
          }
        }
      }
    }
  }

  /// Grubość: podświetlony element – kilka razy grubszy.
  double _w(String id, double base) => _on(id) ? base * 2.6 : base;

  /// Przygaszenie rysunku pod podświetlonym sprzętem.
  void _dim(Canvas canvas, Size size) {
    if (highlight == null) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = (dark ? Colors.black : Colors.white).withOpacity(0.45));
  }

  void _glowLine(Canvas canvas, Offset a, Offset b, double width) => canvas.drawLine(
      a,
      b,
      Paint()
        ..color = glowColor.withOpacity(0.7)
        ..strokeWidth = width + 10
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));

  void _glowPath(Canvas canvas, Path path, {double width = 8}) => canvas.drawPath(
      path,
      Paint()
        ..color = glowColor.withOpacity(0.75)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));

  /// Wielokąt z obrysem; podświetlony – z poświatą.
  void _shape(Canvas canvas, List<Offset> points, Color fill, String id) {
    final path = Path()..addPolygon(points, true);
    if (_on(id)) _glowPath(canvas, path);
    // Jasne poduszki po podświetleniu – wyraźnym kolorem, żeby nie ginęły na podłodze.
    canvas.drawPath(path, Paint()..color = _on(id) && id == 'airbags' ? const Color(0xFFFFB020) : fill);
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _on(id) ? 2 : 0.8
          ..color = _on(id) ? glowColor : Colors.black.withOpacity(0.35));
  }

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

    // Maty pod sztukami (wystają spod palety).
    void mat(SimPiece p, double out) => _shape(
        canvas,
        [
          pt(p.x - out, p.y - out, 0),
          pt(p.x + p.length + out, p.y - out, 0),
          pt(p.x + p.length + out, p.y + p.width + out, 0),
          pt(p.x - out, p.y + p.width + out, 0)
        ],
        matColor,
        'mats');
    if (s.mats && !_on('mats')) {
      for (final p in s.pieces) {
        mat(p, 0.05);
      }
    }

    // Ładunek: od najdalszych (mały x + y) do najbliższych.
    final order = [...s.pieces]..sort((a, b) => (a.x + a.y * 3).compareTo(b.x + b.y * 3));
    for (final p in order) {
      _box(canvas, pt, p);
    }
    // Poduszki sztauerskie w lukach w poprzek rzędów.
    if ((s.gear['airbags'] ?? 0) > 0 && !_on('airbags')) {
      for (final g in s.gaps) {
        _airbagIso(canvas, pt, g);
      }
    }
    _dim(canvas, size);
    if (_on('mats')) {
      for (final p in s.pieces) {
        mat(p, 0.1);
      }
    }
    if (_on('airbags')) {
      for (final g in s.gaps) {
        _airbagIso(canvas, pt, g);
      }
    }

    // Pasy: przez górę ładunku i w dół po bliższej burcie.
    if (_showStraps) {
      final width = _w('straps', math.max(1.5, 0.06 * scale));
      final strap = Paint()
        ..color = strapColor
        ..strokeWidth = width
        ..style = PaintingStyle.stroke;
      for (final x in s.straps) {
        final h = _heightAt(x);
        if (h <= 0) continue;
        final path = Path()
          ..moveTo(pt(x, 0, h).dx, pt(x, 0, h).dy)
          ..lineTo(pt(x, s.width, h).dx, pt(x, s.width, h).dy)
          ..lineTo(pt(x, s.width, 0).dx, pt(x, s.width, 0).dy);
        if (_on('straps')) _glowPath(canvas, path, width: width + 10);
        canvas.drawPath(path, strap);
        // Narożniki ochronne na obu górnych krawędziach.
        final e = _on('edges') ? 0.26 : 0.1;
        for (final y in [0.0, s.width]) {
          final inward = y == 0 ? e : -e;
          _shape(
              canvas, [pt(x - e, y, h), pt(x + e, y, h), pt(x + e, y, h - e), pt(x - e, y, h - e)], edgeColor, 'edges');
          _shape(canvas, [pt(x - e, y, h), pt(x + e, y, h), pt(x + e, y + inward, h), pt(x - e, y + inward, h)],
              _shade(edgeColor, 1.6), 'edges');
        }
      }
    }
    // Belki rozporowe na granicach rozładunków.
    for (final x in s.beams) {
      final width = _w('beams', 4);
      if (_on('beams')) _glowLine(canvas, pt(x, 0, 1.0), pt(x, s.width, 1.0), width);
      canvas.drawLine(
          pt(x, 0, 1.0),
          pt(x, s.width, 1.0),
          Paint()
            ..color = beamColor
            ..strokeWidth = width
            ..strokeCap = StrokeCap.round);
    }

    _gear(canvas, pt, scale);

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

  void _airbagIso(
      Canvas canvas, Offset Function(double, double, double) pt, (double, double, double, double, double) g) {
    final (x, len, y, w, h) = g;
    final x0 = x + 0.1, x1 = x + len - 0.1, y0 = y + 0.02, y1 = y + w - 0.02, z0 = 0.15, z1 = h - 0.1;
    _shape(canvas, [pt(x0, y1, z0), pt(x1, y1, z0), pt(x1, y1, z1), pt(x0, y1, z1)], airbagColor, 'airbags');
    _shape(
        canvas, [pt(x0, y0, z1), pt(x1, y0, z1), pt(x1, y1, z1), pt(x0, y1, z1)], _shade(airbagColor, 1.05), 'airbags');
  }

  double _heightAt(double x) {
    var h = 0.0;
    for (final p in scene.pieces) {
      if (x >= p.x && x <= p.x + p.length) h = math.max(h, p.height);
    }
    return h;
  }

  void _box(Canvas canvas, Offset Function(double, double, double) pt, SimPiece p) {
    switch (p.shape) {
      case 'coil':
        return _cylinder(canvas, pt, p, 'x', eye: true);
      case 'bale_round':
        return _cylinder(canvas, pt, p, 'y');
      case 'drum' || 'roll':
        return _cylinder(canvas, pt, p, 'z', eye: p.shape == 'roll');
    }
    final base = p.color;
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

    final wood = p.palletBase ? const Color(0xFFC08A4A) : null;
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

  /// Walec (krąg, bela okrągła, beczka, rola): oś wzdłuż (`x`), w poprzek (`y`) albo pionowa (`z`).
  void _cylinder(Canvas canvas, Offset Function(double, double, double) pt, SimPiece p, String axis,
      {bool eye = false}) {
    const n = 28;
    final x0 = p.x + 0.03, x1 = p.x + p.length - 0.03, y0 = p.y + 0.03, y1 = p.y + p.width - 0.03;
    final r = switch (axis) {
      'x' => math.min(y1 - y0, p.height) / 2,
      'y' => math.min(x1 - x0, p.height) / 2,
      _ => math.min(x1 - x0, y1 - y0) / 2,
    };
    final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    List<Offset> ring(double at, double radius) => [
          for (var k = 0; k < n; k++)
            switch (axis) {
              'x' => pt(at, cy + radius * math.cos(2 * math.pi * k / n), r + radius * math.sin(2 * math.pi * k / n)),
              'y' => pt(cx + radius * math.cos(2 * math.pi * k / n), at, r + radius * math.sin(2 * math.pi * k / n)),
              _ => pt(cx + radius * math.cos(2 * math.pi * k / n), cy + radius * math.sin(2 * math.pi * k / n), at),
            },
        ];
    final (start, end) = switch (axis) { 'x' => (x0, x1), 'y' => (y0, y1), _ => (0.0, p.height) };
    final base = p.color;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = Colors.black.withOpacity(0.3);
    final hull = Path()..addPolygon(_hull([...ring(start, r), ...ring(end, r)]), true);
    canvas.drawPath(hull, Paint()..color = _shade(base, 0.82));
    canvas.drawPath(hull, outline);
    // Widoczna podstawa: przód (+x), bliższa strona (+y) albo góra.
    final face = Path()..addPolygon(ring(end, r), true);
    canvas.drawPath(face, Paint()..color = _shade(base, 1.12));
    canvas.drawPath(face, outline);
    if (eye) {
      canvas.drawPath(Path()..addPolygon(ring(end, r * 0.38), true), Paint()..color = _shade(base, 0.45));
    } else if (p.shape == 'bale_round') {
      for (final k in [0.55, 0.8]) {
        canvas.drawPath(Path()..addPolygon(ring(end, r * k), true), outline);
      }
    }
  }

  /// Otoczka wypukła punktów (algorytm monotoniczny).
  static List<Offset> _hull(List<Offset> points) {
    final pts = [...points]..sort((a, b) => a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
    double cross(Offset o, Offset a, Offset b) => (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
    final lower = <Offset>[], upper = <Offset>[];
    for (final p in pts) {
      while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }
    for (final p in pts.reversed) {
      while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }
    return [...lower.sublist(0, lower.length - 1), ...upper.sublist(0, upper.length - 1)];
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
    void mat(SimPiece p, double out) => _shape(
        canvas,
        [
          pt(p.x - out, p.y - out),
          pt(p.x + p.length + out, p.y - out),
          pt(p.x + p.length + out, p.y + p.width + out),
          pt(p.x - out, p.y + p.width + out)
        ],
        matColor,
        'mats');
    if (s.mats) {
      for (final p in s.pieces) {
        mat(p, 0.0);
      }
    }
    for (final p in s.pieces) {
      final rect = Rect.fromPoints(pt(p.x + 0.04, p.y + 0.04), pt(p.x + p.length - 0.04, p.y + p.width - 0.04));
      if (p.shape == 'drum' || p.shape == 'roll') {
        final r = math.min(rect.width, rect.height) / 2;
        canvas.drawCircle(rect.center, r, Paint()..color = p.color);
        canvas.drawCircle(
            rect.center,
            r,
            Paint()
              ..style = PaintingStyle.stroke
              ..color = Colors.black.withOpacity(0.3));
        if (p.shape == 'roll') canvas.drawCircle(rect.center, r * 0.35, Paint()..color = _shade(p.color, 0.5));
        continue;
      }
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              rect, Radius.circular(p.shape == 'coil' || p.shape == 'bale_round' ? rect.shortestSide * 0.2 : 0)),
          Paint()..color = p.color);
      // Zwoje kręgu / beli – linie wzdłuż osi.
      if (p.shape == 'coil' || p.shape == 'bale_round') {
        final line = Paint()
          ..color = Colors.black.withOpacity(0.25)
          ..strokeWidth = 1;
        for (var k = 1; k < 4; k++) {
          if (p.shape == 'coil') {
            final y = rect.top + rect.height * k / 4;
            canvas.drawLine(Offset(rect.left + 2, y), Offset(rect.right - 2, y), line);
          } else {
            final x = rect.left + rect.width * k / 4;
            canvas.drawLine(Offset(x, rect.top + 2), Offset(x, rect.bottom - 2), line);
          }
        }
      }
      // Deski palety.
      if (p.palletBase) {
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
    void airbag((double, double, double, double, double) g) {
      final (x, len, y, w, _) = g;
      _shape(
          canvas,
          [
            pt(x + 0.1, y + 0.03),
            pt(x + len - 0.1, y + 0.03),
            pt(x + len - 0.1, y + w - 0.03),
            pt(x + 0.1, y + w - 0.03)
          ],
          airbagColor,
          'airbags');
    }

    if ((s.gear['airbags'] ?? 0) > 0 && !_on('airbags')) s.gaps.forEach(airbag);
    _dim(canvas, size);
    if (_on('mats')) {
      for (final p in s.pieces) {
        mat(p, 0.08);
      }
    }
    if (_on('airbags')) s.gaps.forEach(airbag);
    if (_showStraps) {
      final width = _w('straps', math.max(2, 0.07 * scale));
      final strap = Paint()
        ..color = strapColor
        ..strokeWidth = width;
      for (final x in s.straps) {
        if (_on('straps')) _glowLine(canvas, pt(x, -0.05), pt(x, s.width + 0.05), width);
        canvas.drawLine(pt(x, -0.05), pt(x, s.width + 0.05), strap);
        final e = _on('edges') ? 0.2 : 0.08;
        for (final y in [0.0, s.width]) {
          _shape(canvas, [pt(x - e, y - e), pt(x + e, y - e), pt(x + e, y + e), pt(x - e, y + e)], edgeColor, 'edges');
        }
      }
    }
    for (final x in s.beams) {
      if (_on('beams')) _glowLine(canvas, pt(x, 0), pt(x, s.width), _w('beams', math.max(3, 0.1 * scale)));
      _beam(canvas, pt(x, 0), pt(x, s.width), scale);
    }
    _gear(canvas, (x, y, z) => pt(x, y), scale);
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
      ..strokeWidth = _w('beams', math.max(3, 0.1 * scale))
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
      final color = p.color;
      if (p.shape == 'bale_round') {
        // Bela leżąca w poprzek – z boku widać koło.
        final r = math.min(p.length, p.height) / 2 * scale;
        final c = pt(p.x + p.length / 2, p.height / 2);
        canvas.drawCircle(c, r, Paint()..color = color.withOpacity(0.9));
        canvas.drawCircle(
            c,
            r,
            Paint()
              ..style = PaintingStyle.stroke
              ..color = Colors.black.withOpacity(0.3));
        continue;
      }
      final bottom = p.palletBase ? 0.14 : 0.0;
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
    void mats(double thick) {
      for (final p in s.pieces) {
        _shape(
            canvas,
            [pt(p.x - 0.03, 0), pt(p.x + p.length + 0.03, 0), pt(p.x + p.length + 0.03, thick), pt(p.x - 0.03, thick)],
            matColor,
            'mats');
      }
    }

    if (s.mats && !_on('mats')) mats(0.04);
    _dim(canvas, size);
    if (_on('mats')) mats(0.12);
    // Poduszki są w poprzek rzędu – z boku zaznaczamy rzędy, w których są.
    if (_on('airbags')) {
      for (final (x, len, _, _, h) in s.gaps) {
        _shape(canvas, [pt(x + 0.1, 0.2), pt(x + len - 0.1, 0.2), pt(x + len - 0.1, h - 0.1), pt(x + 0.1, h - 0.1)],
            airbagColor.withOpacity(0.85), 'airbags');
      }
    }
    if (_showStraps) {
      final width = _w('straps', math.max(2, 0.06 * scale));
      final strap = Paint()
        ..color = strapColor
        ..strokeWidth = width;
      for (final x in s.straps) {
        final h = _heightAt(x);
        if (h <= 0) continue;
        if (_on('straps')) _glowLine(canvas, pt(x, -0.05), pt(x, h + 0.03), width);
        canvas.drawLine(pt(x, -0.05), pt(x, h + 0.03), strap);
        final e = _on('edges') ? 0.22 : 0.08;
        _shape(canvas, [pt(x - e, h + 0.03), pt(x + e, h + 0.03), pt(x + e, h + 0.03 - e), pt(x - e, h + 0.03 - e)],
            edgeColor, 'edges');
      }
    }
    for (final x in s.beams) {
      if (_on('beams')) _glowLine(canvas, pt(x, 0.2), pt(x, 1.6), _w('beams', math.max(3, 0.1 * scale)));
      _beam(canvas, pt(x, 0.2), pt(x, 1.6), scale);
    }
    _gear(canvas, (x, y, z) => pt(x, z), scale);
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
      oldDelegate.dark != dark ||
      oldDelegate.highlight != highlight;
}
