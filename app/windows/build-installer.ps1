# Packs the built Windows app into builds/kintura-<version>-<build>-windows-setup.exe.
# Used by make build-windows-installer and .github/workflows/deploy.yml.
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Build
)

$iscc = Get-ChildItem -ErrorAction SilentlyContinue -Path @(
    "${env:ProgramFiles(x86)}\Inno Setup *\ISCC.exe",
    "$env:ProgramFiles\Inno Setup *\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup *\ISCC.exe"
) | Select-Object -First 1

if (-not $iscc) {
    Write-Host "Inno Setup nicht gefunden. Installieren mit: winget install JRSoftware.InnoSetup"
    exit 1
}

& $iscc.FullName /Q "/DAppVersion=$Version" "/DBuildNumber=$Build" "$PSScriptRoot\installer.iss"
exit $LASTEXITCODE
