# Mapa wektorowa: kafelki PMTiles (schemat OpenMapTiles) z plikow OSM, Planetiler.
# Uruchomienie z katalogu glownego repozytorium:
#   powershell -ExecutionPolicy Bypass -File infra\build_tiles.ps1
#   powershell -ExecutionPolicy Bypass -File infra\build_tiles.ps1 -Country germany
# Potrzebne (katalog infra\data jest poza gitem):
#   infra\data\tools\jdk-21                 - Java 21 (Eclipse Temurin)
#   infra\data\tools\planetiler\planetiler.jar
#   infra\data\osm\<kraj>-latest.osm.pbf    - pobierany przez infra\update_data.ps1
# Wynik: infra\data\tiles\<kraj>.pmtiles - serwer oddaje go pod /api/tiles (TRUCKMAPS_TILES_DIR).
# Nowy plik powstaje obok i podmienia stary dopiero po udanym przebiegu.
param(
    [string]$Country = "poland",
    [string]$Memory = "8g"
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\.."
$tools = Join-Path $root "infra\data\tools"
$java = Join-Path $tools "jdk-21\bin\java.exe"
$jar = Join-Path $tools "planetiler\planetiler.jar"
$osm = Join-Path $root "infra\data\osm\$Country-latest.osm.pbf"
$tiles = Join-Path $root "infra\data\tiles"
$work = Join-Path $tools "planetiler"

foreach ($path in @($java, $jar, $osm)) {
    if (-not (Test-Path $path)) { throw "Brak pliku: $path" }
}
New-Item -ItemType Directory -Force $tiles | Out-Null
$output = Join-Path $tiles "$Country.pmtiles"
$partial = Join-Path $tiles "$Country.new.pmtiles"

# Dane uzupelniajace (wybrzeza, Natural Earth) pobiera sam Planetiler przy pierwszym uruchomieniu;
# magazyn certyfikatow Windows zamiast wlasnego magazynu Javy.
& $java "-Xmx$Memory" "-Djavax.net.ssl.trustStoreType=Windows-ROOT" -jar $jar `
    "--osm_path=$osm" --download "--download_dir=$(Join-Path $work 'sources')" `
    "--tmpdir=$(Join-Path $work 'tmp')" "--output=$partial" --force
if ($LASTEXITCODE -ne 0) { throw "Planetiler zakonczyl sie bledem ($LASTEXITCODE)" }

Move-Item -Force $partial $output
Write-Host "Gotowe: $output ($([math]::Round((Get-Item $output).Length / 1MB)) MB)"
