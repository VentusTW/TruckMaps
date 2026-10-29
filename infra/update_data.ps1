# Cotygodniowa aktualizacja danych: mapy, trasy, ograniczenia, parkingi, wyszukiwarka.
# Uruchomienie z katalogu glownego repozytorium (albo z harmonogramu: infra\schedule_update.ps1):
#   powershell -ExecutionPolicy Bypass -File infra\update_data.ps1
#   powershell -ExecutionPolicy Bypass -File infra\update_data.ps1 -Force   # przebuduj nawet bez nowych danych
# Kroki:
#   1. pobieraj: mapy krajow i zrzut wyszukiwarki - tylko to, co zmienilo sie na serwerach
#   2. nowe mapy -> build_routing.ps1 (kontrola tras testowych przed podmiana), potem
#      ograniczenia i parkingi z kopia poprzednich (schemat "kopia") i kontrola liczby wpisow
#   3. nowy zrzut -> photon_import.ps1 (kontrola zapytan przed podmiana)
# Kazdy krok, ktory nie przejdzie kontroli, zostawia poprzednie dane. Powrot do poprzednich
# danych po podmianie: infra\rollback.ps1 trasy|ograniczenia|wyszukiwarka|wszystko.
# Wynik: infra\data\aktualizacja.json (ostatnie uruchomienie) i infra\data\aktualizacja.log.

param(
    [string[]]$Regions = @("poland", "germany", "czech-republic", "slovakia", "lithuania"),
    [string]$SearchCountries = "pl,de,cz,sk,lt",
    [switch]$Force
)
$Regions = $Regions | ForEach-Object { $_ -split "," } | Where-Object { $_ }

$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\.."
$data = Join-Path $PSScriptRoot "data"
$python = Join-Path $root ".venv\Scripts\python.exe"
$compose = Join-Path $PSScriptRoot "docker-compose.yml"
$manifest = Join-Path $data "pobrane.json"
$status = [ordered]@{ start = (Get-Date).ToString("s"); koniec = $null; wynik = "w toku"; kroki = @() }
. "$PSScriptRoot\db_backup.ps1"

function Write-Status {
    $status | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 (Join-Path $data "aktualizacja.json")
}

function Step([string]$Name, [scriptblock]$Action) {
    Write-Host "=== $Name $(Get-Date -Format HH:mm)"
    $entry = [ordered]@{ krok = $Name; wynik = "w toku"; start = (Get-Date).ToString("s") }
    $status.kroki += $entry
    Write-Status
    try {
        & $Action
        $entry.wynik = "OK"
    } catch {
        $entry.wynik = "BLAD: $($_.Exception.Message)"
        throw
    } finally {
        $entry.koniec = (Get-Date).ToString("s")
        Write-Status
    }
}

function Downloaded {
    # Kiedy pobrano kazdy plik - po porownaniu wiadomo, co jest nowe.
    if (-not (Test-Path $manifest)) { return @{} }
    $entries = @{}
    (Get-Content $manifest -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $entries[$_.Name] = $_.Value.finished }
    return $entries
}

New-Item -ItemType Directory -Force $data | Out-Null
# Wyjscie programow idzie przez "| Out-Host", bo Start-Transcript w PowerShell 5.1 inaczej go nie zapisuje.
Start-Transcript -Append (Join-Path $data "aktualizacja.log") | Out-Null
try {
    Step "Uslugi Dockera" {
        docker compose -f $compose --profile routing --profile search up -d --wait
        if ($LASTEXITCODE -ne 0) { throw "Docker nie dziala albo uslugi nie wystartowaly" }
    }

    $before = Downloaded
    Step "Pobieranie" {
        & $python -u (Join-Path $root "tools\pobieraj\pobieraj.py") mapy @Regions | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Pobieranie map nie powiodlo sie" }
        & $python -u (Join-Path $root "tools\pobieraj\pobieraj.py") photon | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Pobieranie zrzutu wyszukiwarki nie powiodlo sie" }
    }
    $after = Downloaded
    $changed = $after.Keys | Where-Object { $before[$_] -ne $after[$_] }
    $newMaps = $Force -or ($changed | Where-Object { $_ -like "infra/data/osm/*" })
    $dump = $after.Keys | Where-Object { $_ -match "photon-dump-europe-release-(\d{6})" } |
        Sort-Object | Select-Object -Last 1
    $newSearch = $Force -or ($changed -contains $dump)
    Write-Host "Nowe mapy: $([bool]$newMaps), nowy zrzut wyszukiwarki: $([bool]$newSearch)"

    if ($newMaps) {
        Step "Dane tras" {
            & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "build_routing.ps1") -Regions ($Regions -join ",") | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Budowa albo kontrola danych tras nie powiodla sie - zostaja poprzednie" }
        }
        Step "Ograniczenia i parkingi" {
            $previous = Backup-Tables
            $pbf = Join-Path $data "valhalla\region.osm.pbf"
            foreach ($import in "import_restrictions.py", "import_parkings.py") {
                & $python -u (Join-Path $root "data_pipeline\$import") $pbf | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    Restore-Tables
                    throw "$import nie powiodl sie - przywrocono poprzednie dane"
                }
            }
            # Duzo mniej wpisow niz poprzednio = prawie na pewno blad danych, nie zmiana na drogach.
            foreach ($table in $previous.Keys) {
                $now = Count-Rows $table
                Write-Host "   ${table}: $now (poprzednio $($previous[$table]))"
                if ($now -lt 0.9 * $previous[$table]) {
                    Restore-Tables
                    throw "$table ma o ponad 10% mniej wpisow niz poprzednio - przywrocono poprzednie dane"
                }
            }
        }
    }

    if ($newSearch) {
        $release = [regex]::Match($dump, "release-(\d{6})").Groups[1].Value
        Step "Wyszukiwarka ($release)" {
            & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "photon_import.ps1") -Release $release -Countries $SearchCountries | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Import albo kontrola wyszukiwarki nie powiodly sie - zostaje poprzednia" }
            # Starsze zrzuty nie sa juz potrzebne (13 GB kazdy).
            Get-ChildItem (Join-Path $data "photon") -Filter "photon-dump-europe-release-*" |
                Where-Object { $_.Name -notlike "*$release*" } | Remove-Item
        }
    }
    $status.wynik = if ($newMaps -or $newSearch) { "OK" } else { "OK - brak nowych danych" }
} catch {
    $status.wynik = "BLAD: $($_.Exception.Message)"
    Write-Host $status.wynik
    exit 1
} finally {
    $status.koniec = (Get-Date).ToString("s")
    Write-Status
    Stop-Transcript | Out-Null
}
