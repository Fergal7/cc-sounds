# Plays a Windows media .wav for Claude Code hook notifications, and flashes the
# terminal's taskbar button, but ONLY for the ROOT interactive session -- the one
# the human started in a terminal -- and only when that terminal is NOT the
# focused foreground window (minimized or in the background). Keeps quiet while
# you are actively looking at the session, and keeps quiet for spawned
# sub-sessions.
#
# Why the root-only rule: tools like second-opinion MCP servers launch a FULL
# nested Claude Code session (often a different model) as a subprocess. Each
# nested session fires its own Stop hook, so without this guard every second
# opinion would jingle. The root session's completion is the only "everything is
# done" signal worth a sound -- when it finishes, the sub-sessions already have.
#
# User settings live in ~/.claude/cc-sounds.json (see cc-sounds-config.ps1 and
# the /cc-sounds slash command): master mute, per-event enable/disable, a custom
# sound per event, and a taskbar-flash toggle. Missing/!invalid config falls back
# to built-in defaults, so the hook never breaks on a bad file.
#
# Env overrides (per-instance, win over config):
#   CC_SOUNDS_DISABLE  - set to anything to force silence for this instance.
#   CC_SOUNDS_DEBUG    - print the decision (and why) to stderr, skip play+flash.
#
# Event classes (derived from EventName) control nested-session handling:
#   completion (Stop / StopFailure) - a sub-session finishing is noise => silent.
#   input      (PermissionRequest / Elicitation) - a sub-session blocked on human
#              input still pings even when nested (falls through to the terminal
#              foreground/background test).
#
# Usage: play-if-background.ps1 <EventName> <DefaultWav> [MaxMilliseconds]
#        e.g. play-if-background.ps1 PermissionRequest Alarm04.wav 2000
param(
    [string]$EventName,
    [string]$WavFileName,
    [int]$MaxMilliseconds = 2000
)

# completion events finish silently when nested; input events still ping.
$eventClass = if ($EventName -in @('Stop','StopFailure')) { 'completion' } else { 'input' }

function Write-Decision([bool]$shouldPlay, [string]$reason) {
    if ($env:CC_SOUNDS_DEBUG) {
        $line = "cc-sounds: pid=$PID claudePid=$env:CLAUDE_PID event=$EventName wav=$WavFileName shouldPlay=$shouldPlay reason=$reason"
        [Console]::Error.WriteLine($line)
        # Also append to a log file, so decisions from NESTED sessions (whose
        # stderr the user never sees) can be inspected after a test run.
        try { Add-Content -Path (Join-Path $env:TEMP 'cc-sounds-debug.log') -Value $line -ErrorAction Stop } catch {}
    }
}

# ── User config (~/.claude/cc-sounds.json) ─────────────────────────────
# Shape: { muted:bool, flash:bool, events:{ <EventName>:{ enabled:bool, sound:str } } }
# `sound` is either a bare Windows Media filename (resolved under WINDIR\Media) or
# an absolute path to a custom .wav.
$flashEnabled = $true
$eventEnabled = $true
$configSound  = $null
try {
    $configPath = Join-Path $env:USERPROFILE '.claude\cc-sounds.json'
    if (Test-Path $configPath) {
        $cfg = Get-Content -Raw $configPath | ConvertFrom-Json
        if ($cfg.PSObject.Properties.Name -contains 'muted' -and $cfg.muted) {
            Write-Decision $false 'muted-by-config'; return
        }
        if ($cfg.PSObject.Properties.Name -contains 'flash') { $flashEnabled = [bool]$cfg.flash }
        $evCfg = $null
        if ($cfg.events -and ($cfg.events.PSObject.Properties.Name -contains $EventName)) {
            $evCfg = $cfg.events.$EventName
        }
        if ($evCfg) {
            if ($evCfg.PSObject.Properties.Name -contains 'enabled') { $eventEnabled = [bool]$evCfg.enabled }
            if ($evCfg.PSObject.Properties.Name -contains 'sound' -and $evCfg.sound) { $configSound = [string]$evCfg.sound }
        }
    }
} catch { }  # malformed config => fall back to defaults, never break the hook

if (-not $eventEnabled) { Write-Decision $false 'event-disabled-by-config'; return }

# Explicit per-instance opt-out and remote/cloud sessions (no local terminal).
if ($env:CC_SOUNDS_DISABLE)             { Write-Decision $false 'CC_SOUNDS_DISABLE'; return }
if ($env:CLAUDE_CODE_REMOTE -eq 'true') { Write-Decision $false 'CLAUDE_CODE_REMOTE'; return }

# Resolve the sound file: config override (absolute path or Media name) else the
# default wav passed by the hook.
$soundName = if ($configSound) { $configSound } else { $WavFileName }
if ([System.IO.Path]::IsPathRooted($soundName)) {
    $mediaPath = $soundName
} else {
    $mediaPath = Join-Path $env:WINDIR "Media\$soundName"
}
if (-not (Test-Path $mediaPath)) { Write-Decision $false "wav-not-found:$mediaPath"; return }

Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Win32Notify
{
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr handle);

    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO {
        public uint cbSize; public IntPtr hwnd; public uint dwFlags;
        public uint uCount; public uint dwTimeout;
    }
    [DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    // FLASHW_ALL (3) | FLASHW_TIMERNOFG (12) = flash caption + taskbar until the
    // window is brought to the foreground. So the pinging terminal keeps pulsing
    // until you click it -- the "which of my 8 terminals" signal.
    public static void FlashUntilFocused(IntPtr hwnd) {
        FLASHWINFO fi = new FLASHWINFO();
        fi.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        fi.hwnd = hwnd; fi.dwFlags = 15; fi.uCount = uint.MaxValue; fi.dwTimeout = 0;
        FlashWindowEx(ref fi);
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    // Find the top-level window owned by one of `pids` (the VS Code processes)
    // whose title contains `titleContains` (the workspace folder name). Electron
    // shares one main process across windows, so Process.MainWindowHandle is
    // unreliable; enumerating by title is the only way to hit the RIGHT window.
    public static IntPtr FindWindowByPidsAndTitle(int[] pids, string titleContains) {
        HashSet<int> set = new HashSet<int>(pids);
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            uint wpid; GetWindowThreadProcessId(h, out wpid);
            if (!set.Contains((int)wpid)) return true;
            int len = GetWindowTextLength(h);
            if (len <= 0) return true;
            StringBuilder sb = new StringBuilder(len + 1);
            GetWindowText(h, sb, sb.Capacity);
            if (sb.ToString().IndexOf(titleContains, StringComparison.OrdinalIgnoreCase) >= 0) {
                found = h; return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@

# Single up-front process snapshot (per-hop CIM queries are slow). Keyed by PID,
# storing parent PID and image name for the ancestry walks below.
$procById = @{}
foreach ($process in Get-CimInstance Win32_Process) {
    $procById[[int]$process.ProcessId] = [pscustomobject]@{
        Parent = [int]$process.ParentProcessId
        Name   = "$($process.Name)".ToLowerInvariant()
    }
}

# Identify the Claude Code process that owns this hook. Claude Code exports
# CLAUDE_PID into every hook subprocess; fall back to walking up to the first
# claude.exe ancestor if it is ever absent.
$ownerClaudePid = 0
if ($env:CLAUDE_PID -and ($env:CLAUDE_PID -as [int])) {
    $ownerClaudePid = [int]$env:CLAUDE_PID
} else {
    $probe = $PID
    for ($hop = 0; $hop -lt 12; $hop++) {
        $info = $procById[$probe]
        if (-not $info) { break }
        if ($info.Name -eq 'claude.exe') { $ownerClaudePid = $probe; break }
        $probe = $info.Parent
        if ($probe -le 0) { break }
    }
}

# Nested-session test. A spawned sub-session (e.g. second-opinion MCP, which
# launches a FULL Claude Code via @anthropic-ai/claude-agent-sdk) always has a
# parent claude sitting above it in the process tree; the root session's
# ancestry reaches the terminal with no intervening claude. Nested => silent.
#
# Two independent signals, OR'd, so detection survives both things we could not
# verify statically about the SDK-spawned child:
#   (A) Walk up from our CLAUDE_PID-identified owning claude; another claude.exe
#       above it => nested. Robust when the child is spawned as node.exe, but
#       depends on CLAUDE_PID being the child's own pid (not root's, inherited).
#   (B) Count claude.exe processes in this hook's own ancestry. Root hook sees
#       exactly one (root); a nested hook sees two (child + root). Robust even if
#       CLAUDE_PID was inherited, provided the child runs as claude.exe.
$isNested = $false
if ($ownerClaudePid -gt 0 -and $procById.ContainsKey($ownerClaudePid)) {
    $probe = $procById[$ownerClaudePid].Parent
    for ($hop = 0; $hop -lt 12; $hop++) {
        if ($probe -le 0) { break }
        $info = $procById[$probe]
        if (-not $info) { break }
        if ($info.Name -eq 'claude.exe') { $isNested = $true; break }
        $probe = $info.Parent
    }
}

$claudeAncestors = 0
$probe = $PID
for ($hop = 0; $hop -lt 16; $hop++) {
    $info = $procById[$probe]
    if (-not $info) { break }
    if ($info.Name -eq 'claude.exe') { $claudeAncestors++ }
    $probe = $info.Parent
    if ($probe -le 0) { break }
}
if ($claudeAncestors -ge 2) { $isNested = $true }

# Nested completion events are pure noise -> silent. Nested INPUT events mean a
# sub-session is blocked waiting on a human, so let them fall through to the
# normal terminal test below (they still stay quiet if you are looking at it).
if ($isNested -and $eventClass -eq 'completion') {
    Write-Decision $false "nested-claude-session (owner=$ownerClaudePid claudeAncestors=$claudeAncestors)"
    return
}

# Find the terminal window that hosts this hook.
#
# VS Code (Electron) shares ONE main Code.exe process across every window, and
# .NET Process.MainWindowHandle exposes only a single (often wrong) window for
# it -- so the ancestor walk would flash whichever VS Code window Windows calls
# "main", not the one hosting this terminal. When VS Code hosts us, disambiguate
# by matching the window whose TITLE contains this session's workspace folder.
# Standard terminals (Windows Terminal, conhost, pwsh) fall back to the ancestor
# MainWindowHandle walk, which is correct there.

# Workspace folder name: from the hook's stdin JSON (cwd), else current dir.
$workspaceLeaf = ''
try {
    if ([Console]::IsInputRedirected) {
        $hookJson = [Console]::In.ReadToEnd()
        if ($hookJson) {
            $hookObj = $hookJson | ConvertFrom-Json
            if ($hookObj.cwd) { $workspaceLeaf = Split-Path -Leaf ([string]$hookObj.cwd) }
        }
    }
} catch { }
if (-not $workspaceLeaf) { try { $workspaceLeaf = Split-Path -Leaf (Get-Location).Path } catch { } }

# Are we hosted by VS Code? (any code.exe ancestor)
$inVSCode = $false
$probe = $PID
for ($hop = 0; $hop -lt 16; $hop++) {
    $info = $procById[$probe]
    if (-not $info) { break }
    if ($info.Name -eq 'code.exe') { $inVSCode = $true; break }
    $probe = $info.Parent
    if ($probe -le 0) { break }
}

$terminalWindowHandle = [IntPtr]::Zero
$handleSource = 'none'

if ($inVSCode -and $workspaceLeaf) {
    $codePids = @()
    foreach ($k in $procById.Keys) { if ($procById[$k].Name -eq 'code.exe') { $codePids += [int]$k } }
    if ($codePids.Count -gt 0) {
        $terminalWindowHandle = [Win32Notify]::FindWindowByPidsAndTitle([int[]]$codePids, $workspaceLeaf)
        if ($terminalWindowHandle -ne [IntPtr]::Zero) { $handleSource = "vscode-title:$workspaceLeaf" }
    }
}

# Fallback: first ancestor exposing a real MainWindowHandle (non-VSCode, or a
# VS Code title miss e.g. a customised window.title).
if ($terminalWindowHandle -eq [IntPtr]::Zero) {
    $walkProcessId = $PID
    for ($hop = 0; $hop -lt 12; $hop++) {
        $candidate = Get-Process -Id $walkProcessId -ErrorAction SilentlyContinue
        if ($candidate -and $candidate.MainWindowHandle -ne [IntPtr]::Zero) {
            $terminalWindowHandle = $candidate.MainWindowHandle
            $handleSource = 'ancestor-walk'
            break
        }
        $info = $procById[$walkProcessId]
        if (-not $info) { break }
        $walkProcessId = $info.Parent
        if ($walkProcessId -le 0) { break }
    }
}

# No owning terminal window => headless (claude -p / SDK / CI). Nobody is
# watching; stay silent. Otherwise notify only when the terminal is NOT the
# focused, non-minimized foreground window.
if ($terminalWindowHandle -eq [IntPtr]::Zero) { Write-Decision $false 'no-terminal-window'; return }

$foregroundWindowHandle = [Win32Notify]::GetForegroundWindow()
$isMinimized = [Win32Notify]::IsIconic($terminalWindowHandle)
$isForeground = ($foregroundWindowHandle -eq $terminalWindowHandle -and -not $isMinimized)

if ($isForeground) { Write-Decision $false "terminal-foreground (via $handleSource)"; return }

Write-Decision $true "terminal-background (via $handleSource)"
if ($env:CC_SOUNDS_DEBUG) { return }

# Flash the taskbar (only when a sound would play), so after un-minimizing a wall
# of terminals you can see which one pinged.
if ($flashEnabled) { [Win32Notify]::FlashUntilFocused($terminalWindowHandle) }

$player = New-Object Media.SoundPlayer $mediaPath
if ($MaxMilliseconds -le 0) {
    $player.PlaySync()
} else {
    $player.Play()
    Start-Sleep -Milliseconds $MaxMilliseconds
}
