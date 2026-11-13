import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import 'map_sprites.dart';
import 'map_style.dart';
import 'planner_screen.dart' show mapTiles, nightMapTiles;

/// Katalog map dołączonych do programu: `maps` obok pliku programu (Windows – kopiuje go tam
/// budowanie, zob. `windows/CMakeLists.txt`). Brak – mapy z serwera.
Directory? bundledMapsDir() {
  if (kIsWeb) return null;
  final dir = Directory('${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}maps');
  return dir.existsSync() ? dir : null;
}

/// Pliki `*.pmtiles` w katalogu (posortowane, bez plików w trakcie podmiany `*.new.pmtiles`).
List<String> mapFiles(Directory dir) => [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('.pmtiles') && !f.path.endsWith('.new.pmtiles')) f.path,
    ]..sort();

/// Mapa wektorowa z kafelków PMTiles (schemat OpenMapTiles, Planetiler z OSM – `infra/build_tiles.ps1`):
/// najpierw mapy dołączone do programu (działają bez sieci), potem mapy z serwera TruckMaps.
/// Rysowana w aplikacji własnym stylem (`map_style.dart`), dziennym i nocnym, na każdej
/// platformie (także Windows). Bez map – zostaje podkład obrazkowy OSM.
///
/// Pod mapą wektorową zostaje podkład obrazkowy: poza obszarem plików (kraje, których jeszcze
/// nie ma) widać zwykłą mapę.
Future<bool> useVectorMap(String serverUrl, {http.Client? client, Directory? localDir}) async {
  try {
    final local = localDir ?? bundledMapsDir();
    final sources = local != null ? mapFiles(local) : <String>[];
    if (sources.isEmpty) sources.addAll(await _serverArchives(serverUrl, client));
    if (sources.isEmpty) return false;
    // Jeden plik na raz (zwykle jeden kraj albo cała Europa); kolejne kraje – kolejne pliki.
    final provider = await PmTilesVectorTileProvider.fromSource(sources.first);
    final providers = TileProviders({'openmaptiles': provider});
    final day = vtr.ThemeReader().read(truckMapStyle());
    final night = vtr.ThemeReader().read(truckMapStyle(night: true));
    final (dayIndex, dayAtlas) = await shieldSprites(MapPalette.day);
    final (nightIndex, nightAtlas) = await shieldSprites(MapPalette.night);
    final raster = mapTiles;
    Widget layer(vtr.Theme theme, SpriteStyle sprites, {bool dark = false}) => Stack(children: [
          if (dark) ColorFiltered(colorFilter: _darken, child: raster()) else raster(),
          VectorTileLayer(
            theme: theme,
            sprites: sprites,
            tileProviders: providers,
            fileCacheTtl: const Duration(days: 7),
          ),
          const _Attribution(),
        ]);
    final daySprites = SpriteStyle(atlasProvider: () async => dayAtlas, index: dayIndex);
    final nightSprites = SpriteStyle(atlasProvider: () async => nightAtlas, index: nightIndex);
    mapTiles = () => layer(day, daySprites);
    nightMapTiles = () => layer(night, nightSprites, dark: true);
    return true;
  } catch (_) {
    return false;
  }
}

Future<List<String>> _serverArchives(String serverUrl, http.Client? client) async {
  final http.Client api = client ?? http.Client();
  try {
    final response = await api.get(Uri.parse('$serverUrl/api/tiles')).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return [];
    final archives = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
    return [for (final a in archives) '$serverUrl${(a as Map<String, dynamic>)['url']}'];
  } catch (_) {
    return [];
  } finally {
    if (client == null) api.close();
  }
}

const _darken = ColorFilter.matrix([
  0.35, 0, 0, 0, 0, //
  0, 0.38, 0, 0, 0,
  0, 0, 0.45, 0, 0,
  0, 0, 0, 1, 0,
]);

/// Autorzy danych mapy – wymagane przez licencje OpenStreetMap (ODbL) i OpenMapTiles.
class _Attribution extends StatelessWidget {
  const _Attribution();

  @override
  Widget build(BuildContext context) => const Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: DecoratedBox(
            decoration: BoxDecoration(color: Color(0xB3FFFFFF), borderRadius: BorderRadius.all(Radius.circular(4))),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text('© OpenMapTiles © OpenStreetMap', style: TextStyle(fontSize: 11, color: Color(0xFF444444))),
            ),
          ),
        ),
      );
}
