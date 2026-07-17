# allow-firewall.ps1 -- one-time: let Double Dash Online receive connections through Windows Firewall.
#
# The person who HOSTS needs inbound UDP 7777 allowed, or a joining friend's packets get dropped before
# they reach the game (symptom: both sides "time out / no peer"). Run this once on the machine that
# hosts. It self-elevates (Windows will ask for permission) and adds a single narrow rule.

$rule = "Double Dash Online (UDP 7777 in)"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "Asking for administrator permission to add the firewall rule..."
  Start-Process powershell -Verb RunAs -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',("`"" + $PSCommandPath + "`"")
  )
  return
}

if (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue) {
  Write-Host "Already allowed -- nothing to do." -ForegroundColor Green
} else {
  New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol UDP -LocalPort 7777 `
    -Action Allow -Profile Any | Out-Null
  Write-Host "Done. Double Dash Online can now receive connections (inbound UDP 7777)." -ForegroundColor Green
}
Read-Host "Press Enter to close"
