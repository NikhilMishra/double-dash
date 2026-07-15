Double Dash Online (rollback netplay build)
===========================================

This folder is a self-contained build of a Dolphin fork with rollback netcode, set up to play
Mario Kart: Double Dash!! online with a friend. Nothing to install -- just unzip and run.

WHAT YOU NEED
-------------
1. This folder (keep all the files together -- Dolphin.exe needs the Sys folder and the .dll files
   next to it).
2. YOUR OWN copy of the game: a byte-identical Mario Kart Double Dash (USA) dump (.rvz/.iso/.gcm),
   dumped from your own disc. It must match your opponent's copy exactly, or the game desyncs. The
   game file is NOT included -- each player brings their own.
3. A controller (Xbox pad works out of the box; others: launch once, then Controllers > Configure).

HOW TO PLAY (over Tailscale -- easiest)
---------------------------------------
You and your friend both install Tailscale (free, tailscale.com) and end up on the same network.
Then:

  The host runs:      play-online.cmd -Host -Game "D:\path\to\your\MKDD.rvz"
  The joiner runs:    play-online.cmd -Join <host's Tailscale IP> -Game "D:\path\to\your\MKDD.rvz"

The host waits; when you join, you'll see a brief "syncing..." while the host sends the starting game
state, then you're racing. Each of you drives with your own controller on your own screen.

  (Host's Tailscale IP: run  tailscale ip -4  on the host machine.)

TUNING
------
-InputDelay controls felt lag vs. smoothness (default 3 = ~50 ms). Lower it (2, or 1) if your ping is
low; raise it (4) if the connection is rough. Both players should use the SAME value.

TROUBLESHOOTING
---------------
- First launch may pop a Windows Firewall prompt -- allow it (Private AND Public).
- If it connects but you see problems, check user\Logs\dolphin.log for "DESYNC". A desync means the
  two game dumps (or builds) aren't identical.
- Controller not moving? Make sure the game window is focused.

Full setup guide (Tailscale step-by-step, connect-by-code, etc.) is with the project docs.
