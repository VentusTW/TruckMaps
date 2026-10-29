# Buduje dist\pobieraj.exe - pobieranie duzych danych (mapy OSM, zrzut Photon) poza sesja.
# Uruchomienie z katalogu glownego repozytorium:
#   powershell -ExecutionPolicy Bypass -File packaging\windows\build_pobieraj.ps1
# Exe szuka katalogu projektu w gore od swojego polozenia, wiec dziala z dist\.

$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\..\.."
$python = Join-Path $root ".venv\Scripts\python.exe"

& $python -m pip install --quiet "pyinstaller>=6.10"
if ($LASTEXITCODE -ne 0) { throw "Instalacja PyInstallera nie powiodla sie" }

& $python -m PyInstaller `
    --noconfirm --clean --onefile --console `
    --name pobieraj `
    --distpath (Join-Path $root "dist") `
    --workpath (Join-Path $root "build\pyinstaller") `
    --specpath (Join-Path $root "build\pyinstaller") `
    (Join-Path $root "tools\pobieraj\pobieraj.py")
if ($LASTEXITCODE -ne 0) { throw "Budowanie pobieraj.exe nie powiodlo sie" }

Write-Host "Gotowe: $(Join-Path $root 'dist\pobieraj.exe')"
