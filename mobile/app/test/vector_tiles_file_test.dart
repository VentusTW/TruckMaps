import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';
import 'package:truckmaps_app/src/planner/vector_tiles.dart';

final _poland = _mapFile();

/// Plik mapy z `infra/build_tiles.ps1` (cała Europa albo sama Polska) – tylko na komputerze z kafelkami.
File _mapFile() => [for (final n in ['europe', 'poland']) File('../../infra/data/tiles/$n.pmtiles')]
    .firstWhere((f) => f.existsSync(), orElse: () => File('../../infra/data/tiles/poland.pmtiles'));

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
  }, skip: _poland.existsSync() ? false : 'brak pliku mapy w infra/data/tiles');

  test('kilka plików map: kafelek tylko z pliku, który obejmuje to miejsce', () async {
    final poland = await PmTilesVectorTileProvider.fromSource(_poland.path);
    final header = poland.archive.header.data;
    expect(MultiMapProvider.covers(header, TileIdentity(12, 2287, 1348)), isTrue); // Warszawa
    expect(MultiMapProvider.covers(header, TileIdentity(12, 2103, 1460)), isFalse); // Lyon
    final multi = MultiMapProvider([poland]);
    expect(await multi.provide(TileIdentity(12, 2287, 1348)), isNotEmpty);
    await expectLater(multi.provide(TileIdentity(12, 2103, 1460)), throwsA(isA<ProviderException>()));
  }, skip: _poland.existsSync() ? false : 'brak pliku mapy w infra/data/tiles');
}
