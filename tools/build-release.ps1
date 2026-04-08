param(
  [string]$AddonDir = "MDT_QoL",
  [string]$OutDir = "release",
  [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$addonPath = Join-Path $repoRoot $AddonDir
$tocPath = Join-Path $addonPath "$AddonDir.toc"

if (-not (Test-Path $addonPath)) {
  throw "Addon directory not found: $addonPath"
}

if (-not (Test-Path $tocPath)) {
  throw "TOC file not found: $tocPath"
}

if (-not $Version) {
  $tocContent = Get-Content $tocPath
  $versionLine = $tocContent | Where-Object { $_ -match '^##\s*Version:\s*(.+)$' } | Select-Object -First 1
  if (-not $versionLine) {
    throw "Could not find ## Version in $tocPath"
  }
  $Version = ([regex]::Match($versionLine, '^##\s*Version:\s*(.+)$')).Groups[1].Value.Trim()
}

$stagingRoot = Join-Path $repoRoot "_staging"
$stagingAddonPath = Join-Path $stagingRoot $AddonDir
$outPath = Join-Path $repoRoot $OutDir
$zipPath = Join-Path $outPath ("{0}-{1}.zip" -f $AddonDir, $Version)

if (Test-Path $stagingRoot) {
  Remove-Item -Path $stagingRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stagingAddonPath -Force | Out-Null
New-Item -ItemType Directory -Path $outPath -Force | Out-Null

Copy-Item -Path (Join-Path $addonPath "*") -Destination $stagingAddonPath -Recurse -Force

if (Test-Path $zipPath) {
  Remove-Item -Path $zipPath -Force
}

Compress-Archive -Path $stagingAddonPath -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item -Path $stagingRoot -Recurse -Force

Write-Host "Release package created: $zipPath"
