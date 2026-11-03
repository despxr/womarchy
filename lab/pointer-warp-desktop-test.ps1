# Real Windows/Hyprland integration test. Only runs against an omarchy-test* distro.
# Temporarily moves the mouse/focus; restores both and closes only its own viewer in finally.
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [string]$Distro = "omarchy-test-pointer",
  [string]$User = "omarchy",
  [switch]$Fullscreen,
  [string]$OutDir = (Join-Path $env:TEMP "womarchy-pointer-validation")
)
$ErrorActionPreference = "Stop"
if ($Distro -notlike "omarchy-test*") { throw "Use a throwaway omarchy-test* distro, never the everyday desktop" }
. "$PSScriptRoot\assert-desktop.ps1"
New-Item -ItemType Directory -Force $OutDir | Out-Null
Add-Type -AssemblyName System.Windows.Forms
$expectedOutputs = 2
if ($Fullscreen) { $expectedOutputs = [Math]::Min(2, [Windows.Forms.Screen]::AllScreens.Count) }
$singleOutput = $expectedOutputs -eq 1
Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class WarpDesktopNative {
  [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder text, int size);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder text, int size);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref Point p);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [StructLayout(LayoutKind.Explicit, Size=40)] public struct Input {
    [FieldOffset(0)] public uint Type;
    [FieldOffset(10)] public ushort Scan;
    [FieldOffset(12)] public uint Flags;
  }
  [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint count, Input[] inputs, int size);
  public static void WorkspaceKey(int workspace) {
    var inputs = new Input[4];
    inputs[0] = new Input { Type = 1, Scan = 0x5b, Flags = 9 }; // scan + extended
    inputs[1] = new Input { Type = 1, Scan = (ushort)(workspace + 1), Flags = 8 };
    inputs[2] = new Input { Type = 1, Scan = (ushort)(workspace + 1), Flags = 10 }; // scan + up
    inputs[3] = new Input { Type = 1, Scan = 0x5b, Flags = 11 }; // scan + extended + up
    if (SendInput(4, inputs, Marshal.SizeOf(typeof(Input))) != 4) throw new Exception("SendInput did not inject the complete chord");
  }
  public static Point Cursor() { Point p; if (!GetCursorPos(out p)) throw new Exception("GetCursorPos failed"); return p; }
  public static Point Origin(IntPtr h) { Point p = new Point(); if (!ClientToScreen(h, ref p)) throw new Exception("ClientToScreen failed"); return p; }
  public static Dictionary<int, IntPtr> Windows(int process) {
    var found = new Dictionary<int, IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr unused) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != process) return true;
      var cls = new StringBuilder(64); GetClassName(h, cls, cls.Capacity);
      if (cls.ToString() != "OmarchyViewer") return true;
      var title = new StringBuilder(128); GetWindowText(h, title, title.Capacity);
      int start = title.ToString().LastIndexOf("WSL-"); int id;
      if (start >= 0 && Int32.TryParse(title.ToString().Substring(start + 4), out id)) found[id] = h;
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
'@
$oldDpi = [WarpDesktopNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
$oldFocus = [WarpDesktopNative]::GetForegroundWindow()
$oldPointer = [WarpDesktopNative]::Cursor()
$results = New-Object 'System.Collections.Generic.List[object]'
$viewer = $null
$viewerHandle = [IntPtr]::Zero
$form = $null
$failure = $null
$windows = $null
# Avoid quoting a shell fragment at every call, and export only the two needed session variables.
$envScript = Join-Path $OutDir "test-env.sh"
[IO.File]::WriteAllText($envScript, @'
#!/usr/bin/env bash
set -euo pipefail
vars=$(systemctl --user show-environment)
export HYPRLAND_INSTANCE_SIGNATURE=$(printf '%s\n' "$vars" | awk -F= '$1 == "HYPRLAND_INSTANCE_SIGNATURE" { print $2 }')
export WAYLAND_DISPLAY=$(printf '%s\n' "$vars" | awk -F= '$1 == "WAYLAND_DISPLAY" { print $2 }')
[[ -n $HYPRLAND_INSTANCE_SIGNATURE ]] || exit 64
exec "$@"
'@.Replace("`r", "") + "`n", (New-Object Text.UTF8Encoding($false)))
$resolved = (Resolve-Path $envScript).Path
if ($resolved -notmatch '^([A-Za-z]):\\') { throw "OutDir must be on a Windows drive mounted by WSL" }
$linuxEnv = "/mnt/" + $Matches[1].ToLower() + ($resolved.Substring(2) -replace '\\', '/')
function Invoke-TestLinux([string[]]$Arguments) {
  $text = @(& wsl.exe -d $Distro -u $User --exec bash $linuxEnv @Arguments) -join "`n"
  if ($LASTEXITCODE) { throw "test command failed ($LASTEXITCODE): $($Arguments -join ' '): $text" }
  return $text
}
function Lua-String([string]$Value) {
  # Single quotes survive Windows PowerShell 5.1's native argv handling.
  "'" + $Value.Replace('\', '\\').Replace("'", "\'") + "'"
}
function Invoke-Hypr([string[]]$Arguments) {
  # The real Omarchy session uses Lua, not the lab's legacy .conf dispatch syntax.
  $expression = $null
  if ($Arguments[0] -eq 'dispatch') {
    switch ($Arguments[1]) {
      'workspace' { $expression = "hl.dispatch(hl.dsp.focus({workspace=$([int]$Arguments[2])}))" }
      'moveworkspacetomonitor' {
        $parts = $Arguments[2].Split(' ')
        $monitor = Lua-String $parts[1]
        $expression = "hl.dispatch(hl.dsp.workspace.move({workspace=$([int]$parts[0]),monitor=$monitor}))"
      }
      'exec' {
        $command = Lua-String $Arguments[2]
        $expression = "hl.dispatch(hl.dsp.exec_cmd($command))"
      }
      'movecursor' {
        $parts = $Arguments[2].Split(' ')
        $expression = "hl.dispatch(hl.dsp.cursor.move({x=$([int]$parts[0]),y=$([int]$parts[1])}))"
      }
      'exit' { $expression = 'hl.dispatch(hl.dsp.exit())' }
      default { throw "Unknown test dispatcher: $($Arguments[1])" }
    }
  } elseif ($Arguments[0] -eq 'keyword') {
    switch ($Arguments[1]) {
      'cursor:no_warps' { $expression = "hl.config({cursor={no_warps=$($Arguments[2])}})" }
      'monitor' {
        $parts = $Arguments[2].Split(',')
        $output = Lua-String $parts[0]
        $mode = Lua-String $parts[1]
        $position = Lua-String $parts[2]
        $expression = "hl.monitor({output=$output,mode=$mode,position=$position,scale=$($parts[3])})"
      }
      default { throw "Unknown test keyword: $($Arguments[1])" }
    }
  }
  if ($expression) { Invoke-TestLinux @('hyprctl','eval',$expression) }
  else { Invoke-TestLinux (@('hyprctl') + $Arguments) }
}
function Wait-Until([scriptblock]$Condition, [int]$Seconds = 15) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  do {
    try { if (& $Condition) { return } } catch { }
    Start-Sleep -Milliseconds 150
  } while ((Get-Date) -lt $deadline)
  throw "condition did not become true within $Seconds seconds"
}
function Focus-Viewer([int]$Output) {
  if ($singleOutput) { $Output = 1 }
  [void][WarpDesktopNative]::ShowWindow($windows[$Output], 9)
  [void][WarpDesktopNative]::SetForegroundWindow($windows[$Output])
  Wait-Until { [WarpDesktopNative]::GetForegroundWindow() -eq $windows[$Output] }
}
function Move-ToOutput([int]$Output) {
  if ($singleOutput) { $Output = 1 }
  Focus-Viewer $Output
  $origin = [WarpDesktopNative]::Origin($windows[$Output])
  # After a deliberately suppressed warp, Linux and Windows can differ until actual motion.
  # Do not rely on SetCursorPos at the unchanged host coordinate to synthesize an event.
  [void][WarpDesktopNative]::SetCursorPos($origin.X + 99, $origin.Y + 99)
  Start-Sleep -Milliseconds 30
  if (-not [WarpDesktopNative]::SetCursorPos($origin.X + 100, $origin.Y + 100)) { throw "SetCursorPos failed" }
  Wait-Until { @((Invoke-Hypr @('-j','monitors') | ConvertFrom-Json) | Where-Object { $_.name -eq "WSL-$Output" -and $_.focused }).Count -eq 1 }
}
function Press-Workspace([int]$Workspace) {
  # Actual Windows set-1 key events, not a direct dispatcher or the viewer's script queue.
  if (-not (@($windows.Values) -contains [WarpDesktopNative]::GetForegroundWindow())) {
    throw 'Foreground changed before key injection; leave the mouse/keyboard idle during this test'
  }
  if ([IntPtr]::Size -ne 8) { throw 'This native input test requires a 64-bit Windows host' }
  [WarpDesktopNative]::WorkspaceKey($Workspace)
}
function Assert-Synchronized([int]$Output) {
  if ($singleOutput) { $Output = 1 }
  Wait-Until {
    $monitor = (Invoke-Hypr @('-j','monitors') | ConvertFrom-Json) | Where-Object name -eq "WSL-$Output"
    $linux = Invoke-Hypr @('-j','cursorpos') | ConvertFrom-Json
    $actual = [WarpDesktopNative]::Cursor()
    $origin = [WarpDesktopNative]::Origin($windows[$Output])
    $x = ($linux.x - $monitor.x) * $monitor.scale
    $y = ($linux.y - $monitor.y) * $monitor.scale
    $monitor.focused -and $x -ge 0 -and $x -le $monitor.width -and $y -ge 0 -and $y -le $monitor.height -and
      [Math]::Abs($actual.X - $origin.X - $x) -le 3 -and [Math]::Abs($actual.Y - $origin.Y - $y) -le 3
  }
}
function Assert-PointerUnchanged($Before) {
  Start-Sleep -Milliseconds 500
  $after = [WarpDesktopNative]::Cursor()
  if ($after.X -ne $Before.X -or $after.Y -ne $Before.Y) {
    throw "host pointer moved unexpectedly: ($($Before.X),$($Before.Y)) -> ($($after.X),$($after.Y))"
  }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
  Write-Host "TEST: $Name"
  & $Body
  $results.Add([pscustomobject]@{ test = $Name; passed = $true })
  Write-Host "PASS: $Name"
}
try {
  $viewerArgs = @('--distro', $Distro, '--user', $User, '--monitors', "$expectedOutputs",
    '--dump-frame', ('"' + (Join-Path $OutDir 'frame.bmp') + '"'), '--dump-after', '5')
  if (-not $Fullscreen) { $viewerArgs += @('--windowed', '800x600', '--scale', '1.25') }
  $viewer = Start-Process -FilePath (Resolve-Path $Exe).Path -ArgumentList $viewerArgs -PassThru `
    -RedirectStandardOutput (Join-Path $OutDir 'viewer-stdout.log') -RedirectStandardError (Join-Path $OutDir 'viewer-stderr.log')
  # Hold the handle while alive; Windows PowerShell 5.1 can otherwise report a null ExitCode.
  $viewerHandle = $viewer.Handle
  Wait-Until { $script:windows = [WarpDesktopNative]::Windows($viewer.Id); $script:windows.Count -eq $expectedOutputs } 60
  Write-Host "$expectedOutputs viewer window(s) are ready."
  Wait-Until { @((Invoke-Hypr @('-j','monitors') | ConvertFrom-Json)).Count -eq $expectedOutputs } 60
  Write-Host "$expectedOutputs Hyprland output(s) are ready."
  Focus-Viewer 1
  Write-Host 'Viewer is foreground.'
  if (-not $Fullscreen) {
    [void](Invoke-Hypr @('keyword','monitor','WSL-1,800x600,0x0,1.25'))
    [void](Invoke-Hypr @('keyword','monitor','WSL-2,800x600,640x0,1'))
  }
  [void](Invoke-Hypr @('dispatch','moveworkspacetomonitor','1 WSL-1'))
  [void](Invoke-Hypr @('dispatch','workspace','2'))
  $secondOutput = if ($singleOutput) { 1 } else { 2 }
  [void](Invoke-Hypr @('dispatch','moveworkspacetomonitor',"2 WSL-$secondOutput"))
  [void](Invoke-Hypr @('dispatch','workspace','1'))
  [void](Invoke-Hypr @('dispatch','exec','foot --title WomarchyWarp1'))
  Write-Host 'Waiting for the workspace-1 test terminal.'
  Wait-Until { @((Invoke-Hypr @('-j','clients') | ConvertFrom-Json) | Where-Object initialTitle -eq 'WomarchyWarp1').Count -eq 1 }
  [void](Invoke-Hypr @('dispatch','workspace','2'))
  [void](Invoke-Hypr @('dispatch','exec','foot --title WomarchyWarp2'))
  Write-Host 'Waiting for the workspace-2 test terminal.'
  Wait-Until { @((Invoke-Hypr @('-j','clients') | ConvertFrom-Json) | Where-Object initialTitle -eq 'WomarchyWarp2').Count -eq 1 }
  [void](Invoke-Hypr @('keyword','cursor:no_warps','false'))
  Test-Case 'configured output scales and rendered frames' {
    $monitors = Invoke-Hypr @('-j','monitors') | ConvertFrom-Json
    if (-not $singleOutput -and @($monitors.scale | Select-Object -Unique).Count -lt 2) { throw 'mixed-scale monitor setup failed' }
    $monitors | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 (Join-Path $OutDir 'monitors.json')
    Wait-Until { (Test-Path (Join-Path $OutDir 'frame.bmp')) -and (Get-Item (Join-Path $OutDir 'frame.bmp')).Length -gt 1000 }
  }
  for ($cycle = 1; $cycle -le 3; $cycle++) {
    foreach ($output in @(1,2)) {
      Test-Case "Win+$output moves focus and the physical cursor (cycle $cycle)" {
        if ($singleOutput) { [void](Invoke-Hypr @('dispatch','workspace',"$(3 - $output)")) }
        Move-ToOutput (3 - $output)
        Press-Workspace $output
        Assert-Synchronized $output
        $active = Invoke-Hypr @('-j','activeworkspace') | ConvertFrom-Json
        if ($active.id -ne $output) { throw "wrong active workspace: $($active.id)" }
      }
      Test-Case "small real mouse movement does not jump back (output $output, cycle $cycle)" {
        $point = [WarpDesktopNative]::Cursor()
        [void][WarpDesktopNative]::SetCursorPos($point.X + 2, $point.Y + 2)
        Start-Sleep -Milliseconds 200
        Assert-Synchronized $output
      }
    }
  }
  Test-Case 'ordinary mouse motion follows configured outputs' {
    Move-ToOutput 1; Assert-Synchronized 1
    Move-ToOutput 2; Assert-Synchronized 2
  }
  Test-Case 'cursor:no_warps blocks non-forced keyboard warps' {
    Move-ToOutput 2
    [void](Invoke-Hypr @('keyword','cursor:no_warps','true'))
    $before = [WarpDesktopNative]::Cursor()
    Press-Workspace 1
    Assert-PointerUnchanged $before
  }
  Test-Case 'forced movecursor still synchronizes when no_warps is enabled' {
    Focus-Viewer 2
    $m = (Invoke-Hypr @('-j','monitors') | ConvertFrom-Json) | Where-Object name -eq 'WSL-1'
    $targetX = [int]($m.x + $m.width / $m.scale / 2)
    $targetY = [int]($m.y + $m.height / $m.scale / 2)
    [void](Invoke-Hypr @('dispatch','movecursor',"$targetX $targetY"))
    Assert-Synchronized 1
    [void](Invoke-Hypr @('keyword','cursor:no_warps','false'))
  }
  if (-not $singleOutput) {
  Test-Case 'a minimized target does not move the host pointer' {
    Move-ToOutput 2
    [void][WarpDesktopNative]::ShowWindow($windows[1], 6)
    Focus-Viewer 2
    if (-not [WarpDesktopNative]::IsIconic($windows[1])) { throw 'target was not minimized' }
    $before = [WarpDesktopNative]::Cursor()
    [void](Invoke-Hypr @('dispatch','workspace','1'))
    Assert-PointerUnchanged $before
    [void][WarpDesktopNative]::ShowWindow($windows[1], 9)
  }
  Test-Case 'a hidden target does not move the host pointer' {
    Move-ToOutput 2
    [void][WarpDesktopNative]::ShowWindow($windows[1], 0)
    $before = [WarpDesktopNative]::Cursor()
    [void](Invoke-Hypr @('dispatch','workspace','1'))
    Assert-PointerUnchanged $before
    [void][WarpDesktopNative]::ShowWindow($windows[1], 5)
  }
  }
  Test-Case 'a foreground Windows application prevents compositor cursor theft' {
    Move-ToOutput 2
    [void](Invoke-Hypr @('dispatch','workspace','2'))
    $script:form = New-Object Windows.Forms.Form
    $form.Text = 'Womarchy pointer guard test'
    $form.SetBounds(300, 760, 300, 160)
    $form.TopMost = $true
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    [void][WarpDesktopNative]::SetForegroundWindow($form.Handle)
    Wait-Until { [WarpDesktopNative]::GetForegroundWindow() -eq $form.Handle }
    $origin = [WarpDesktopNative]::Origin($form.Handle)
    [void][WarpDesktopNative]::SetCursorPos($origin.X + 50, $origin.Y + 50)
    $before = [WarpDesktopNative]::Cursor()
    [void](Invoke-Hypr @('dispatch','workspace','1'))
    Assert-PointerUnchanged $before
    $form.Close(); $form.Dispose(); $script:form = $null
  }
  Focus-Viewer 1
  $linuxOut = "/mnt/" + $OutDir.Substring(0,1).ToLower() + ($OutDir.Substring(2) -replace '\\','/')
  [void](Invoke-TestLinux @('grim','-o','WSL-1',"$linuxOut/output-1.png"))
  if (-not $singleOutput) { [void](Invoke-TestLinux @('grim','-o','WSL-2',"$linuxOut/output-2.png")) }
  Test-Case 'no Hyprland configuration errors' {
    $errors = Invoke-Hypr @('configerrors')
    if ($errors.Trim() -and $errors.Trim() -ne 'ok') { throw "Hyprland config errors: $errors" }
  }
} catch {
  $failure = $_.Exception.Message
  Write-Host "FAIL: $failure"
  if ($viewer -and -not $viewer.HasExited) {
    try {
      Invoke-Hypr @('-j','clients') | Set-Content -Encoding UTF8 (Join-Path $OutDir 'failed-clients.json')
      Invoke-Hypr @('-j','monitors') | Set-Content -Encoding UTF8 (Join-Path $OutDir 'failed-monitors.json')
      Invoke-Hypr @('-j','cursorpos') | Set-Content -Encoding UTF8 (Join-Path $OutDir 'failed-cursor.json')
      [pscustomobject]@{ cursor = [WarpDesktopNative]::Cursor(); foreground = [WarpDesktopNative]::GetForegroundWindow().ToInt64();
        origin1 = [WarpDesktopNative]::Origin($windows[1]); origin2 = $(if ($windows.ContainsKey(2)) { [WarpDesktopNative]::Origin($windows[2]) }) } |
        ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $OutDir 'failed-native.json')
    } catch { }
  }
} finally {
  if ($form) { $form.Close(); $form.Dispose() }
  if ($viewer) {
    if (-not $viewer.HasExited) {
      foreach ($h in [WarpDesktopNative]::Windows($viewer.Id).Values) {
        [void][WarpDesktopNative]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
      }
      if (-not $viewer.WaitForExit(20000)) {
        try { [void](Invoke-Hypr @('dispatch','exit')) } catch { }
        if (-not $viewer.WaitForExit(10000)) { $viewer.Kill(); if (-not $failure) { $failure = 'viewer did not exit cleanly' } }
      }
    }
    if ($viewer.HasExited -and -not $failure) {
      [uint32]$exitCode = 0
      if (-not [WarpDesktopNative]::GetExitCodeProcess($viewerHandle, [ref]$exitCode)) {
        $failure = 'could not read the viewer exit status'
      } elseif ($exitCode -ne 0) { $failure = "viewer exited with $exitCode" }
      else { $results.Add([pscustomobject]@{ test = 'clean viewer exit'; passed = $true }) }
    }
  }
  [void][WarpDesktopNative]::SetForegroundWindow($oldFocus)
  [void][WarpDesktopNative]::SetCursorPos($oldPointer.X, $oldPointer.Y)
  [void][WarpDesktopNative]::SetThreadDpiAwarenessContext($oldDpi)
  [pscustomobject]@{ passed = -not $failure; failure = $failure; tests = @($results.ToArray()) } |
    ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $OutDir 'results.json')
}
if ($failure) { exit 1 }
Write-Host "All $($results.Count) desktop integration checks passed."
