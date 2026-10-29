# Laczy mapy krajow i buduje dane tras Valhalli bez przerwy w dzialaniu tras.
# Uruchomienie z katalogu glownego repozytorium (po pobraniu map: dist\pobieraj.exe mapy):
#   powershell -ExecutionPolicy Bypass -File infra\build_routing.ps1
#   powershell -ExecutionPolicy Bypass -File infra\build_routing.ps1 -Regions poland,germany
# Kroki:
#   1. osmium merge map z infra\data\osm (mapy krajow nachodza na siebie przy granicach)
#      -> region.osm.pbf; gdy jest nowszy od map krajow, zostaje uzyty ponownie
#   2. budowa kafelkow w wolumenie Dockera (szybki dysk Linuksa), etapami z ponawianiem
#      (infra\valhalla_build.sh - Valhalla losowo pada przy duzej mapie)
#   3. kopia wyniku do infra\data\valhalla-new i podmiana katalogow: dzialajaca Valhalla
#      korzysta ze starych danych az do tej chwili
# Ten sam plik infra\data\valhalla\region.osm.pbf czytaja import_restrictions.py i import_parkings.py.

param([string[]]$Regions = @("poland", "germany", "czech-republic", "slovakia", "lithuania"))
$Regions = $Regions | ForEach-Object { $_ -split "," } | Where-Object { $_ }

$ErrorActionPreference = "Stop"
$osm = Join-Path $PSScriptRoot "data\osm"
$live = Join-Path $PSScriptRoot "data\valhalla"
$build = Join-Path $PSScriptRoot "data\valhalla-new"
$compose = Join-Path $PSScriptRoot "docker-compose.yml"
$volume = "truckmaps-valhalla-build"
$started = Get-Date

$maps = foreach ($region in $Regions) {
    $file = "$osm\$region-latest.osm.pbf"
    if (-not (Test-Path $file)) { throw "Brak mapy $region - uruchom dist\pobieraj.exe mapy" }
    Get-Item $file
}
$merged = "$build\region.osm.pbf"
$reuse = (Test-Path $merged) -and -not ($maps | Where-Object { $_.LastWriteTime -gt (Get-Item $merged).LastWriteTime })
if (Test-Path $build) {
    Get-ChildItem $build | Where-Object { -not ($reuse -and $_.Name -eq "region.osm.pbf") } | Remove-Item -Recurse -Force
}
New-Item -ItemType Directory -Force $build | Out-Null
docker build -q -t truckmaps-osmium "$PSScriptRoot\osmium" | Out-Null

if ($reuse) {
    Write-Host "1/3 Polaczona mapa jest nowsza od map krajow - uzywam jej ponownie"
} else {
    Write-Host "1/3 Laczenie map: $($Regions -join ', ')"
    $inputs = ($Regions | ForEach-Object { "/osm/$_-latest.osm.pbf" }) -join " "
    # Geofabrik publikuje kraje z roznych dni (np. Niemcy dzien pozniej), wiec przy granicach
    # ta sama droga bywa w dwoch wersjach - merge zachowuje obie, a time-filter zostawia
    # najnowsza. Valhalla i importy wymagaja jednej wersji kazdego obiektu.
    docker run --rm -v "${osm}:/osm" -v "${build}:/out" --entrypoint sh truckmaps-osmium -c `
        "osmium merge $inputs -o /tmp/merged.osm.pbf && osmium time-filter /tmp/merged.osm.pbf -o /out/region.osm.pbf --overwrite"
    if ($LASTEXITCODE -ne 0) { throw "Laczenie map nie powiodlo sie" }
    $versions = docker run --rm -v "${build}:/out" truckmaps-osmium fileinfo -e -g data.multiple_versions /out/region.osm.pbf
    if ($versions -ne "no") { throw "Polaczona mapa nadal ma kilka wersji tych samych obiektow" }
}
Write-Host ("   {0:N0} MB" -f ((Get-Item $merged).Length / 1MB))

Write-Host "2/3 Budowa kafelkow Valhalli (godzina lub dluzej)..."
# Wolumen zostaje po nieudanej budowie (granice i strefy czasowe nie licza sie od nowa);
# inna mapa = czysty wolumen.
docker volume create $volume | Out-Null
# Skrypt kopiuje mape do wolumenu, buduje i odklada wynik do infra\data\valhalla-new (/out).
docker run --rm -v "${build}:/out" -v "${volume}:/custom_files" -v "${PSScriptRoot}:/scripts:ro" `
    --entrypoint bash ghcr.io/valhalla/valhalla-scripted:latest /scripts/valhalla_build.sh
if ($LASTEXITCODE -ne 0) { throw "Budowa kafelkow nie powiodla sie - wolumen $volume zostaje, uruchom ponownie" }
if (-not (Test-Path "$build\valhalla_tiles.tar")) { throw "Brak archiwum kafelkow po budowie" }
docker volume rm $volume | Out-Null

Write-Host "3/3 Podmiana danych tras"
docker compose -f $compose --profile routing stop valhalla
if (Test-Path "$live-old") { Remove-Item -Recurse -Force "$live-old" }
if (Test-Path $live) { Rename-Item $live "valhalla-old" }
Rename-Item $build "valhalla"
docker compose -f $compose --profile routing up -d valhalla
if ($LASTEXITCODE -ne 0) { throw "Valhalla nie wystartowala - stare dane sa w infra\data\valhalla-old" }
Remove-Item -Recurse -Force "$live-old"
Write-Host ("Gotowe po {0:N0} min" -f ((Get-Date) - $started).TotalMinutes)
