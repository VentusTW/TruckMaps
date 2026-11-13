import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

/// Plik z `infra/build_tiles.ps1` – jest tylko na komputerze z wygenerowanymi kafelkami.
final _poland = File('../../infra/data/tiles/poland.pmtiles');

void main() {
  test('kafelek Warszawy z pliku PMTiles ma warstwy, które rysuje styl mapy', () async {
    final provider = await PmTilesVectorTileProvider.fromSource(_poland.path);
    // z12: Warszawa, centrum (52,23° N, 21,01° E).
    final bytes = await provider.provide(TileIdentity(12, 2287, 1348));
    final tile = VectorTileReader().read(bytes);
    final layers = {for (final layer in tile.layers) layer.name};

    // Budynki są od z13, więc tu tylko drogi, woda i miejscowości.
    expect(layers, containsAll(['transportation', 'water', 'place']));
    final theme = ProvidedThemes.lightTheme();
    expect(theme.layers, isNotEmpty);
    expect(provider.maximumZoom, greaterThanOrEqualTo(14));
  }, skip: _poland.existsSync() ? false : 'brak infra/data/tiles/poland.pmtiles');
}
