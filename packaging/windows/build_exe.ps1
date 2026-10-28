# Buduje dist\TruckMaps-Server.exe z rdzeniem i wszystkimi modułami z backend\modules.
# Uruchomienie z katalogu głównego repozytorium:
#   powershell -ExecutionPolicy Bypass -File packaging\windows\build_exe.ps1

$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\..\.."
$python = Join-Path $root ".venv\Scripts\python.exe"

& $python -m pip install --quiet "pyinstaller>=6.10"
if ($LASTEXITCODE -ne 0) { throw "Instalacja PyInstallera nie powiodła się" }

$moduleArgs = @()
foreach ($dir in Get-ChildItem (Join-Path $root "backend\modules") -Directory) {
    $pyproject = Get-Content (Join-Path $dir.FullName "pyproject.toml") -Raw
    $dist = [regex]::Match($pyproject, '(?m)^name\s*=\s*"([^"]+)"').Groups[1].Value
    $package = (Get-ChildItem (Join-Path $dir.FullName "src") -Directory | Select-Object -First 1).Name
    # Moduły są wykrywane przez entry pointy, więc PyInstaller musi dostać ich kod i metadane.
    $moduleArgs += @("--collect-submodules", $package, "--copy-metadata", $dist)
}

& $python -m PyInstaller `
    --noconfirm --clean --onefile --console `
    --name TruckMaps-Server `
    --distpath (Join-Path $root "dist") `
    --workpath (Join-Path $root "build\pyinstaller") `
    --specpath (Join-Path $root "build\pyinstaller") `
    --collect-submodules uvicorn `
    --copy-metadata truckmaps-backend `
    --collect-data truckmaps `
    --collect-submodules psycopg `
    --collect-all psycopg_binary `
    @moduleArgs `
    (Join-Path $root "backend\src\truckmaps\core\__main__.py")
if ($LASTEXITCODE -ne 0) { throw "Budowanie exe nie powiodło się" }

Write-Host "Gotowe: $(Join-Path $root 'dist\TruckMaps-Server.exe')"
