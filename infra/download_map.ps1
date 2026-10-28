# Pobiera mapy OSM z Geofabrik do infra\data\valhalla i sprawdza sumy MD5.
# Uruchomienie z katalogu glownego repozytorium:
#   powershell -ExecutionPolicy Bypass -File infra\download_map.ps1
#   powershell -ExecutionPolicy Bypass -File infra\download_map.ps1 -Regions poland,germany
# Po pobraniu nowych map przebuduj kafelki: usun infra\data\valhalla\valhalla_tiles*
# i uruchom: docker compose -f infra/docker-compose.yml --profile routing up -d valhalla

param([string[]]$Regions = @("poland"))

$ErrorActionPreference = "Stop"
$target = Join-Path $PSScriptRoot "data\valhalla"
New-Item -ItemType Directory -Force $target | Out-Null

foreach ($region in $Regions) {
    $name = "$region-latest.osm.pbf"
    $url = "https://download.geofabrik.de/europe/$name"
    $file = Join-Path $target $name
    Write-Host "Pobieranie $url"
    curl.exe -sSL --fail -o "$file.md5" "$url.md5"
    curl.exe -sSL --fail -o $file $url
    if ($LASTEXITCODE -ne 0) { throw "Nie udalo sie pobrac $url" }
    $expected = (Get-Content "$file.md5").Split(" ")[0]
    $actual = (Get-FileHash $file -Algorithm MD5).Hash.ToLower()
    if ($actual -ne $expected) { throw "Niezgodna suma MD5 dla $name" }
    Write-Host ("OK {0} ({1:N0} MB)" -f $name, ((Get-Item $file).Length / 1MB))
}
