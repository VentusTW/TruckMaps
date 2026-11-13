import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';
import 'package:truckmaps_app/src/planner/map_sprites.dart';
import 'package:truckmaps_app/src/planner/map_style.dart';
import 'package:truckmaps_app/src/planner/vector_tiles.dart';

final _tiles = Directory('../../infra/data/tiles');

/// Podgląd stylu: kafelki z pliku mapy narysowane do PNG w `build/map_preview` (do obejrzenia).
/// Nazwa → (zoom stylu, kafelek z14 x, y, ile kafelków na bok, powiększenie kafelka z14).
const _previews = {
  'balice_z14': (14.0, 9105, 5554, 2, 1), // węzeł A4 / S7 pod Krakowem
  'krakow_z16': (16.0, 9103, 5552, 1, 4), // osiedle: budynki, ulice
  'liszki_z17': (17.0, 9092, 5553, 1, 8), // wieś: numery domów
  'malopolska_z10': (10.0, 568, 347, 2, 1), // drogi krajowe i miasta (kafelki z10)
};

void main() {
  test('styl dzienny i nocny czyta się bez błędów, z tarczami numerów dróg', () {
    for (final night in [false, true]) {
      final theme = ThemeReader().read(truckMapStyle(night: night));
      final ids = [for (final layer in theme.layers) layer.id];
      expect(ids, containsAll(['background', 'motorway', 'building', 'shield_red', 'shield_green_1', 'housenumber']));
    }
  });

  test('mapy dołączone do programu: tylko gotowe pliki *.pmtiles', () {
    final dir = Directory.systemTemp.createTempSync('maps');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final name in ['poland.pmtiles', 'germany.new.pmtiles', 'opis.txt']) {
      File('${dir.path}/$name').writeAsStringSync('x');
    }
    expect([for (final f in mapFiles(dir)) f.split(Platform.pathSeparator).last], ['poland.pmtiles']);
  });

  testWidgets('podgląd stylu na prawdziwych kafelkach', (tester) async {
    await tester.runAsync(() async {
      for (final family in ['Roboto', 'Roboto Regular']) {
        final font = FontLoader(family)
          ..addFont(File(r'C:\Windows\Fonts\segoeui.ttf').readAsBytes().then(ByteData.sublistView));
        await font.load();
      }
      final provider = await PmTilesVectorTileProvider.fromSource('${_tiles.path}/poland.pmtiles');
      final out = Directory('build/map_preview')..createSync(recursive: true);
      for (final night in [false, true]) {
        final theme = ThemeReader().read(truckMapStyle(night: night));
        final (spriteIndex, atlasPng) = await shieldSprites(night ? MapPalette.night : MapPalette.day);
        final atlas = (await (await ui.instantiateImageCodec(atlasPng)).getNextFrame()).image;
        for (final MapEntry(key: name, value: (zoom, x, y, n, magnify)) in _previews.entries) {
          const size = 512.0;
          final tileZoom = zoom > 14 ? 14 : zoom.toInt();
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          canvas.clipRect(ui.Rect.fromLTWH(0, 0, size * n, size * n));
          for (var dx = 0; dx < n; dx++) {
            for (var dy = 0; dy < n; dy++) {
              final bytes = await provider.provide(TileIdentity(tileZoom, x + dx, y + dy));
              final tileset = TilesetPreprocessor(theme, initializeGeometry: true).preprocess(
                  Tileset({'openmaptiles': TileFactory(theme, const Logger.noop()).create(VectorTileReader().read(bytes))}),
                  zoom: zoom);
              canvas.save();
              canvas.translate(dx * size, dy * size);
              // Powiększenie: lewa górna część kafelka z14 w całym obrazie.
              canvas.scale(size / 256 * magnify);
              Renderer(theme: theme).render(
                  canvas, TileSource(tileset: tileset, spriteIndex: spriteIndex, spriteAtlas: atlas),
                  zoomScaleFactor: 2.0 * magnify, zoom: zoom, rotation: 0);
              canvas.restore();
            }
          }
          final image = await recorder.endRecording().toImage((size * n).toInt(), (size * n).toInt());
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('${out.path}/${name}_${night ? 'noc' : 'dzien'}.png').writeAsBytesSync(png!.buffer.asUint8List());
        }
      }
    });
  }, skip: !File('../../infra/data/tiles/poland.pmtiles').existsSync());
}
