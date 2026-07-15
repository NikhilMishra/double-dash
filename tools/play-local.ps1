# play-local.ps1 -- launch two Double Dash rollback instances on this machine and put them into a
# single, byte-identical shared match. This is the "two windows, play together" path: the host
# captures its whole machine at match start, the guest adopts it, and from there both step in
# lockstep, exchanging inputs over UDP (127.0.0.1). Focus a window to drive its player -- host = P1
# (SI port 0), guest = P2 (SI port 1). One controller + Alt-Tab between windows works.
#
# Every flag below is determinism-critical: two peers only stay in sync if they step identically
# from identical state. Change them together or not at all.
#
#   Determinism mode   : forced on whenever RollbackNetRole != 0 (see Core.cpp) -- deterministic
#                        DSP/GPU/SI timing, no idle-skip, matching JIT codegen.
#   Single core        : CPUThread=False -- the deterministic-execution requirement.
#   EXI slots empty    : SlotA/SlotB/SerialPort1 = 255 (None). Different memory cards in the two user
#                        dirs would make the OS write different EXI globals and desync. (Memory-card
#                        SYNC, so saves work, is future work; for now both run card-less.)
#   State handoff      : RollbackStateSyncPath -- host writes its start state here, guest loads it.
#                        Same-machine only; cross-machine play needs the over-the-wire transfer (M3).
#
# Usage:
#   ./play-local.ps1                          # boot the repo's MKDD dump, input delay 3
#   ./play-local.ps1 -InputDelay 2            # tighter feel, less jitter cover
#   ./play-local.ps1 -Game "D:\path\to.rvz"   # a different dump

param(
  [string]$Game = "$PSScriptRoot\..\Mario Kart - Double Dash!! (USA).rvz",
  [int]$InputDelay = 3,
  [int]$Port = 7777
)

$ErrorActionPreference = "Stop"

$exe = Join-Path $PSScriptRoot "..\dolphin\Binary\x64\Dolphin.exe"
if (-not (Test-Path $exe))  { throw "Dolphin.exe not found at $exe -- build the fork first (Release x64)." }
if (-not (Test-Path $Game)) { throw "Game not found at $Game -- pass -Game <path to your own dump>." }

# Persistent per-instance user dirs (configs, controller mappings, logs) live outside the repo.
$root      = Join-Path $env:LOCALAPPDATA "double-dash-rollback"
$hostDir   = Join-Path $root "host"
$guestDir  = Join-Path $root "guest"
New-Item -ItemType Directory -Force -Path $hostDir, $guestDir | Out-Null

# Seed a Logger.ini so the rollback match + desync lines land in <user dir>\Logs\dolphin.log.
# MI = the MEMMAP category the rollback code logs under; Verbosity 4 = INFO. Grep the log for
# 'DESYNC' to confirm the two stayed in lockstep.
$loggerIni = @"
[Options]
Verbosity = 4
WriteToFile = True
WriteToConsole = False
WriteToWindow = False
[Logs]
MI = True
"@
foreach ($d in @($hostDir, $guestDir)) {
  $cfg = Join-Path $d "Config"
  New-Item -ItemType Directory -Force -Path $cfg | Out-Null
  Set-Content -Path (Join-Path $cfg "Logger.ini") -Value $loggerIni -Encoding ASCII
}

# Shared start-state file (host -> guest). Clear any stale copy so the guest waits for a fresh one.
$syncPath = Join-Path $env:TEMP "dd-rollback-startstate.bin"
foreach ($p in @($syncPath, "$syncPath.tmp")) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }

$common = @(
  '-b',
  '-C','Dolphin.Core.CPUThread=False',
  '-C','Dolphin.Core.RollbackDriveFrames=True',
  '-C',"Dolphin.Core.RollbackInputDelay=$InputDelay",
  '-C',"Dolphin.Core.RollbackNetPort=$Port",
  '-C','Dolphin.Core.SIDevice0=6',            # standard GC controller, port 0
  '-C','Dolphin.Core.SIDevice1=6',            # standard GC controller, port 1
  '-C','Dolphin.Core.SlotA=255',              # EXI None -- no memory card (determinism)
  '-C','Dolphin.Core.SlotB=255',
  '-C','Dolphin.Core.SerialPort1=255',
  '-C',"Dolphin.Core.RollbackStateSyncPath=$syncPath"
)

$hostArgs  = @('-u',"`"$hostDir`"")  + $common + @('-C','Dolphin.Core.RollbackNetRole=1','-e',"`"$Game`"")
$guestArgs = @('-u',"`"$guestDir`"") + $common + @('-C','Dolphin.Core.RollbackNetRole=2',
                                                   '-C','Dolphin.Core.RollbackNetPeer=127.0.0.1',
                                                   '-e',"`"$Game`"")

Write-Host "Launching HOST (P1)..."  -ForegroundColor Cyan
$h = Start-Process -FilePath $exe -ArgumentList $hostArgs -PassThru
Start-Sleep -Seconds 3   # let the host bind the port and reach its match start before the guest connects
Write-Host "Launching GUEST (P2)..." -ForegroundColor Cyan
$g = Start-Process -FilePath $exe -ArgumentList $guestArgs -PassThru

Write-Host ""
Write-Host "Host  PID $($h.Id)  (P1, SI port 0)  user dir: $hostDir"
Write-Host "Guest PID $($g.Id)  (P2, SI port 1)  user dir: $guestDir"
Write-Host ""
Write-Host "Focus a window to drive its player. Input delay $InputDelay frame(s); rollback covers jitter."
Write-Host "Logs: <user dir>\Logs\dolphin.log -- grep 'DESYNC' should stay empty."
