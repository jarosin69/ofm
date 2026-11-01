<#
OFM offline install bundle: check and load (step 2.8). Runs on the plant
server (Windows), from the bundle folder made by tools\make-bundle.ps1:

    powershell -ExecutionPolicy Bypass -File .\offline-load.ps1

1. Checks every file against SHA256SUMS (a damaged or altered copy stops here).
2. Loads every image into Docker (docker load); nothing is downloaded.
3. Checks that every image in images.txt is now present.
Then continue with deploy\README.md, "Installing without internet".
#>
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
# Windows PowerShell 5.1 turns a native command's redirected error output into a
# script-stopping error while $ErrorActionPreference is Stop; relax it for this check.
function Test-Image([string]$image) {
    $saved = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & docker image inspect $image *> $null; return ($LASTEXITCODE -eq 0) }
    finally { $ErrorActionPreference = $saved }
}

Write-Host "== Checking the bundle" -ForegroundColor Cyan
$bad = 0
foreach ($line in (Get-Content (Join-Path $here "SHA256SUMS"))) {
    if (-not $line.Trim()) { continue }
    $hash, $file = $line -split '\s+', 2
    $path = Join-Path $here $file.TrimStart('*')        # "/" works on Windows too
    if (-not (Test-Path $path)) { Write-Host "MISSING  $file" -ForegroundColor Red; $bad++; continue }
    if ((Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower() -ne $hash.ToLower()) {
        Write-Host "DAMAGED  $file" -ForegroundColor Red; $bad++
    } else {
        Write-Host "ok       $file"
    }
}
if ($bad -gt 0) { throw "$bad file(s) missing or damaged: copy the bundle again." }

Write-Host "== Loading images into Docker (a few minutes)" -ForegroundColor Cyan
foreach ($f in (Get-ChildItem (Join-Path $here "images") -Filter "*.tar.gz" | Sort-Object Name)) {
    Write-Host "loading  $($f.Name)"
    & docker load -i $f.FullName
    if ($LASTEXITCODE -ne 0) { throw "docker load failed for $($f.Name). Is Docker running?" }
}

$missing = @()
foreach ($image in (Get-Content (Join-Path $here "images.txt"))) {
    if (-not $image.Trim()) { continue }
    if (-not (Test-Image $image)) { $missing += $image }
}
if ($missing.Count -gt 0) { throw "Not loaded: $($missing -join ', ')" }

Write-Host "== All images loaded." -ForegroundColor Green
Write-Host "Next: deploy\README.md, 'Installing without internet' (unpack ofm-repo.tar.gz, make-env.sh, docker compose up -d)."
