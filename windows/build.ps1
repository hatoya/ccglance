# Local Windows build: publishes a single-file ccglance.exe and packs
# build\ccglance_windows.zip + .sha256, the same layout release.yml produces.
# VERSION comes from ..\build.sh (the single version source).
#
#   powershell -ExecutionPolicy Bypass -File windows\build.ps1 [-Run]
param([switch]$Run)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

$version = (Select-String -Path build.sh -Pattern '^VERSION="([^"]+)"').Matches[0].Groups[1].Value
$out = "build\windows\ccglance"
$zip = "build\ccglance_windows.zip"

node windows\tools\gen-crab-frames.js --check
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (Test-Path build\windows) { Remove-Item build\windows -Recurse -Force }
dotnet publish windows\ccglance.csproj -c Release -r win-x64 --self-contained `
    -p:PublishSingleFile=true -p:Version=$version -o $out
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Get-ChildItem $out -Filter *.pdb | Remove-Item -Force

if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $out -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  ccglance_windows.zip`n" | Out-File -FilePath "$zip.sha256" -Encoding ascii -NoNewline

Write-Host "Done: $out\ccglance.exe (v$version)"
Write-Host "Release: upload $zip and $zip.sha256"
if ($Run) { Start-Process "$out\ccglance.exe" }
