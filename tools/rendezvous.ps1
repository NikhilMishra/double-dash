# rendezvous.ps1 -- Double Dash connect-by-code rendezvous server.
#
# A tiny UDP server that pairs two peers by a shared code and swaps their public endpoints so they can
# hole-punch a direct connection through home NATs. Run it on a machine your friends can reach on this
# port (this PC with the UDP port forwarded, or a box with a public IP / shared Tailscale IP). Flip it
# on with this script and off with Ctrl+C -- it holds no state on disk.
#
#   ./rendezvous.ps1                 # listen on UDP 7778
#   ./rendezvous.ps1 -Port 9000      # a different port
#
# Both players point at this server + the same code:
#   host:  play-online.ps1 -Host -Code raccoon -Rendezvous <this server's IP>
#   join:  play-online.ps1       -Code raccoon -Rendezvous <this server's IP>
#
# Protocol (ASCII UDP): client -> "DDR1 REG <code> <H|G>";  server -> "DDR1 PEER <ip> <port>" once both
# roles are present. NOTE: simple hole-punching works for typical home routers (cone NAT); two
# symmetric NATs need a relay, which is a later addition.

param([int]$Port = 7778)

$ErrorActionPreference = "Stop"

$udp = New-Object System.Net.Sockets.UdpClient($Port)
$sessions = @{}   # code -> @{ H = IPEndPoint; G = IPEndPoint }

Write-Host "Double Dash rendezvous listening on UDP $Port. Ctrl+C to stop." -ForegroundColor Cyan
Write-Host "Give friends this machine's reachable IP; they connect by code."

function Send-Text($endpoint, $text) {
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($text)
  [void]$udp.Send($bytes, $bytes.Length, $endpoint)
}

try {
  while ($true) {
    $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $data = $udp.Receive([ref]$remote)   # blocks until a datagram arrives
    $msg = ([System.Text.Encoding]::ASCII.GetString($data)).Trim()
    $p = $msg -split '\s+'
    if ($p.Count -lt 4 -or $p[0] -ne 'DDR1' -or $p[1] -ne 'REG') { continue }

    $code = $p[2]
    $role = $p[3].ToUpper()
    if ($role -ne 'H' -and $role -ne 'G') { continue }

    if (-not $sessions.ContainsKey($code)) { $sessions[$code] = @{} }
    $sessions[$code][$role] = $remote
    Write-Host ("REG  code={0} role={1} from {2}:{3}" -f $code, $role, $remote.Address, $remote.Port)

    $s = $sessions[$code]
    if ($s.ContainsKey('H') -and $s.ContainsKey('G')) {
      # Both roles present: tell each peer the other's public endpoint (re-sent on every REG so a lost
      # reply is recovered by the client's next registration).
      $h = $s['H']; $g = $s['G']
      Send-Text $h ("DDR1 PEER {0} {1}" -f $g.Address, $g.Port)
      Send-Text $g ("DDR1 PEER {0} {1}" -f $h.Address, $h.Port)
      Write-Host ("PAIR code={0}: H={1}:{2} <-> G={3}:{4}" -f `
                  $code, $h.Address, $h.Port, $g.Address, $g.Port) -ForegroundColor Green
    }
  }
}
finally {
  $udp.Close()
  Write-Host "Rendezvous stopped."
}
