/// Własny styl mapy wektorowej TruckMaps (schemat OpenMapTiles z Planetilera).
///
/// Wygląd pod jazdę ciężarówką: jasne pastelowe tło, wyraźne drogi szybkiego ruchu
/// (czerwone), krajowe i wojewódzkie (pomarańczowe / żółte), białe ulice z szarą obwódką,
/// tarcze numerów dróg w kolorach znaków (A, S i drogi krajowe – czerwone, E – zielone,
/// wojewódzkie – żółte), budynki, numery domów, rozstrzelone nazwy dzielnic. Wersja nocna
/// z tym samym układem warstw i ciemnymi kolorami.
library;

/// Kolory stylu (dzień / noc).
class MapPalette {
  const MapPalette({
    required this.land,
    required this.residential,
    required this.industrial,
    required this.wood,
    required this.grass,
    required this.farmland,
    required this.water,
    required this.waterLine,
    required this.building,
    required this.buildingOutline,
    required this.motorway,
    required this.motorwayCasing,
    required this.trunk,
    required this.trunkCasing,
    required this.primary,
    required this.primaryCasing,
    required this.secondary,
    required this.secondaryCasing,
    required this.minor,
    required this.minorCasing,
    required this.track,
    required this.rail,
    required this.boundary,
    required this.label,
    required this.labelMuted,
    required this.labelHalo,
    required this.waterLabel,
    required this.shieldRed,
    required this.shieldGreen,
    required this.shieldYellow,
    required this.shieldText,
    required this.shieldTextDark,
  });

  final String land, residential, industrial, wood, grass, farmland, water, waterLine;
  final String building, buildingOutline;
  final String motorway, motorwayCasing, trunk, trunkCasing, primary, primaryCasing;
  final String secondary, secondaryCasing, minor, minorCasing, track, rail, boundary;
  final String label, labelMuted, labelHalo, waterLabel;
  final String shieldRed, shieldGreen, shieldYellow, shieldText, shieldTextDark;

  static const day = MapPalette(
    land: '#f4f1e8',
    residential: '#eeecef',
    industrial: '#e8e4ee',
    wood: '#c8e2b1',
    grass: '#d9ecc6',
    farmland: '#efeedc',
    water: '#a9d3f2',
    waterLine: '#8cc3ea',
    building: '#dfdcd6',
    buildingOutline: '#c9c4bc',
    motorway: '#e8603c',
    motorwayCasing: '#b8402a',
    trunk: '#ef7d4f',
    trunkCasing: '#c45a33',
    primary: '#f6b94a',
    primaryCasing: '#d0912c',
    secondary: '#f7d46a',
    secondaryCasing: '#d4ae3f',
    minor: '#ffffff',
    minorCasing: '#c9c6c0',
    track: '#d6cfc0',
    rail: '#b4b0aa',
    boundary: '#a78fc2',
    label: '#3d3d3d',
    labelMuted: '#7a7a7a',
    labelHalo: '#ffffff',
    waterLabel: '#4a86b8',
    shieldRed: '#d6262e',
    shieldGreen: '#1f8a4c',
    shieldYellow: '#f5c518',
    shieldText: '#ffffff',
    shieldTextDark: '#1f1f1f',
  );

  static const night = MapPalette(
    land: '#1f2530',
    residential: '#272d3a',
    industrial: '#2b2f3d',
    wood: '#1f3328',
    grass: '#24382d',
    farmland: '#232a2f',
    water: '#183a5c',
    waterLine: '#1f4a73',
    building: '#343a47',
    buildingOutline: '#424959',
    motorway: '#c9532f',
    motorwayCasing: '#7d2f1a',
    trunk: '#c56a3f',
    trunkCasing: '#7a3f22',
    primary: '#b98a37',
    primaryCasing: '#6f5220',
    secondary: '#a8903f',
    secondaryCasing: '#615325',
    minor: '#4a5161',
    minorCasing: '#2c313c',
    track: '#3d4250',
    rail: '#5a6070',
    boundary: '#7d6a95',
    label: '#e3e6ec',
    labelMuted: '#a3a9b5',
    labelHalo: '#1f2530',
    waterLabel: '#7fb3e0',
    shieldRed: '#c0222a',
    shieldGreen: '#1b7a43',
    shieldYellow: '#d9ad12',
    shieldText: '#ffffff',
    shieldTextDark: '#1f1f1f',
  );
}

/// Sieci dróg z relacji OSM (`route_N_network`) → kolor tarczy.
const _redNetworks = [
  'PL:motorway', 'pl:motorway', 'PL:expressway', 'pl:expressway', 'PL:national', 'pl:national', //
  'DE:BAB', 'CZ:motorway', 'CZ:national', 'SK:motorway', 'LT:motorway',
];
const _yellowNetworks = [
  'PL:regional',
  'pl:regional',
  'PL:voivodeship',
  'pl:voivodeship',
  'DE:B',
  'CZ:regional',
  'cz:regional',
];
const _greenNetworks = ['e-road', 'E-road', 'int:e-road'];

Map<String, dynamic> _width(List<List<num>> stops, {double base = 1.3}) => {'base': base, 'stops': stops};

Map<String, dynamic> _line(String id, String layer, List<dynamic> filter, String color, Map<String, dynamic> width,
        {int minzoom = 0}) =>
    {
      'id': id,
      'type': 'line',
      'source': 'openmaptiles',
      'source-layer': layer,
      'minzoom': minzoom,
      'filter': filter,
      'layout': {'line-cap': 'round', 'line-join': 'round'},
      'paint': {'line-color': color, 'line-width': width},
    };

Map<String, dynamic> _fill(String id, String layer, List<dynamic> filter, String color,
        {int minzoom = 0, String? outline}) =>
    {
      'id': id,
      'type': 'fill',
      'source': 'openmaptiles',
      'source-layer': layer,
      'minzoom': minzoom,
      'filter': filter,
      'paint': {'fill-color': color, if (outline != null) 'fill-outline-color': outline},
    };

Map<String, dynamic> _text(
  String id,
  String layer,
  List<dynamic> filter,
  String field, {
  required String color,
  required String halo,
  required Map<String, dynamic> size,
  double haloWidth = 1.5,
  int minzoom = 0,
  int maxzoom = 24,
  bool line = false,
  bool upper = false,
  double spacing = 0,
}) =>
    {
      'id': id,
      'type': 'symbol',
      'source': 'openmaptiles',
      'source-layer': layer,
      'minzoom': minzoom,
      'maxzoom': maxzoom,
      'filter': filter,
      'layout': {
        'text-field': field,
        'text-font': ['Roboto Regular'],
        'text-size': size,
        if (line) 'symbol-placement': 'line',
        if (upper) 'text-transform': 'uppercase',
        if (spacing > 0) 'text-letter-spacing': spacing,
        'text-max-width': 8,
      },
      'paint': {'text-color': color, 'text-halo-color': halo, 'text-halo-width': haloWidth},
    };

/// Tarcza numeru drogi: numer na ikonie w kolorze znaku (`map_sprites.dart`, `shield_<kolor>_<znaki>`).
Map<String, dynamic> _shield(String id, List<dynamic> filter, String field, String icon, String text,
        {int minzoom = 7}) =>
    {
      'id': id,
      'type': 'symbol',
      'source': 'openmaptiles',
      'source-layer': 'transportation_name',
      'minzoom': minzoom,
      'filter': filter,
      'layout': {
        'icon-image': icon,
        'icon-rotation-alignment': 'viewport',
        'symbol-placement': 'point',
        'text-field': field,
        'text-font': ['Roboto Regular'],
        'text-size': 13,
        'text-rotation-alignment': 'viewport',
      },
      'paint': {'text-color': text},
    };

/// Pełny styl (Mapbox GL Style, podzbiór obsługiwany przez `vector_tile_renderer`).
Map<String, dynamic> truckMapStyle({bool night = false}) {
  final p = night ? MapPalette.night : MapPalette.day;
  const all = ['all'];

  // Drogi: obwódka i wypełnienie, od najmniej do najbardziej ważnych (ważne rysowane na wierzchu).
  final roads = <(String, List<String>, String, String, List<List<num>>, int)>[
    (
      'track',
      ['track', 'path'],
      p.track,
      p.track,
      [
        [14, 0.5],
        [18, 2]
      ],
      14
    ),
    (
      'service',
      ['service'],
      p.minor,
      p.minorCasing,
      [
        [13, 1],
        [18, 7]
      ],
      13
    ),
    (
      'minor',
      ['minor'],
      p.minor,
      p.minorCasing,
      [
        [12, 1],
        [14, 3],
        [18, 12]
      ],
      12
    ),
    (
      'tertiary',
      ['tertiary'],
      p.minor,
      p.minorCasing,
      [
        [10, 1],
        [14, 4],
        [18, 16]
      ],
      10
    ),
    (
      'secondary',
      ['secondary'],
      p.secondary,
      p.secondaryCasing,
      [
        [8, 1],
        [12, 2.5],
        [18, 18]
      ],
      8
    ),
    (
      'primary',
      ['primary'],
      p.primary,
      p.primaryCasing,
      [
        [6, 1],
        [12, 3],
        [18, 20]
      ],
      6
    ),
    (
      'trunk',
      ['trunk'],
      p.trunk,
      p.trunkCasing,
      [
        [5, 1],
        [12, 3.5],
        [18, 22]
      ],
      5
    ),
    (
      'motorway',
      ['motorway'],
      p.motorway,
      p.motorwayCasing,
      [
        [4, 1],
        [12, 4],
        [18, 24]
      ],
      4
    ),
  ];
  List<List<num>> wider(List<List<num>> stops) => [
        for (final s in stops) [s[0], s[1] * 1.35 + 0.8]
      ];

  return {
    'version': 8,
    'name': night ? 'TruckMaps noc' : 'TruckMaps dzień',
    'sources': {
      'openmaptiles': {'type': 'vector'},
    },
    'layers': [
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': p.land},
      },
      _fill('farmland', 'landcover', ['==', 'class', 'farmland'], p.farmland),
      _fill('grass', 'landcover', ['in', 'class', 'grass', 'wetland'], p.grass),
      _fill('wood', 'landcover', ['==', 'class', 'wood'], p.wood),
      _fill('residential', 'landuse', ['in', 'class', 'residential', 'suburb', 'neighbourhood'], p.residential,
          minzoom: 9),
      _fill('industrial', 'landuse',
          ['in', 'class', 'industrial', 'commercial', 'retail', 'railway', 'garages', 'quarry'], p.industrial,
          minzoom: 10),
      _fill('cemetery', 'landuse', ['==', 'class', 'cemetery'], p.grass, minzoom: 12),
      _fill('park', 'park', all, p.grass, minzoom: 9),
      _fill('water', 'water', all, p.water),
      _line(
          'waterway',
          'waterway',
          ['!=', 'brunnel', 'tunnel'],
          p.waterLine,
          _width([
            [8, 0.5],
            [14, 1.5],
            [18, 4],
          ]),
          minzoom: 8),
      _fill('aeroway', 'aeroway', ['==', '\$type', 'Polygon'], p.industrial, minzoom: 11),
      _line(
          'boundary_country',
          'boundary',
          ['==', 'admin_level', 2],
          p.boundary,
          _width([
            [3, 1],
            [10, 2.5],
          ])),
      _fill('building', 'building', all, p.building, minzoom: 13, outline: p.buildingOutline),
      _line(
          'rail',
          'transportation',
          ['in', 'class', 'rail', 'transit'],
          p.rail,
          _width([
            [10, 0.6],
            [16, 2],
          ]),
          minzoom: 10),
      for (final (id, classes, _, casing, stops, minzoom) in roads)
        _line('${id}_casing', 'transportation', ['in', 'class', ...classes], casing, _width(wider(stops)),
            minzoom: minzoom),
      for (final (id, classes, color, _, stops, minzoom) in roads)
        _line(id, 'transportation', ['in', 'class', ...classes], color, _width(stops), minzoom: minzoom),

      // Nazwy: woda, ulice, numery domów, miejscowości i dzielnice.
      _text('water_name', 'water_name', all, '{name}',
          color: p.waterLabel,
          halo: p.labelHalo,
          minzoom: 11,
          spacing: 0.15,
          size: _width([
            [11, 11],
            [16, 14],
          ], base: 1)),
      _text('street_name', 'transportation_name',
          ['in', 'class', 'minor', 'tertiary', 'secondary', 'primary', 'trunk', 'service'], '{name}',
          color: p.label,
          halo: p.labelHalo,
          minzoom: 14,
          line: true,
          size: _width([
            [14, 11],
            [18, 14],
          ], base: 1)),
      _text('housenumber', 'housenumber', all, '{housenumber}',
          color: p.labelMuted,
          halo: p.labelHalo,
          minzoom: 17,
          size: _width([
            [17, 10],
            [19, 12],
          ], base: 1)),
      _shield('shield_red', ['in', 'route_1_network', ..._redNetworks], '{route_1_ref}', 'shield_red_{ref_length}',
          p.shieldText),
      _shield('shield_yellow', ['in', 'route_1_network', ..._yellowNetworks], '{route_1_ref}',
          'shield_yellow_{ref_length}', p.shieldTextDark,
          minzoom: 9),
      _shield('shield_green_1', ['in', 'route_1_network', ..._greenNetworks], '{route_1_ref}', 'shield_green_4',
          p.shieldText),
      _shield('shield_green_2', ['in', 'route_2_network', ..._greenNetworks], '{route_2_ref}', 'shield_green_4',
          p.shieldText),
      _shield('shield_green_3', ['in', 'route_3_network', ..._greenNetworks], '{route_3_ref}', 'shield_green_4',
          p.shieldText),
      // Numer bez relacji w danych: kolor według klasy drogi.
      _shield(
          'shield_other',
          [
            'all',
            ['has', 'ref'],
            ['!has', 'route_1_network'],
            ['in', 'class', 'motorway', 'trunk', 'primary'],
          ],
          '{ref}',
          'shield_red_{ref_length}',
          p.shieldText,
          minzoom: 8),
      // Drogi wojewódzkie i powiatowe bez relacji w danych – żółte.
      _shield(
          'shield_yellow_other',
          [
            'all',
            ['has', 'ref'],
            ['!has', 'route_1_network'],
            ['in', 'class', 'secondary', 'tertiary'],
          ],
          '{ref}',
          'shield_yellow_{ref_length}',
          p.shieldTextDark,
          minzoom: 10),
      _text('suburb', 'place', ['in', 'class', 'suburb', 'quarter', 'neighbourhood'], '{name}',
          color: p.labelMuted,
          halo: p.labelHalo,
          minzoom: 12,
          upper: true,
          spacing: 0.25,
          size: _width([
            [12, 10],
            [16, 13],
          ], base: 1)),
      _text('village', 'place', ['in', 'class', 'village', 'hamlet', 'isolated_dwelling'], '{name}',
          color: p.label,
          halo: p.labelHalo,
          minzoom: 10,
          size: _width([
            [10, 11],
            [15, 15],
          ], base: 1)),
      _text('town', 'place', ['==', 'class', 'town'], '{name}',
          color: p.label,
          halo: p.labelHalo,
          minzoom: 7,
          size: _width([
            [7, 12],
            [14, 18],
          ], base: 1)),
      _text('city', 'place', ['==', 'class', 'city'], '{name}',
          color: p.label,
          halo: p.labelHalo,
          haloWidth: 2,
          minzoom: 4,
          size: _width([
            [4, 12],
            [12, 22],
          ], base: 1)),
    ],
  };
}
