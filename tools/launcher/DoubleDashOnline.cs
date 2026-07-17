// DoubleDashOnline.cs -- a tiny double-click GUI launcher for the Double Dash rollback build.
//
// It wraps the existing Dolphin.exe: the player picks their own MKDD dump once, chooses Host or Join,
// and clicks Play. The launcher writes the same determinism-critical config the scripts use, launches
// Dolphin, and then TAILS the game log to show plain-English connection status on screen -- so the
// "nothing seems to happen" black box is gone. No command line, no installs (compiles with the C#
// compiler that ships in-box with Windows; see tools/build-launcher.ps1).
//
// It lives next to Dolphin.exe. The game file is never bundled; each player supplies their own.

using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace DoubleDashOnline
{
  public class MainForm : Form
  {
    private TextBox _gameBox;
    private Button _browseBtn;
    private RadioButton _hostRadio;
    private RadioButton _joinRadio;
    private Label _joinLabel;
    private TextBox _joinBox;
    private NumericUpDown _delayBox;
    private Button _playBtn;
    private Button _stopBtn;
    private Label _statusLabel;
    private TextBox _detailBox;
    private System.Windows.Forms.Timer _timer;

    private readonly string _exeDir;
    private readonly string _userDir;
    private readonly string _logPath;
    private readonly string _cfgPath;
    private readonly string _dolphinPath;
    private long _logPos;
    private Process _dolphin;
    private bool _inGame;

    public MainForm()
    {
      _exeDir = AppDomain.CurrentDomain.BaseDirectory;
      _userDir = Path.Combine(_exeDir, "user");
      _logPath = Path.Combine(_userDir, "Logs\\dolphin.log");
      _cfgPath = Path.Combine(_userDir, "launcher.cfg");
      _dolphinPath = Path.Combine(_exeDir, "Dolphin.exe");

      BuildUi();
      LoadConfig();
      UpdateJoinEnabled();
    }

    private void BuildUi()
    {
      Text = "Double Dash Online";
      FormBorderStyle = FormBorderStyle.FixedSingle;
      MaximizeBox = false;
      StartPosition = FormStartPosition.CenterScreen;
      ClientSize = new Size(460, 430);
      Font = new Font("Segoe UI", 9f);

      int x = 16, w = 428, y = 14;

      Label l1 = new Label();
      l1.Text = "1.  Your game file  (your own Mario Kart: Double Dash dump)";
      l1.SetBounds(x, y, w, 18);
      Controls.Add(l1);
      y += 22;

      _gameBox = new TextBox();
      _gameBox.SetBounds(x, y, w - 90, 24);
      _gameBox.ReadOnly = true;
      Controls.Add(_gameBox);

      _browseBtn = new Button();
      _browseBtn.Text = "Browse...";
      _browseBtn.SetBounds(x + w - 82, y - 1, 82, 26);
      _browseBtn.Click += OnBrowse;
      Controls.Add(_browseBtn);
      y += 40;

      Label l2 = new Label();
      l2.Text = "2.  Play with a friend";
      l2.SetBounds(x, y, w, 18);
      Controls.Add(l2);
      y += 22;

      _hostRadio = new RadioButton();
      _hostRadio.Text = "Host  (your friend joins you)";
      _hostRadio.SetBounds(x + 8, y, w - 8, 22);
      _hostRadio.Checked = true;
      _hostRadio.CheckedChanged += OnModeChanged;
      Controls.Add(_hostRadio);
      y += 26;

      _joinRadio = new RadioButton();
      _joinRadio.Text = "Join  (connect to your friend)";
      _joinRadio.SetBounds(x + 8, y, w - 8, 22);
      _joinRadio.CheckedChanged += OnModeChanged;
      Controls.Add(_joinRadio);
      y += 30;

      _joinLabel = new Label();
      _joinLabel.Text = "Friend's Tailscale IP:";
      _joinLabel.SetBounds(x + 28, y + 3, 130, 18);
      Controls.Add(_joinLabel);

      _joinBox = new TextBox();
      _joinBox.SetBounds(x + 160, y, w - 160, 24);
      Controls.Add(_joinBox);
      y += 38;

      Label l3 = new Label();
      l3.Text = "Input delay (raise if the connection is rough):";
      l3.SetBounds(x, y + 3, 280, 18);
      Controls.Add(l3);

      _delayBox = new NumericUpDown();
      _delayBox.Minimum = 1;
      _delayBox.Maximum = 6;
      _delayBox.Value = 3;
      _delayBox.SetBounds(x + 290, y, 60, 24);
      Controls.Add(_delayBox);
      y += 38;

      _playBtn = new Button();
      _playBtn.Text = "Play";
      _playBtn.SetBounds(x, y, 200, 34);
      _playBtn.Click += OnPlay;
      Controls.Add(_playBtn);

      _stopBtn = new Button();
      _stopBtn.Text = "Stop";
      _stopBtn.SetBounds(x + 228, y, 200, 34);
      _stopBtn.Enabled = false;
      _stopBtn.Click += OnStop;
      Controls.Add(_stopBtn);
      y += 44;

      _statusLabel = new Label();
      _statusLabel.SetBounds(x, y, w, 40);
      _statusLabel.Text = "Pick your game file, choose Host or Join, then click Play.";
      Controls.Add(_statusLabel);
      y += 46;

      _detailBox = new TextBox();
      _detailBox.SetBounds(x, y, w, 100);
      _detailBox.Multiline = true;
      _detailBox.ReadOnly = true;
      _detailBox.ScrollBars = ScrollBars.Vertical;
      _detailBox.BackColor = Color.FromArgb(245, 245, 245);
      _detailBox.Font = new Font("Consolas", 8f);
      Controls.Add(_detailBox);

      _timer = new System.Windows.Forms.Timer();
      _timer.Interval = 300;
      _timer.Tick += OnTimer;

      FormClosing += delegate { KillDolphin(); };
    }

    private void OnModeChanged(object sender, EventArgs e)
    {
      UpdateJoinEnabled();
      if (_hostRadio.Checked)
      {
        string ip = GetTailscaleIp();
        if (ip.Length > 0)
          SetStatus("You're the host. Send your friend this address to Join:\r\n    " + ip);
        else
          SetStatus("You're the host. Your friend joins with your Tailscale IP " +
                    "(install Tailscale, then run: tailscale ip -4).");
      }
      else
      {
        SetStatus("Paste your friend's Tailscale IP above, then click Play.");
      }
    }

    private void UpdateJoinEnabled()
    {
      bool join = _joinRadio.Checked;
      _joinLabel.Enabled = join;
      _joinBox.Enabled = join;
    }

    private void OnBrowse(object sender, EventArgs e)
    {
      OpenFileDialog dlg = new OpenFileDialog();
      dlg.Title = "Select your Mario Kart: Double Dash dump";
      dlg.Filter = "GameCube images (*.rvz;*.iso;*.gcm;*.ciso)|*.rvz;*.iso;*.gcm;*.ciso|All files (*.*)|*.*";
      if (dlg.ShowDialog(this) == DialogResult.OK)
        _gameBox.Text = dlg.FileName;
    }

    private void OnPlay(object sender, EventArgs e)
    {
      if (!File.Exists(_dolphinPath))
      {
        SetStatus("Dolphin.exe isn't next to this launcher. Keep all the files together.");
        return;
      }
      string game = _gameBox.Text.Trim();
      if (game.Length == 0 || !File.Exists(game))
      {
        SetStatus("Pick your game file first (your own MKDD dump).");
        return;
      }
      bool host = _hostRadio.Checked;
      string peer = _joinBox.Text.Trim();
      if (!host && peer.Length == 0)
      {
        SetStatus("Enter your friend's Tailscale IP to Join.");
        return;
      }

      try
      {
        WriteConfigFiles();
        SaveConfig();
      }
      catch (Exception ex)
      {
        SetStatus("Couldn't write settings: " + ex.Message);
        return;
      }

      // Start the log fresh so status reflects THIS session only.
      try { if (File.Exists(_logPath)) File.Delete(_logPath); }
      catch { /* Dolphin will recreate it */ }
      _logPos = 0;
      _detailBox.Clear();
      _inGame = false;

      ProcessStartInfo psi = new ProcessStartInfo();
      psi.FileName = _dolphinPath;
      psi.Arguments = BuildArgs(game, host, peer);
      psi.WorkingDirectory = _exeDir;
      psi.UseShellExecute = false;

      try
      {
        _dolphin = Process.Start(psi);
      }
      catch (Exception ex)
      {
        SetStatus("Couldn't start the game: " + ex.Message);
        return;
      }

      _playBtn.Enabled = false;
      _stopBtn.Enabled = true;
      _browseBtn.Enabled = false;
      _hostRadio.Enabled = _joinRadio.Enabled = _joinBox.Enabled = _delayBox.Enabled = false;

      if (host)
      {
        string ip = GetTailscaleIp();
        SetStatus(ip.Length > 0
          ? "Hosting. Waiting for your friend to join you at:\r\n    " + ip
          : "Hosting. Waiting for your friend to join (share your Tailscale IP).");
      }
      else
      {
        SetStatus("Connecting to your friend at " + peer + " ...");
      }
      _timer.Start();
    }

    private void OnStop(object sender, EventArgs e)
    {
      KillDolphin();
      SetStatus("Stopped.");
    }

    private void OnTimer(object sender, EventArgs e)
    {
      if (_dolphin != null && _dolphin.HasExited)
      {
        _timer.Stop();
        _playBtn.Enabled = true;
        _stopBtn.Enabled = false;
        _browseBtn.Enabled = true;
        _hostRadio.Enabled = _joinRadio.Enabled = _delayBox.Enabled = true;
        UpdateJoinEnabled();
        if (!_inGame)
          SetStatus("The game closed before connecting. Make sure your friend started too, " +
                    "and that the IP is right.");
        _dolphin = null;
        return;
      }
      PumpLog();
    }

    private void PumpLog()
    {
      if (!File.Exists(_logPath))
        return;
      try
      {
        using (FileStream fs = new FileStream(_logPath, FileMode.Open, FileAccess.Read,
                                              FileShare.ReadWrite))
        {
          if (fs.Length < _logPos)
            _logPos = 0;  // file was rotated/recreated
          fs.Seek(_logPos, SeekOrigin.Begin);
          using (StreamReader sr = new StreamReader(fs))
          {
            string chunk = sr.ReadToEnd();
            _logPos = fs.Length;
            if (chunk.Length > 0)
              foreach (string line in chunk.Split('\n'))
                Interpret(line);
          }
        }
      }
      catch { /* transient sharing violation; try again next tick */ }
    }

    // Translate the game's own log lines into plain-English status. Substrings come from
    // RollbackNet.cpp / RollbackManager.cpp.
    private void Interpret(string line)
    {
      if (line.IndexOf("DESYNC", StringComparison.Ordinal) >= 0)
      {
        SetStatus("Your game files don't match your friend's. You each need a byte-identical " +
                  "MKDD dump (same USA disc).");
        return;
      }
      if (line.IndexOf("registering code", StringComparison.Ordinal) >= 0)
        SetStatus("Waiting for your friend to connect...");
      else if (line.IndexOf("rendezvous paired", StringComparison.Ordinal) >= 0)
        SetStatus("Found your friend. Connecting...");
      else if (line.IndexOf("CONNECTED as", StringComparison.Ordinal) >= 0)
        SetStatus("Connected. Syncing the game so you both start identical...");
      else if (line.IndexOf("sending start state", StringComparison.Ordinal) >= 0 ||
               line.IndexOf("receiving start state", StringComparison.Ordinal) >= 0)
        SetStatus("Syncing the game so you both start identical...");
      else if (line.IndexOf("start-state", StringComparison.Ordinal) >= 0 &&
               line.IndexOf("chunks", StringComparison.Ordinal) >= 0)
      {
        Match m = Regex.Match(line, @"(\d+)/(\d+)\s+chunks");
        if (m.Success)
        {
          double a = double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
          double b = double.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
          int pct = b > 0 ? (int)(100.0 * a / b) : 0;
          SetStatus("Syncing the game... " + pct + "%");
        }
      }
      else if (line.IndexOf("match started", StringComparison.Ordinal) >= 0)
      {
        _inGame = true;
        SetStatus("Connected -- you're in the game. Have fun!");
      }
      else if (line.IndexOf("no peer; falling back", StringComparison.Ordinal) >= 0)
        SetStatus("Couldn't reach your friend. Check they clicked Play too, and that the IP is right.");
      else if (line.IndexOf("transport failed to start", StringComparison.Ordinal) >= 0)
        SetStatus("Network port is busy -- is another copy already running?");

      string t = line.Trim();
      if (t.Length > 0 && t.IndexOf("RollbackNet", StringComparison.Ordinal) >= 0)
        AppendDetail(t);
    }

    private string BuildArgs(string game, bool host, string peer)
    {
      StringBuilder sb = new StringBuilder();
      sb.Append("-u \"").Append(_userDir).Append("\" -b");
      Add(sb, "Dolphin.Core.CPUThread=False");
      Add(sb, "Dolphin.Core.RollbackDriveFrames=True");
      Add(sb, "Dolphin.Core.RollbackInputDelay=" + ((int)_delayBox.Value));
      Add(sb, "Dolphin.Core.RollbackNetPort=7777");
      Add(sb, "Dolphin.Core.RollbackNetRole=" + (host ? "1" : "2"));
      Add(sb, "Dolphin.Core.SIDevice0=6");
      Add(sb, "Dolphin.Core.SIDevice1=6");
      Add(sb, "Dolphin.Core.SlotA=255");
      Add(sb, "Dolphin.Core.SlotB=255");
      Add(sb, "Dolphin.Core.SerialPort1=255");
      if (!host)
        Add(sb, "Dolphin.Core.RollbackNetPeer=" + peer);
      sb.Append(" -e \"").Append(game).Append("\"");
      return sb.ToString();
    }

    private static void Add(StringBuilder sb, string kv)
    {
      sb.Append(" -C ").Append(kv);
    }

    private void WriteConfigFiles()
    {
      string cfg = Path.Combine(_userDir, "Config");
      Directory.CreateDirectory(cfg);

      File.WriteAllText(Path.Combine(cfg, "Logger.ini"),
        "[Options]\r\nVerbosity = 4\r\nWriteToFile = True\r\nWriteToConsole = False\r\n" +
        "WriteToWindow = False\r\n[Logs]\r\nMI = True\r\nCORE = True\r\n", Encoding.ASCII);

      string dev = "XInput/0/Gamepad";
      string body =
        "Buttons/A = `Button A`\r\nButtons/B = `Button B`\r\nButtons/X = `Button X`\r\n" +
        "Buttons/Y = `Button Y`\r\nButtons/Z = `Shoulder R`\r\nButtons/Start = `Start`\r\n" +
        "Main Stick/Up = `Left Y+`\r\nMain Stick/Down = `Left Y-`\r\nMain Stick/Left = `Left X-`\r\n" +
        "Main Stick/Right = `Left X+`\r\n" +
        "Main Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42\r\n" +
        "C-Stick/Up = `Right Y+`\r\nC-Stick/Down = `Right Y-`\r\nC-Stick/Left = `Right X-`\r\n" +
        "C-Stick/Right = `Right X+`\r\n" +
        "C-Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42\r\n" +
        "Triggers/L = `Trigger L`\r\nTriggers/R = `Trigger R`\r\n" +
        "Triggers/L-Analog = `Trigger L`\r\nTriggers/R-Analog = `Trigger R`\r\n" +
        "D-Pad/Up = `Pad N`\r\nD-Pad/Down = `Pad S`\r\nD-Pad/Left = `Pad W`\r\nD-Pad/Right = `Pad E`\r\n";
      string section = "Device = " + dev + "\r\n" + body;
      File.WriteAllText(Path.Combine(cfg, "GCPadNew.ini"),
        "[GCPad1]\r\n" + section + "[GCPad2]\r\n" + section, Encoding.ASCII);
    }

    private string GetTailscaleIp()
    {
      string[] candidates = new string[] {
        "C:\\Program Files\\Tailscale\\tailscale.exe",
        "C:\\Program Files (x86)\\Tailscale\\tailscale.exe",
        "tailscale"
      };
      foreach (string exe in candidates)
      {
        try
        {
          ProcessStartInfo psi = new ProcessStartInfo(exe, "ip -4");
          psi.UseShellExecute = false;
          psi.RedirectStandardOutput = true;
          psi.CreateNoWindow = true;
          Process p = Process.Start(psi);
          string outp = p.StandardOutput.ReadToEnd();
          p.WaitForExit(3000);
          foreach (string line in outp.Split('\n'))
          {
            string ip = line.Trim();
            if (ip.Length > 0)
              return ip;
          }
        }
        catch { /* try next candidate */ }
      }
      return "";
    }

    private void SetStatus(string s)
    {
      _statusLabel.Text = s;
    }

    private void AppendDetail(string s)
    {
      if (_detailBox.TextLength > 6000)
        _detailBox.Clear();
      _detailBox.AppendText(s + "\r\n");
    }

    private void KillDolphin()
    {
      _timer.Stop();
      try
      {
        if (_dolphin != null && !_dolphin.HasExited)
          _dolphin.Kill();
      }
      catch { }
      _dolphin = null;
      _playBtn.Enabled = true;
      _stopBtn.Enabled = false;
      _browseBtn.Enabled = true;
      _hostRadio.Enabled = _joinRadio.Enabled = _delayBox.Enabled = true;
      UpdateJoinEnabled();
    }

    private void LoadConfig()
    {
      try
      {
        if (!File.Exists(_cfgPath))
          return;
        foreach (string line in File.ReadAllLines(_cfgPath))
        {
          int eq = line.IndexOf('=');
          if (eq <= 0)
            continue;
          string k = line.Substring(0, eq).Trim();
          string v = line.Substring(eq + 1).Trim();
          if (k == "game")
            _gameBox.Text = v;
          else if (k == "delay")
          {
            int d;
            if (int.TryParse(v, out d) && d >= 1 && d <= 6)
              _delayBox.Value = d;
          }
          else if (k == "join")
            _joinBox.Text = v;
          else if (k == "mode" && v == "join")
            _joinRadio.Checked = true;
        }
      }
      catch { }
    }

    private void SaveConfig()
    {
      Directory.CreateDirectory(_userDir);
      StringBuilder sb = new StringBuilder();
      sb.Append("game=").Append(_gameBox.Text.Trim()).Append("\r\n");
      sb.Append("delay=").Append((int)_delayBox.Value).Append("\r\n");
      sb.Append("join=").Append(_joinBox.Text.Trim()).Append("\r\n");
      sb.Append("mode=").Append(_hostRadio.Checked ? "host" : "join").Append("\r\n");
      File.WriteAllText(_cfgPath, sb.ToString(), Encoding.ASCII);
    }
  }

  internal static class Program
  {
    [STAThread]
    private static void Main()
    {
      Application.EnableVisualStyles();
      Application.SetCompatibleTextRenderingDefault(false);
      Application.Run(new MainForm());
    }
  }
}
