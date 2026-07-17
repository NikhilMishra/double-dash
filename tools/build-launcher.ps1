# build-launcher.ps1 -- compile the double-click GUI launcher (DoubleDashOnline.exe).
#
# Uses the C# compiler that ships in-box with Windows (.NET Framework), so there's nothing to install.
# Output goes next to Dolphin.exe in the build folder, where package.ps1 picks it up.
#
#   ./build-launcher.ps1

$ErrorActionPreference = "Stop"

$repo = Split-Path $PSScriptRoot -Parent
$src  = Join-Path $PSScriptRoot "launcher\DoubleDashOnline.cs"
$out  = Join-Path $repo "dolphin\Binary\x64\DoubleDashOnline.exe"

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "C# compiler not found at $csc (.NET Framework 4.x is required)." }
if (-not (Test-Path $src)) { throw "Launcher source not found at $src." }

& $csc /nologo /target:winexe /optimize+ `
  "/out:$out" `
  /reference:System.Windows.Forms.dll `
  /reference:System.Drawing.dll `
  $src

if ($LASTEXITCODE -ne 0) { throw "Compilation failed (csc exit $LASTEXITCODE)." }
Write-Host "Built $out" -ForegroundColor Green
