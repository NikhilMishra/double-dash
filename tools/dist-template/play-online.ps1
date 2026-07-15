# play-online.ps1 (portable) -- run Double Dash rollback netplay and connect to a friend.
# This folder is self-contained: Dolphin.exe and everything it needs are right here.
#
#   Direct connect (e.g. over Tailscale):
#     Host:  play-online.cmd -Host
#     Join:  play-online.cmd -Join 100.x.y.z -Game "D:\your\MKDD.rvz"
#
#   Connect-by-code (needs a rendezvous server running somewhere reachable):
#     Host:  play-online.cmd -Host -Code raccoon -Rendezvous <server IP> -Game "D:\your\MKDD.rvz"
#     Join:  play-online.cmd       -Code raccoon -Rendezvous <server IP> -Game "D:\your\MKDD.rvz"
#
# YOU MUST SUPPLY YOUR OWN MKDD DUMP with -Game. It has to be byte-identical to your opponent's
# (same USA disc, dumped yourself) or the game will desync -- that's a hard rollback requirement.
# We never share the game file; each player brings their own.

param(
  [Alias('Host')][switch]$AsHost,   # -Host: this machine hosts (drives P1) and streams the start state
  [string]$Join = "",               # direct mode: the host's IP to connect to (this machine drives P2)
  [string]$Code = "",               # connect-by-code: shared session code (both peers use the same one)
  [string]$Rendezvous = "",         # connect-by-code: the rendezvous server's IP
  [int]$RendezvousPort = 7778,
  [string]$Game = "",               # REQUIRED: path to your own MKDD dump (.rvz/.iso/.gcm)
  [int]$InputDelay = 3,             # ~50 ms; covers a same-region ping. Lower for low ping, raise for high
  [int]$Port = 7777
)

$ErrorActionPreference = "Stop"

$codeMode = -not [string]::IsNullOrEmpty($Code)
if ($codeMode) {
  if ([string]::IsNullOrEmpty($Rendezvous)) {
    throw "Connect-by-code needs -Rendezvous <server IP> (the machine running rendezvous.ps1)."
  }
}
else {
  if (-not $AsHost -and [string]::IsNullOrEmpty($Join)) {
    throw "Specify -Host, or -Join <host IP>, or -Code <code> -Rendezvous <server IP>. See the header."
  }
  if ($AsHost -and -not [string]::IsNullOrEmpty($Join)) {
    throw "Pass either -Host or -Join, not both."
  }
}

$exe = Join-Path $PSScriptRoot "Dolphin.exe"
if (-not (Test-Path $exe)) { throw "Dolphin.exe not found next to this script." }
if ([string]::IsNullOrEmpty($Game)) {
  throw "Pass your own game dump with -Game ""D:\path\to\MKDD.rvz""."
}
if (-not (Test-Path $Game)) { throw "Game not found at $Game" }

$role  = if ($AsHost) { 1 } else { 2 }
$label = if ($AsHost) { "HOST (P1)" } else { "JOIN (P2)" }

# Persistent user dir (config, controller mapping, logs) next to this app.
$userDir = Join-Path $PSScriptRoot "user"
New-Item -ItemType Directory -Force -Path (Join-Path $userDir "Config") | Out-Null

# Log the match/desync (MI) + transport connect (CORE) lines.
Set-Content -Path (Join-Path $userDir "Config\Logger.ini") -Encoding ASCII -Value @"
[Options]
Verbosity = 4
WriteToFile = True
WriteToConsole = False
WriteToWindow = False
[Logs]
MI = True
CORE = True
"@

# Controller mapping (Xbox/XInput) on both ports, so whichever side you are your pad works. Remap once
# in Controllers > Configure if your pad isn't an Xbox one (this file is rewritten each launch).
$ControllerDevice = "XInput/0/Gamepad"
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
$section = "Device = $ControllerDevice`n$padBody"
Set-Content -Path (Join-Path $userDir "Config\GCPadNew.ini") -Encoding ASCII `
  -Value "[GCPad1]`n$section`n[GCPad2]`n$section`n"

# Determinism-critical flags (must match the peer): single core, determinism-via-role, EXI empty.
$dolArgs = @(
  '-u',"`"$userDir`"",'-b',
  '-C','Dolphin.Core.CPUThread=False',
  '-C','Dolphin.Core.RollbackDriveFrames=True',
  '-C',"Dolphin.Core.RollbackInputDelay=$InputDelay",
  '-C',"Dolphin.Core.RollbackNetPort=$Port",
  '-C',"Dolphin.Core.RollbackNetRole=$role",
  '-C','Dolphin.Core.SIDevice0=6',
  '-C','Dolphin.Core.SIDevice1=6',
  '-C','Dolphin.Core.SlotA=255',
  '-C','Dolphin.Core.SlotB=255',
  '-C','Dolphin.Core.SerialPort1=255'
)
if ($codeMode) {
  $dolArgs += @('-C',"Dolphin.Core.RollbackNetCode=$Code",
                '-C',"Dolphin.Core.RollbackNetRendezvous=$Rendezvous",
                '-C',"Dolphin.Core.RollbackNetRendezvousPort=$RendezvousPort")
}
elseif (-not $AsHost) {
  $dolArgs += @('-C',"Dolphin.Core.RollbackNetPeer=$Join")
}
$dolArgs += @('-e',"`"$Game`"")

Write-Host "Starting $label on UDP $Port ..." -ForegroundColor Cyan
if ($codeMode) {
  Write-Host "Connect-by-code: code '$Code' via rendezvous $Rendezvous`:$RendezvousPort."
} elseif ($AsHost) {
  Write-Host "Waiting for your friend to join. Share your IP (Tailscale IP, or public IP if forwarded)."
} else {
  Write-Host "Connecting to host at $Join ..."
}
Write-Host "Input delay $InputDelay frames. Log: $userDir\Logs\dolphin.log (grep 'DESYNC' should stay empty)."
Start-Process -FilePath $exe -ArgumentList $dolArgs | Out-Null
