# Laczy mapy krajow i buduje dane tras Valhalli bez przerwy w dzialaniu tras.
# Uruchomienie z katalogu glownego repozytorium (po pobraniu map: dist\pobieraj.exe mapy):
#   powershell -ExecutionPolicy Bypass -File infra\build_routing.ps1
#   powershell -ExecutionPolicy Bypass -File infra\build_routing.ps1 -Regions poland,germany
# Kroki:
#   1. osmium merge map z infra\data\osm (mapy krajow nachodza na siebie przy granicach)
#      -> region.osm.pbf; gdy jest nowszy od map krajow, zostaje uzyty ponownie
#   2. budowa kafelkow w wolumenie Dockera (szybki dysk Linuksa), etapami z ponawianiem
#      (infra\valhalla_build.sh - Valhalla losowo pada przy duzej mapie)
#   3. kontrola: nowe dane na chwile na porcie 8003, trasy testowe (infra\testy_danych.json)
#      porownane z obecnymi; zle dane nie wchodza
#   4. podmiana katalogow: dzialajaca Valhalla korzysta ze starych danych az do tej chwili,
#      a poprzednie zostaja w infra\data\valhalla-previous (powrot: infra\rollback.ps1 trasy)
# Ten sam plik infra\data\valhalla\region.osm.pbf czytaja import_restrictions.py i import_parkings.py.

param(
    [string[]]$Regions = @("poland", "germany", "czech-republic", "slovakia", "lithuania"),
    # Podmiana mimo nieudanej kontroli - np. gdy zmienia sie lista krajow i trasy testowe musza sie zmienic.
    [switch]$SkipCheck
)
$Regions = $Regions | ForEach-Object { $_ -split "," } | Where-Object { $_ }

$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\.."
$python = Join-Path $root ".venv\Scripts\python.exe"
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
    Write-Host "1/4 Polaczona mapa jest nowsza od map krajow - uzywam jej ponownie"
} else {
    Write-Host "1/4 Laczenie map: $($Regions -join ', ')"
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

Write-Host "2/4 Budowa kafelkow Valhalli (godzina lub dluzej)..."
# Wolumen zostaje po nieudanej budowie (granice i strefy czasowe nie licza sie od nowa);
# inna mapa = czysty wolumen.
docker volume create $volume | Out-Null
# Skrypt kopiuje mape do wolumenu, buduje i odklada wynik do infra\data\valhalla-new (/out).
docker run --rm -v "${build}:/out" -v "${volume}:/custom_files" -v "${PSScriptRoot}:/scripts:ro" `
    --entrypoint bash ghcr.io/valhalla/valhalla-scripted:latest /scripts/valhalla_build.sh
if ($LASTEXITCODE -ne 0) { throw "Budowa kafelkow nie powiodla sie - wolumen $volume zostaje, uruchom ponownie" }
if (-not (Test-Path "$build\valhalla_tiles.tar")) { throw "Brak archiwum kafelkow po budowie" }
docker volume rm $volume | Out-Null

Write-Host "3/4 Kontrola nowych danych (trasy testowe z infra\testy_danych.json)"
# Nowe dane na chwile na porcie 8003, obok dzialajacej Valhalli (8002), i porownanie tras.
$check = "truckmaps-valhalla-check"
$ErrorActionPreference = "Continue"
docker rm -f $check 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
docker run -d --rm --name $check -p 127.0.0.1:8003:8002 -v "${build}:/custom_files" `
    -e tile_urls= -e use_tiles_ignore_pbf=True -e build_admins=True -e build_time_zones=True `
    -e build_elevation=False -e serve_tiles=True -e force_rebuild=False -e use_default_speeds_config=False `
    ghcr.io/valhalla/valhalla-scripted:latest | Out-Null
& $python -u (Join-Path $root "tools\dane\sprawdz.py") trasy --nowe http://127.0.0.1:8003 --obecne http://127.0.0.1:8002
$checked = $LASTEXITCODE -eq 0
docker stop $check | Out-Null
if (-not $checked -and -not $SkipCheck) {
    throw "Nowe dane tras nie przeszly kontroli - zostaja obecne. Nowe sa w infra\data\valhalla-new."
}

Write-Host "4/4 Podmiana danych tras (poprzednie zostaja w infra\data\valhalla-previous)"
docker compose -f $compose --profile routing stop valhalla
if (Test-Path "$live-previous") { Remove-Item -Recurse -Force "$live-previous" }
if (Test-Path $live) { Rename-Item $live "valhalla-previous" }
Rename-Item $build "valhalla"
docker compose -f $compose --profile routing up -d valhalla
if ($LASTEXITCODE -ne 0) { throw "Valhalla nie wystartowala - powrot: infra\rollback.ps1 trasy" }
Write-Host ("Gotowe po {0:N0} min" -f ((Get-Date) - $started).TotalMinutes)
