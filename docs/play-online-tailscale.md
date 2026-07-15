# Playing Double Dash online over Tailscale

The easiest way to play across two different networks. Tailscale is a free mesh VPN that makes your
two PCs act like they're on the same LAN — so there's **no router config, no port forwarding, and no
rendezvous server**. You just connect to your friend's Tailscale IP directly.

> Over Tailscale you don't need the connect-by-code system at all — Tailscale *is* the connection.
> Use plain direct-connect (`-Host` / `-Join <ip>`).

Budget ~10–15 minutes the first time. After that, starting a game is two commands.

---

## Before you start (both players)

1. **The same Dolphin build.** Whoever built the fork zips up `dolphin\Binary\x64\` **and** the
   `tools\` folder and sends them to the other, keeping the layout:
   ```
   double-dash\
     dolphin\Binary\x64\Dolphin.exe   (+ the DLLs next to it)
     tools\play-online.cmd  play-online.ps1
   ```
   (The launcher looks for `..\dolphin\Binary\x64\Dolphin.exe` relative to itself, so keep that
   structure.)
2. **Each player has their own byte-identical MKDD dump.** Same region (USA), dumped from your own
   disc. The bytes must match exactly on both machines or the game will desync — this is a hard
   requirement of rollback. Note the path to yours; you'll pass it with `-Game`.

---

## 1. Install Tailscale (both players)

1. Download from **https://tailscale.com/download/windows** and run the installer.
2. Launch Tailscale; it opens a browser to sign in. A **free personal account** is fine (sign in with
   Google/Microsoft/GitHub/email).
3. After signing in, Tailscale is running in the system tray.

## 2. Get on the same Tailscale network

Your friend needs to be on your **tailnet** (your Tailscale network) so the two machines can see each
other. The host does this once:

1. Go to the admin console: **https://login.tailscale.com/admin/users**
2. Click **Invite external users** (or **Invite users**), and send the invite link to your friend.
3. Your friend opens the link, signs in with their own free Tailscale account, and accepts.

Now both machines are in the same tailnet. By default every device in a tailnet can reach every
other, in both directions — which is exactly what the game needs.

> Alternative: instead of inviting them into your tailnet, you can **Share** just the host machine
> (admin console → **Machines** → your machine → **Share…** → send the link). Either works; inviting
> to the tailnet is the simplest and is bidirectional by default.

## 3. Find the host's Tailscale IP

On the **host** machine, open PowerShell (or Command Prompt) and run:

```powershell
tailscale ip -4
```

It prints something like `100.101.102.103`. That `100.x.y.z` address is what your friend will connect
to. (You can also hover the Tailscale tray icon → **This device** → copy the address.)

## 4. Allow Dolphin through the firewall (first run, both players)

The first time you run Dolphin it may pop a **Windows Defender Firewall** prompt:
*"Allow Dolphin to communicate on these networks."* **Check both Private and Public, then Allow.**

If you clicked it away by accident and can't connect later: Windows Security → **Firewall & network
protection** → **Allow an app through firewall** → find/add `Dolphin.exe`, tick Private + Public.

## 5. Start the game

**Host** (this machine drives Player 1):
```powershell
tools\play-online.cmd -Host
```

**Friend** (drives Player 2 — point at the host's Tailscale IP and your own dump):
```powershell
tools\play-online.cmd -Join 100.101.102.103 -Game "D:\path\to\your\MKDD.rvz"
```

The host waits; when the friend joins you'll see a brief **"syncing…"** while the host streams its game
state, then you're racing. **Focus your own window** to drive your kart. One controller works — Alt-Tab
isn't needed here since each of you has your own machine.

## 6. Check it's actually working

- On either machine you can test the link before playing:
  ```powershell
  tailscale ping 100.101.102.103
  ```
  `pong … direct` means a clean direct connection (best). `via DERP` means it fell back to a Tailscale
  relay — still works, just a little more latency.
- The game logs to `%LOCALAPPDATA%\double-dash-rollback\online\Logs\dolphin.log`. Search it for
  `DESYNC` — it should stay **empty**. A desync almost always means the two game dumps aren't
  byte-identical, or the two builds differ.

---

## Tuning latency

The launcher defaults to `-InputDelay 3` (~50 ms) which comfortably covers a same-region ping. Check
your ping first:

```powershell
tailscale ping <friend's 100.x.y.z>
```

- Low ping (say < 30 ms): try `-InputDelay 2`, even `-InputDelay 1`, for a snappier feel. If you see
  occasional hitches, go back up a step.
- Higher ping / different regions: keep it at 3, or raise to 4. Higher delay = a bit more input lag but
  fewer rollbacks.

Both players should use the **same** `-InputDelay`.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Friend's connect just times out | Run `tailscale status` on both — each should list the other. Make sure the friend accepted the invite and is signed in. Check the Dolphin firewall allow (step 4). |
| Connects, but `DESYNC` in the log | The two MKDD dumps differ, or the two Dolphin builds differ. Re-check both are byte-identical / the same build. |
| `tailscale` command not found | Use the tray icon menu instead, or reinstall Tailscale (it adds the CLI to PATH). |
| Feels laggy | Check `tailscale ping` — if it says `via DERP`, you're on a relay; still playable. Lower `-InputDelay` only if the ping is low. |
| Works one session, not the next | The host's Tailscale IP is stable, so re-check the friend is still signed in and the invite/share is still active. |

## Notes

- **Tailscale IPs are stable**, so once set up, future games are just steps 5–6 again.
- Your friend only needs Tailscale + the accepted invite once; it persists.
- If you'd rather friends install *nothing* and just use a code, that's the port-forward +
  connect-by-code route (`rendezvous.ps1` + `-Code`), documented separately — but for two friends,
  Tailscale direct-connect is the least hassle.
