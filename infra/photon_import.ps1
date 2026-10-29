# Przygotowuje wyszukiwarke adresow Photon (darmowa, dane OSM) dla wybranych krajow.
# Uruchomienie z katalogu glownego repozytorium:
#   powershell -ExecutionPolicy Bypass -File infra\photon_import.ps1
#   powershell -ExecutionPolicy Bypass -File infra\photon_import.ps1 -Countries pl,de,cz,sk,lt,at
# Zrzut obejmuje cala Europe (nie dla kazdego kraju jest osobny), a do bazy trafiaja
# tylko kraje z -Countries. Kolejny kraj = ponowny import, bez ponownego pobierania.
# Kroki:
#   1. pobranie Photon i zrzutu (przez Windows - kontenery nie ufaja certyfikatom w tej sieci)
#   2. wybor krajow w Pythonie (minuty zamiast godzin w Photon)
#   3. import w kontenerze do wolumenu truckmaps-photon-import (szybki dysk Linuksa);
#      dzialajaca wyszukiwarka korzysta w tym czasie ze starej bazy
#   4. kontrola: nowa baza na chwile na porcie 2323, zapytania z infra\testy_danych.json
#   5. kopia do wolumenu truckmaps-photon-data (poprzednia zostaje w truckmaps-photon-previous)

param(
    [string]$Release = "261025",
    [string]$PhotonVersion = "1.3.0",
    [string]$Countries = "pl,de,cz,sk,lt"
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\.."
$target = Join-Path $PSScriptRoot "data\photon"
$python = Join-Path $root ".venv\Scripts\python.exe"
$compose = Join-Path $PSScriptRoot "docker-compose.yml"
$dump = "photon-dump-europe-release-$Release.jsonl.zst"
$selected = "photon-$($Countries -replace ',', '-').jsonl.zst"
$baseUrl = "https://download1.graphhopper.com/public/europe"
$started = Get-Date
New-Item -ItemType Directory -Force $target | Out-Null

if (-not (Test-Path "$target\photon.jar")) {
    curl.exe -sSL --fail -o "$target\photon.jar" "https://github.com/komoot/photon/releases/download/$PhotonVersion/photon-$PhotonVersion.jar"
}
if (-not (Test-Path "$target\$dump.ok")) {
    # Zwykle pobrane wczesniej poza sesja: dist\pobieraj.exe photon (tworzy znacznik .ok).
    Write-Host "1/5 Pobieranie $dump (ok. 13 GB)"
    & $python -u "$root\tools\pobieraj\pobieraj.py" photon --wydanie $Release
    if ($LASTEXITCODE -ne 0) { throw "Nie udalo sie pobrac $dump" }
}

Write-Host "2/5 Wybor krajow: $Countries"
& $python -m pip install --quiet zstandard
& $python -u "$PSScriptRoot\photon_filter.py" "$target\$dump" "$target\$selected" $Countries
if ($LASTEXITCODE -ne 0) { throw "Wybor krajow nie powiodl sie" }

Write-Host "3/5 Import do Photon"
docker build -q -t truckmaps-photon "$PSScriptRoot\photon" | Out-Null
docker volume create truckmaps-photon-import | Out-Null
$import = "rm -rf /import/* && zstd -dc /photon/$selected" +
    " | java -Xmx8g -jar /photon/photon.jar import -import-file - -data-dir /import -languages pl,en,de"
docker run --rm -v "${target}:/photon" -v truckmaps-photon-import:/import truckmaps-photon sh -c $import
if ($LASTEXITCODE -ne 0) { throw "Import Photon nie powiodl sie" }
Remove-Item "$target\$selected"

Write-Host "4/5 Kontrola nowej bazy (zapytania z infra\testy_danych.json)"
# Nowa baza na chwile na porcie 2323, obok dzialajacej wyszukiwarki (2322).
$check = "truckmaps-photon-check"
$ErrorActionPreference = "Continue"
docker rm -f $check 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
docker run -d --rm --name $check -p 127.0.0.1:2323:2322 -v "${target}:/photon" -v truckmaps-photon-import:/photon-data `
    truckmaps-photon java -Xmx4g -jar /photon/photon.jar serve -data-dir /photon-data -listen-ip 0.0.0.0 | Out-Null
& $python -u (Join-Path $root "tools\dane\sprawdz.py") wyszukiwarka --adres http://127.0.0.1:2323
$checked = $LASTEXITCODE -eq 0
docker stop $check | Out-Null
if (-not $checked) { throw "Nowa baza wyszukiwarki nie przeszla kontroli - zostaje obecna (nowa w wolumenie truckmaps-photon-import)" }

# Baza dzialajacej wyszukiwarki jest w wolumenie truckmaps-photon-data (docker-compose.yml),
# poprzednia zostaje w truckmaps-photon-previous (powrot: infra\rollback.ps1 wyszukiwarka).
Write-Host "5/5 Podmiana bazy wyszukiwarki (kilka minut przerwy)"
docker volume create truckmaps-photon-data | Out-Null
docker volume create truckmaps-photon-previous | Out-Null
docker compose -f $compose --profile search stop photon
docker run --rm -v truckmaps-photon-import:/import -v truckmaps-photon-data:/photon-data `
    -v truckmaps-photon-previous:/previous truckmaps-photon `
    sh -c "rm -rf /previous/* && cp -a /photon-data/. /previous/ && rm -rf /photon-data/* && cp -a /import/. /photon-data/"
if ($LASTEXITCODE -ne 0) { throw "Kopiowanie bazy nie powiodlo sie - powrot: infra\rollback.ps1 wyszukiwarka" }
docker compose -f $compose --profile search up -d photon
docker volume rm truckmaps-photon-import | Out-Null
Write-Host ("Gotowe po {0:N0} min: {1}" -f ((Get-Date) - $started).TotalMinutes, $Countries)
