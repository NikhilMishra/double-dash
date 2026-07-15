# play-online.ps1 -- run ONE Double Dash rollback instance and connect to a friend over the network.
# One of you hosts, the other joins the host's IP:
#
#   Host machine:  ./play-online.ps1 -Host
#   Join machine:  ./play-online.ps1 -Join 100.x.y.z        (the host's IP)
#
# At match start the host streams its exact game state to the joiner (compressed, over the same UDP
# socket) so both begin byte-identical; from there it's the same lockstep + rollback as local play.
#
# BEFORE YOU START, both machines need:
#   1. The SAME build of this fork (same Dolphin.exe).
#   2. A byte-identical MKDD dump. Each person dumps their own disc; the bytes must match exactly, or
#      the two will desync (it's a hard determinism requirement). Pass yours with -Game if it's not
#      the repo copy.
#   3. A path from the joiner to the host on the chosen UDP port. Easiest: both install Tailscale
#      (free mesh VPN, no router config) and the joiner uses the host's Tailscale IP. Otherwise the
#      host must port-forward the UDP port on their router and share their public IP.
#
# Connectivity note: the HOST must be reachable; the joiner reaches out and the host learns the
# joiner's address from that first packet. Symmetric-NAT hole-punching / connect-by-code is a later
# milestone -- for now use Tailscale or a forwarded port.

param(
  [Alias('Host')][switch]$AsHost,   # -Host: this machine hosts (drives P1) and streams the start state
  [string]$Join = "",               # the host's IP to connect to (this machine drives P2)
  [string]$Game = "$PSScriptRoot\..\Mario Kart - Double Dash!! (USA).rvz",
  [int]$InputDelay = 3,             # ~50 ms; covers a same-region ping. Lower for low ping, raise for high
  [int]$Port = 7777
)

$ErrorActionPreference = "Stop"

if (-not $AsHost -and [string]::IsNullOrEmpty($Join)) {
  throw "Specify a role: -Host  (to host), or  -Join <host IP>  (to join). See the header for setup."
}
if ($AsHost -and -not [string]::IsNullOrEmpty($Join)) {
  throw "Pass either -Host or -Join, not both."
}

$exe = Join-Path $PSScriptRoot "..\dolphin\Binary\x64\Dolphin.exe"
if (-not (Test-Path $exe))  { throw "Dolphin.exe not found at $exe -- build the fork first (Release x64)." }
if (-not (Test-Path $Game)) { throw "Game not found at $Game -- pass -Game <path to your own dump>." }

$role  = if ($AsHost) { 1 } else { 2 }
$label = if ($AsHost) { "HOST (P1)" } else { "JOIN (P2)" }

# One persistent user dir for online play (config, controller mapping, logs), outside the repo.
$userDir = Join-Path $env:LOCALAPPDATA "double-dash-rollback\online"
New-Item -ItemType Directory -Force -Path (Join-Path $userDir "Config") | Out-Null

# Log to <user dir>\Logs\dolphin.log. MI = the rollback match/desync lines; CORE = the transport
# (handshake, "CONNECTED", the start-state transfer + its progress) -- the things you watch to see an
# online connection come up.
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

# Controller mapping (Xbox/XInput). Map to BOTH ports so it works whichever side you are: the host
# polls port 0, the joiner polls port 1, and this covers either. Remap once in Controllers > Configure
# if your pad is not an Xbox one (note: this file is rewritten each launch).
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

# Determinism-critical flags (must match the peer): single core, determinism-via-role, EXI slots
# empty. No RollbackStateSyncPath -> the start state is streamed over the wire, not a shared file.
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
if (-not $AsHost) { $dolArgs += @('-C',"Dolphin.Core.RollbackNetPeer=$Join") }
$dolArgs += @('-e',"`"$Game`"")

Write-Host "Starting $label on UDP $Port ..." -ForegroundColor Cyan
if ($AsHost) {
  Write-Host "Waiting for your friend to join. Share your IP (Tailscale IP, or public IP if port-forwarded)."
} else {
  Write-Host "Connecting to host at $Join ..."
}
Write-Host "Input delay $InputDelay frames. Log: $userDir\Logs\dolphin.log (grep 'DESYNC' should stay empty)."
Start-Process -FilePath $exe -ArgumentList $dolArgs | Out-Null
