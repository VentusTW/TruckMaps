# Powrot do poprzednich danych po aktualizacji (np. nowe dane okazaly sie bledne).
# Uruchomienie z katalogu glownego repozytorium:
#   powershell -ExecutionPolicy Bypass -File infra\rollback.ps1 trasy
#   powershell -ExecutionPolicy Bypass -File infra\rollback.ps1 wszystko
# Zamienia obecne dane z poprzednimi - ponowne uruchomienie wraca do nowszych.
#   trasy        - infra\data\valhalla <-> infra\data\valhalla-previous
#   ograniczenia - tabele ograniczen i parkingow <-> kopia z poprzedniej aktualizacji
#   wyszukiwarka - wolumen truckmaps-photon-data <-> truckmaps-photon-previous
# Ograniczenia pochodza z tej samej mapy co trasy - zwykle cofa sie oba ("wszystko").

param(
    [Parameter(Mandatory)]
    [ValidateSet("trasy", "ograniczenia", "wyszukiwarka", "wszystko")]
    [string]$What
)

$ErrorActionPreference = "Stop"
$compose = Join-Path $PSScriptRoot "docker-compose.yml"
$data = Join-Path $PSScriptRoot "data"
. "$PSScriptRoot\db_backup.ps1"

if ($What -in "trasy", "wszystko") {
    if (-not (Test-Path "$data\valhalla-previous")) { throw "Brak poprzednich danych tras (infra\data\valhalla-previous)" }
    Write-Host "Trasy: zamiana z poprzednimi"
    docker compose -f $compose --profile routing stop valhalla
    Rename-Item "$data\valhalla" "valhalla-swap"
    Rename-Item "$data\valhalla-previous" "valhalla"
    Rename-Item "$data\valhalla-swap" "valhalla-previous"
    docker compose -f $compose --profile routing up -d valhalla
}

if ($What -in "ograniczenia", "wszystko") {
    Write-Host "Ograniczenia i parkingi: zamiana z kopia"
    $exists = Invoke-Sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'kopia';"
    if ([int]$exists -lt $BackupTables.Count) { throw "Brak kopii ograniczen (schemat kopia)" }
    Restore-Tables
}

if ($What -in "wyszukiwarka", "wszystko") {
    $volumes = docker volume ls -q
    if ($volumes -notcontains "truckmaps-photon-previous") { throw "Brak poprzedniej bazy wyszukiwarki" }
    Write-Host "Wyszukiwarka: zamiana z poprzednia baza (kilka minut)"
    docker compose -f $compose --profile search stop photon
    docker run --rm -v truckmaps-photon-data:/current -v truckmaps-photon-previous:/previous truckmaps-photon `
        sh -c "mkdir /swap && cp -a /current/. /swap/ && rm -rf /current/* && cp -a /previous/. /current/ && rm -rf /previous/* && cp -a /swap/. /previous/"
    if ($LASTEXITCODE -ne 0) { throw "Zamiana baz wyszukiwarki nie powiodla sie" }
    docker compose -f $compose --profile search up -d photon
}
Write-Host "Gotowe: $What"
