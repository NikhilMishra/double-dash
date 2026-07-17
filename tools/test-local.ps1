# test-local.ps1 -- run BOTH sides of an online match on ONE computer, to test netplay without a
# second machine. It launches a host and a guest as two separate Dolphin instances that talk over the
# real UDP wire path on 127.0.0.1 (the same path used for true online play), each with its own user
# dir so their configs/logs don't collide. The guest binds an ephemeral port and dials the host, so
# there's no port conflict.
#
#   ./test-local.ps1                        # two windows; drive with a controller (focus a window)
#   ./test-local.ps1 -Game "D:\MKDD.rvz"    # use a specific dump
#   ./test-local.ps1 -Headless -Seconds 30  # no windows; auto-verify it connects, print RAM hashes
#
# With one controller, only the FOCUSED Dolphin window takes input (Dolphin ignores background input
# by default), so click a window to drive that kart and switch focus for the other. For real two-player
# feel, plug in a second controller (or use the keyboard for one side).

param(
  [string]$Game = "$PSScriptRoot\..\Mario Kart - Double Dash!! (USA).rvz",
  [int]$InputDelay = 1,     # low delay is fine on loopback
  [int]$Port = 7777,
  [switch]$Headless,        # Null video backend + auto-close; for a scripted connect check
  [int]$Seconds = 30        # how long to run in -Headless mode before closing
)

$ErrorActionPreference = "Stop"

$repo = Split-Path $PSScriptRoot -Parent
$exe  = Join-Path $repo "dolphin\Binary\x64\Dolphin.exe"
if (-not (Test-Path $exe))  { throw "Dolphin.exe not found at $exe -- build the fork first (Release x64)." }
if (-not (Test-Path $Game)) { throw "Game not found at $Game -- pass -Game <path to your own dump>." }

$base = Join-Path $env:LOCALAPPDATA "double-dash-rollback"

function Seed-UserDir($dir) {
  if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
  New-Item -ItemType Directory -Force -Path (Join-Path $dir "Config") | Out-Null
  Set-Content -Path (Join-Path $dir "Config\Logger.ini") -Encoding ASCII -Value @"
[Options]
Verbosity = 4
WriteToFile = True
WriteToConsole = False
WriteToWindow = False
[Logs]
MI = True
CORE = True
"@
  $dev = "XInput/0/Gamepad"
  $padBody = @"
Buttons/A = ``Button A``
Buttons/B = ``Button B``
Buttons/X = ``Button X``
Buttons/Y = ``Button Y``
Buttons/Z = ``Shoulder R``
Buttons/Start = ``Start``
Main Stick/Up = ``Left Y+``
Main Stick/Down = ``Left Y-``
Main Stick/Left = ``Left X-``
Main Stick/Right = ``Left X+``
Main Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
C-Stick/Up = ``Right Y+``
C-Stick/Down = ``Right Y-``
C-Stick/Left = ``Right X-``
C-Stick/Right = ``Right X+``
C-Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
Triggers/L = ``Trigger L``
Triggers/R = ``Trigger R``
Triggers/L-Analog = ``Trigger L``
Triggers/R-Analog = ``Trigger R``
D-Pad/Up = ``Pad N``
D-Pad/Down = ``Pad S``
D-Pad/Left = ``Pad W``
D-Pad/Right = ``Pad E``
"@
  $section = "Device = $dev`n$padBody"
  Set-Content -Path (Join-Path $dir "Config\GCPadNew.ini") -Encoding ASCII `
    -Value "[GCPad1]`n$section`n[GCPad2]`n$section`n"
}

function Dol-Args($userDir, $role, $join) {
  $a = @('-u',"`"$userDir`"",'-b',
    '-C','Dolphin.Core.CPUThread=False',
    '-C','Dolphin.Core.RollbackDriveFrames=True',
    '-C',"Dolphin.Core.RollbackInputDelay=$InputDelay",
    '-C',"Dolphin.Core.RollbackNetPort=$Port",
    '-C',"Dolphin.Core.RollbackNetRole=$role",
    '-C','Dolphin.Core.SIDevice0=6','-C','Dolphin.Core.SIDevice1=6',
    '-C','Dolphin.Core.SlotA=255','-C','Dolphin.Core.SlotB=255','-C','Dolphin.Core.SerialPort1=255')
  if ($role -eq 2) { $a += @('-C',"Dolphin.Core.RollbackNetPeer=$join") }
  if ($Headless)   { $a += @('-C','Dolphin.Video.Backend=Null') }
  $a += @('-e',"`"$Game`"")
  return $a
}

$hostDir  = Join-Path $base "local-host"
$guestDir = Join-Path $base "local-guest"
Seed-UserDir $hostDir
Seed-UserDir $guestDir

Write-Host "Starting HOST (P1) on UDP $Port ..." -ForegroundColor Cyan
$h = Start-Process $exe -PassThru -ArgumentList (Dol-Args $hostDir 1 "")
Start-Sleep -Seconds 2
Write-Host "Starting GUEST (P2) -> 127.0.0.1 ..." -ForegroundColor Cyan
$g = Start-Process $exe -PassThru -ArgumentList (Dol-Args $guestDir 2 "127.0.0.1")

if (-not $Headless) {
  Write-Host ""
  Write-Host "Two windows are launching. Focus one to drive that kart (one controller = focus-switch)." -ForegroundColor Green
  Write-Host "Logs: $hostDir\Logs\dolphin.log  and  $guestDir\Logs\dolphin.log"
  Write-Host "Close the windows when done."
  return
}

# Headless: give it time to connect + sync, then report and close.
Start-Sleep -Seconds $Seconds
foreach ($p in @($h,$g)) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {} }
Start-Sleep -Seconds 1

foreach ($pair in @(@('HOST',$hostDir),@('GUEST',$guestDir))) {
  Write-Host "`n===== $($pair[0]) LOG (key lines) ====="
  $lg = Join-Path $pair[1] "Logs\dolphin.log"
  if (Test-Path $lg) {
    Get-Content $lg | Where-Object { $_ -match 'RollbackNet|match started|RAM hash|DESYNC|fps' } |
      Select-Object -Last 12
  } else { Write-Host "(no log at $lg)" }
}
