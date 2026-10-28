# Przygotowuje wyszukiwarke adresow Photon dla Polski (darmowa, dane OSM).
# Uruchomienie z katalogu glownego repozytorium:
#   powershell -ExecutionPolicy Bypass -File infra\photon_import.ps1
# Kroki: pobranie Photon i danych (przez Windows – kontenery nie ufaja certyfikatom
# w tej sieci), rozpakowanie .zst w Pythonie, import do bazy Photon w kontenerze.
# Po imporcie: docker compose -f infra/docker-compose.yml --profile search up -d photon

param(
    [string]$Release = "261025",
    [string]$PhotonVersion = "1.3.0"
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\.."
$target = Join-Path $PSScriptRoot "data\photon"
$python = Join-Path $root ".venv\Scripts\python.exe"
$dump = "photon-dump-poland-release-$Release.jsonl.zst"
$baseUrl = "https://download1.graphhopper.com/public/europe/poland"
New-Item -ItemType Directory -Force $target | Out-Null

if (-not (Test-Path "$target\photon.jar")) {
    curl.exe -sSL --fail -o "$target\photon.jar" "https://github.com/komoot/photon/releases/download/$PhotonVersion/photon-$PhotonVersion.jar"
}
if (-not (Test-Path "$target\$dump")) {
    Write-Host "Pobieranie $dump"
    curl.exe -sSL --fail -o "$target\$dump" "$baseUrl/$dump"
    $expected = (curl.exe -sSL --fail "$baseUrl/$dump.md5").Split(" ")[0]
    if ((Get-FileHash "$target\$dump" -Algorithm MD5).Hash.ToLower() -ne $expected) { throw "Niezgodna suma MD5" }
}

Write-Host "Rozpakowywanie..."
& $python -m pip install --quiet zstandard
& $python -c "import sys, zstandard; zstandard.ZstdDecompressor().copy_stream(open(sys.argv[1], 'rb'), open(sys.argv[2], 'wb'), write_size=1 << 24)" "$target\$dump" "$target\dump.jsonl"
if ($LASTEXITCODE -ne 0) { throw "Rozpakowanie nie powiodlo sie" }

Write-Host "Import do Photon (kilkanascie minut)..."
if (Test-Path "$target\data") { Remove-Item -Recurse -Force "$target\data" }
docker run --rm -v "${target}:/photon" eclipse-temurin:21-jre `
    java -Xmx8g -jar /photon/photon.jar import -import-file /photon/dump.jsonl -data-dir /photon/data -languages pl,en,de
if ($LASTEXITCODE -ne 0) { throw "Import Photon nie powiodl sie" }
Remove-Item "$target\dump.jsonl"
Write-Host "Gotowe: $target\data"
