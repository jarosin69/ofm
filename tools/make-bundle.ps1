<#
OFM offline install bundle (step 2.8).

Run on a computer with Docker and internet (e.g. the development laptop):

    powershell -ExecutionPolicy Bypass -File C:\ofm\tools\make-bundle.ps1

It writes one folder, by default C:\ofm-bundles\ofm-<version>\, holding
everything a plant server without internet needs:

    images\*.tar.gz     every image the stack uses, at the pinned versions in
                        deploy\docker-compose.yml (OFM's Node-RED image is
                        built here if it is missing)
    ofm-repo.tar.gz     the repository at the last commit: only committed
                        files, so never .env, certificates or keys
    images.txt          the image names, one per line
    MANIFEST.txt        version, commit, date, image IDs and platforms
    SHA256SUMS          checksums of every file, to detect a damaged copy
    offline-load.ps1    run on the plant server (Windows) to check and load
    offline-load.sh     the same for a Linux server

Copy the folder to the plant server (USB drive, file share), then follow
deploy\README.md, "Installing without internet".

Options:
    -OutDir <folder>     where to write the bundle (default: C:\ofm-bundles)
    -AllowUncommitted    bundle the last commit even if the working copy has
                         uncommitted changes (they are NOT included)
Works with Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    [string]$OutDir = "",
    [switch]$AllowUncommitted
)
$ErrorActionPreference = "Stop"

# Images used outside docker-compose.yml: make-env.sh runs in alpine (deploy\README.md step 7).
$ExtraImages = @("alpine:3.22")

$repo = Split-Path -Parent $PSScriptRoot
$compose = Join-Path (Join-Path $repo "deploy") "docker-compose.yml"
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $repo) "ofm-bundles" }

function Invoke-Native([string]$exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "'$exe $($arguments -join ' ')' failed (exit code $LASTEXITCODE)" }
}
function Get-Native([string]$exe, [string[]]$arguments) {
    $out = & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "'$exe $($arguments -join ' ')' failed (exit code $LASTEXITCODE)" }
    return $out
}
function Step([string]$text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }
# Windows PowerShell 5.1 turns a native command's redirected error output into a
# script-stopping error while $ErrorActionPreference is Stop; relax it for this check.
function Test-Image([string]$image) {
    $saved = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & docker image inspect $image *> $null; return ($LASTEXITCODE -eq 0) }
    finally { $ErrorActionPreference = $saved }
}
Add-Type -AssemblyName System.IO.Compression

foreach ($tool in @("git", "docker")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not installed or not on the PATH" }
}

# --- 1. the repository ----------------------------------------------------------------
Step "Repository $repo"
$dirty = Get-Native "git" @("-C", $repo, "status", "--porcelain")
if ($dirty) {
    Write-Host ($dirty -join "`n")
    if (-not $AllowUncommitted) {
        throw "The working copy has uncommitted changes (listed above). Commit them first, so the bundle matches a commit, or use -AllowUncommitted to bundle the last commit without them."
    }
    Write-Warning "Uncommitted changes are NOT in the bundle; it holds the last commit only."
}
$version = (Get-Native "git" @("-C", $repo, "describe", "--tags", "--always")) | Select-Object -First 1
$commit = (Get-Native "git" @("-C", $repo, "rev-parse", "HEAD")) | Select-Object -First 1
Write-Host "OFM $version (commit $commit)"

# --- 2. the images, read from docker-compose.yml ------------------------------------------
Step "Images"
$images = New-Object System.Collections.Generic.List[string]
foreach ($line in (Get-Content $compose)) {
    if ($line -match '^\s*image:\s*["'']?([^\s"''#]+)') {
        if (-not $images.Contains($Matches[1])) { $images.Add($Matches[1]) }
    }
}
foreach ($extra in $ExtraImages) { if (-not $images.Contains($extra)) { $images.Add($extra) } }
foreach ($image in $images) {
    if ($image -notmatch ':[0-9]' -or $image -match ':latest$') {
        throw "Image '$image' is not pinned to a version in docker-compose.yml; the bundle must be reproducible."
    }
}
foreach ($image in $images) {
    if (Test-Image $image) { Write-Host "present   $image"; continue }
    if ($image -like "ofm/node-red:*") {
        Write-Host "building  $image (deploy\nodered\Dockerfile)"
        Invoke-Native "docker" @("build", "-t", $image, (Join-Path (Join-Path $repo "deploy") "nodered"))
    } else {
        Write-Host "pulling   $image"
        Invoke-Native "docker" @("pull", $image)
    }
}

# --- 3. the bundle folder ---------------------------------------------------------------------
$name = "ofm-$version"
$bundle = Join-Path $OutDir $name
if (Test-Path $bundle) { throw "$bundle already exists. Delete it, or choose another -OutDir." }
$imagesDir = Join-Path $bundle "images"
New-Item -ItemType Directory -Force -Path $imagesDir | Out-Null

Step "Saving images (several minutes; a few GB)"
$manifestImages = @()
foreach ($image in $images) {
    $file = ($image -replace '[/:]', '_') + ".tar.gz"
    $tar = Join-Path $imagesDir (($image -replace '[/:]', '_') + ".tar")
    Write-Host "saving    $image -> images/$file"
    Invoke-Native "docker" @("save", "-o", $tar, $image)
    # gzip with .NET: works on every Windows without extra tools; docker load reads .tar.gz.
    $in = [System.IO.File]::OpenRead($tar)
    $out = [System.IO.File]::Create((Join-Path $imagesDir $file))
    $gz = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionLevel]::Optimal)
    try { $in.CopyTo($gz) } finally { $gz.Dispose(); $out.Dispose(); $in.Dispose() }
    Remove-Item $tar
    $info = (Get-Native "docker" @("image", "inspect", "--format", "{{.Id}} {{.Os}}/{{.Architecture}}", $image)) | Select-Object -First 1
    $manifestImages += ("  {0,-48} {1}" -f $image, $info)
}

Step "Repository archive (committed files only)"
Invoke-Native "git" @("-C", $repo, "archive", "--format=tar.gz", "--prefix=ofm/", "-o", (Join-Path $bundle "ofm-repo.tar.gz"), "HEAD")
Copy-Item (Join-Path $PSScriptRoot "offline-load.ps1") $bundle
Copy-Item (Join-Path $PSScriptRoot "offline-load.sh") $bundle

# Text files with Linux line endings, so offline-load.sh and sha256sum read them too.
function Write-LfFile([string]$path, [string[]]$lines) {
    [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}
Write-LfFile (Join-Path $bundle "images.txt") $images.ToArray()
$dockerVersion = (Get-Native "docker" @("version", "--format", "{{.Server.Version}}")) | Select-Object -First 1
Write-LfFile (Join-Path $bundle "MANIFEST.txt") (@(
    "OFM offline install bundle",
    "version:  $version",
    "commit:   $commit",
    "created:  $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC on $([Environment]::MachineName) (Docker $dockerVersion)",
    "images (name, image ID, platform):") + $manifestImages + @(
    "",
    "Install: deploy/README.md in ofm-repo.tar.gz, section 'Installing without internet'."))

Step "Checksums"
$sums = @()
Get-ChildItem -Path $bundle -Recurse -File | Where-Object { $_.Name -ne "SHA256SUMS" } | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($bundle.Length + 1) -replace '\\', '/'
    $sums += ((Get-FileHash -Algorithm SHA256 -Path $_.FullName).Hash.ToLower() + "  " + $relative)
}
Write-LfFile (Join-Path $bundle "SHA256SUMS") $sums

$bytes = (Get-ChildItem -Path $bundle -Recurse -File | Measure-Object -Property Length -Sum).Sum
Step "Done"
Write-Host ("Bundle: {0}  ({1:N1} GB, {2} images)" -f $bundle, ($bytes / 1GB), $images.Count)
Write-Host "Copy the whole folder to the plant server, then follow deploy\README.md, 'Installing without internet'."
