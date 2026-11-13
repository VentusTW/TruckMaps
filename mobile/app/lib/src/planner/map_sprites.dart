import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:vector_tile_renderer/vector_tile_renderer.dart' show SpriteIndex, SpriteIndexReader;

import 'map_style.dart';

/// Kolory tarcz numerów dróg (nazwa ikony w stylu: `shield_<kolor>_<liczba znaków>`).
const shieldColors = ['red', 'green', 'yellow'];

/// Najdłuższy numer drogi na tarczy (np. „E372”, „DK 79”).
const maxShieldChars = 6;

const _pixelRatio = 2;
const _height = 22;

int shieldWidth(int chars) => 10 + chars * 9;

/// Tarcze numerów dróg rysowane w aplikacji (zaokrąglony prostokąt z białą obwódką
/// w kolorze znaku) – atlas PNG i jego indeks dla `vector_tile_renderer`.
Future<(SpriteIndex, Uint8List)> shieldSprites(MapPalette palette) async {
  final fills = {'red': palette.shieldRed, 'green': palette.shieldGreen, 'yellow': palette.shieldYellow};
  final index = <String, dynamic>{};
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  var y = 0;
  var atlasWidth = 0;
  for (final color in shieldColors) {
    var x = 0;
    for (var chars = 1; chars <= maxShieldChars; chars++) {
      final w = shieldWidth(chars) * _pixelRatio, h = _height * _pixelRatio;
      final rect = ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());
      final outer = ui.RRect.fromRectAndRadius(rect.deflate(1), const ui.Radius.circular(9));
      canvas.drawRRect(outer, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
      canvas.drawRRect(outer.deflate(3), ui.Paint()..color = _color(fills[color]!));
      index['shield_${color}_$chars'] = {
        'x': x,
        'y': y,
        'width': w,
        'height': h,
        'pixelRatio': _pixelRatio,
        // Obszar na numer – tekst rysowany na środku tarczy.
        'content': [4 * _pixelRatio, 3 * _pixelRatio, w - 4 * _pixelRatio, h - 3 * _pixelRatio],
      };
      x += w + 2;
    }
    atlasWidth = x > atlasWidth ? x : atlasWidth;
    y += _height * _pixelRatio + 2;
  }
  final image = await recorder.endRecording().toImage(atlasWidth, y);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  return (SpriteIndexReader().read(index), png!.buffer.asUint8List());
}

ui.Color _color(String hex) => ui.Color(int.parse('FF${hex.substring(1)}', radix: 16));
