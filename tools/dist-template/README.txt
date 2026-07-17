Double Dash Online (rollback netplay build)
===========================================

A self-contained build of a Dolphin fork with rollback netcode, set up to play Mario Kart: Double
Dash!! online with a friend. Nothing to install -- just unzip and double-click.

WHAT YOU NEED
-------------
1. This folder (keep all the files together -- the launcher needs Dolphin.exe, the Sys folder, and
   the .dll files next to it).
2. YOUR OWN copy of the game: a byte-identical Mario Kart Double Dash (USA) dump (.rvz/.iso/.gcm),
   dumped from your own disc. It must match your friend's copy exactly, or the game desyncs. The
   game file is NOT included -- each player brings their own.
3. A controller (an Xbox pad works out of the box) -- OR just your keyboard: pick "Keyboard" from
   the Input dropdown in the launcher. Default keys: arrow keys steer, Z accelerate, X brake,
   Shift/Ctrl drift (L/R), Space item (Z), Enter start. (Keyboard steering is on/off rather than
   analog -- fine to play, just less smooth than a stick.)
4. Tailscale (free mesh VPN, tailscale.com). You and your friend both install it once; it puts you
   on the same private network with no router setup.

HOW TO PLAY
-----------
0. EXTRACT FIRST. Right-click the zip -> "Extract All". Then open the extracted DoubleDashOnline
   folder and run the launcher from IN there. Do NOT double-click the .exe while it's still inside
   the zip, and do NOT copy the .exe out on its own -- it needs Dolphin.exe and the Sys folder right
   beside it, or you'll get "can't find Dolphin.exe".
1. Double-click  DoubleDashOnline.exe  (inside the extracted folder)
2. Click "Browse..." and pick your own MKDD dump (it remembers it next time).
3. One of you clicks "Host"; the other clicks "Join" and pastes the host's Tailscale IP.
      - The host's window shows the exact IP to send -- just copy it to your friend.
4. Click "Play". The launcher shows live status: waiting -> syncing -> "you're in the game!"
   Each of you drives with your own controller on your own screen.

If something's off, the launcher says so in plain English (can't reach your friend, game files don't
match, etc.) -- you don't need to read any logs.

TUNING
------
"Input delay" trades felt lag for smoothness (default 3 = ~50 ms). Lower it (2, or 1) if your ping is
low; raise it (4+) if the connection is rough. Both players should use the SAME value.

TROUBLESHOOTING
---------------
- BOTH SIDES "TIME OUT" / "can't reach your friend"? Two things to check on the HOST'S machine:
    1. Firewall: run  allow-firewall.cmd  once (double-click, click Yes). This lets the host receive
       connections (inbound UDP 7777). Without it, the joiner's packets are dropped and both time out.
       (The first-launch Windows Firewall prompt does the same thing IF you allow Private AND Public --
       but allow-firewall.cmd is the reliable way.)
    2. Tailscale: you must both be on the SAME tailnet. On the host run  tailscale status  -- you should
       see your FRIEND'S machine listed, not just your own. If you don't, invite them to your tailnet
       (Tailscale admin console -> add/share), or have them log in to the same account. The joiner must
       use the host's Tailscale IP (host: run  tailscale ip -4 ). Confirm with  tailscale ping <their-ip>.
- "Game files don't match" = you and your friend have different MKDD dumps. You each need a
  byte-identical USA dump.
- Controller not moving? Click the game window so it's focused.

ADVANCED (optional -- you don't need these)
-------------------------------------------
The same thing is available from the command line if you prefer:
  Host:  play-online.cmd -Host -Game "D:\path\to\your\MKDD.rvz"
  Join:  play-online.cmd -Join <host's Tailscale IP> -Game "D:\path\to\your\MKDD.rvz"
Full setup guide (Tailscale step-by-step, connect-by-code, etc.) is with the project docs.
