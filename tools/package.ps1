# package.ps1 -- build the self-contained "DoubleDashOnline" zip you send to a friend.
#
# It bundles the runnable Dolphin build (dolphin\Binary\x64: exe + DLLs + Sys) with the portable
# launcher (tools\dist-template) so the recipient just unzips and runs -- no install, no folder
# layout to recreate. Rebuild this whenever you rebuild the fork. The zip is written to dist\ (which
# is gitignored). The game dump is never included; each player brings their own.
#
#   ./package.ps1

$ErrorActionPreference = "Stop"

$repo = Split-Path $PSScriptRoot -Parent
$binx = Join-Path $repo "dolphin\Binary\x64"
$tpl  = Join-Path $PSScriptRoot "dist-template"
$dist = Join-Path $repo "dist"
$pkg  = Join-Path $dist "DoubleDashOnline"
$zip  = Join-Path $dist "DoubleDashOnline.zip"

if (-not (Test-Path (Join-Path $binx "Dolphin.exe"))) {
  throw "Build not found at $binx -- build the fork (Release x64) first."
}

# Fresh staging.
if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
New-Item -ItemType Directory -Force -Path $pkg | Out-Null

# The runnable app (exe + Qt runtime + Sys + plugins + languages).
Copy-Item -Path (Join-Path $binx '*') -Destination $pkg -Recurse -Force

# A player doesn't need the extra command-line tools; drop them to slim the download.
foreach ($x in @('DolphinTool.exe','DSPTool.exe','Updater.exe')) {
  $p = Join-Path $pkg $x; if (Test-Path $p) { Remove-Item -Force $p }
}

# The portable launcher + readme.
Copy-Item -Path (Join-Path $tpl '*') -Destination $pkg -Force

# Zip it.
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $pkg -DestinationPath $zip -CompressionLevel Optimal

$mb = "{0:N1} MB" -f ((Get-Item $zip).Length / 1MB)
Write-Host "Built $zip ($mb)" -ForegroundColor Green
Write-Host "Send that zip to your friend. Each of you supplies your own MKDD dump."
