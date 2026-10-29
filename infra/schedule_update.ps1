# Rejestruje w Harmonogramie zadan Windows cotygodniowa aktualizacje danych (infra\update_data.ps1).
# Uruchomienie z katalogu glownego repozytorium:
#   powershell -ExecutionPolicy Bypass -File infra\schedule_update.ps1                 # niedziela 03:00
#   powershell -ExecutionPolicy Bypass -File infra\schedule_update.ps1 -Day Wednesday -At 02:30
#   powershell -ExecutionPolicy Bypass -File infra\schedule_update.ps1 -Remove
# Zadanie dziala na koncie zalogowanego uzytkownika (Docker Desktop musi byc uruchomiony).
# Gdy komputer byl wylaczony o tej porze, aktualizacja ruszy po wlaczeniu.
# Wynik ostatniego uruchomienia: infra\data\aktualizacja.json.

param(
    [ValidateSet("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")]
    [string]$Day = "Sunday",
    [string]$At = "03:00",
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$name = "TruckMaps - aktualizacja danych"
$root = Resolve-Path "$PSScriptRoot\.."

if ($Remove) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    Write-Host "Usunieto zadanie: $name"
    return
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" -WorkingDirectory $root `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\update_data.ps1`""
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $At
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
    -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings `
    -Description "Mapy OSM, trasy, ograniczenia, parkingi i wyszukiwarka TruckMaps (kontrola przed podmiana)" `
    -Force | Out-Null
Write-Host "Zarejestrowano: $name - co tydzien, $Day $At"
