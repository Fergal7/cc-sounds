# Plays a Windows media .wav for Claude Code hook notifications, but ONLY for
# the ROOT interactive session -- the one the human started in a terminal -- and
# only when that terminal is NOT the focused foreground window (minimized or in
# the background). Keeps quiet while you are actively looking at the session, and
# keeps quiet for spawned sub-sessions.
#
# Why the root-only rule: tools like second-opinion MCP servers launch a FULL
# nested Claude Code session (often a different model) as a subprocess. Each
# nested session fires its own Stop hook, so without this guard every second
# opinion would jingle. The root session's completion is the only "everything is
# done" signal worth a sound -- when it finishes, the sub-sessions already have.
#
# Playback is capped at MaxMilliseconds because the stock Windows alarm wavs run
# ~5s; a short clip is enough to notify without being annoying. Pass
# MaxMilliseconds = 0 to play the wav in full (used for the finish sound, where
# the turn has already ended so blocking costs nothing).
#
# Env overrides:
#   CC_SOUNDS_DISABLE  - set to anything to force silence for this instance.
#   CC_SOUNDS_DEBUG    - print the decision (and why) to stderr, skip playback.
#
# EventClass controls how nested (spawned sub-)sessions are treated:
#   'completion' (Stop / StopFailure) - a sub-session finishing is noise; the
#                 root session's own completion is the only "done" worth a sound.
#                 Nested completion => silent.
#   'input'      (PermissionRequest / Elicitation) - a sub-session BLOCKED on
#                 human input still deserves a ping even when nested, because a
#                 human must act. Nested input => falls through to the normal
#                 terminal foreground/background test (silent only if you are
#                 already looking at the terminal).
# (The second-opinion MCP runs its sub-sessions with permissionMode
# 'bypassPermissions', so they never raise input events -- but other nested-
# claude tools might, and this keeps their prompts audible.)
#
# Usage: play-if-background.ps1 <WavFileName> [MaxMilliseconds] [EventClass]
#        e.g. play-if-background.ps1 Alarm04.wav 2000 input
param(
    [string]$WavFileName,
    [int]$MaxMilliseconds = 2000,
    [ValidateSet('completion','input')]
    [string]$EventClass = 'completion'
)

function Write-Decision([bool]$shouldPlay, [string]$reason) {
    if ($env:CC_SOUNDS_DEBUG) {
        $line = "cc-sounds: pid=$PID claudePid=$env:CLAUDE_PID wav=$WavFileName shouldPlay=$shouldPlay reason=$reason"
        [Console]::Error.WriteLine($line)
        # Also append to a log file, so decisions from NESTED sessions (whose
        # stderr the user never sees) can be inspected after a test run.
        try { Add-Content -Path (Join-Path $env:TEMP 'cc-sounds-debug.log') -Value $line -ErrorAction Stop } catch {}
    }
}

# Explicit opt-out and remote/cloud sessions (no local terminal to notify).
if ($env:CC_SOUNDS_DISABLE)          { Write-Decision $false 'CC_SOUNDS_DISABLE'; return }
if ($env:CLAUDE_CODE_REMOTE -eq 'true') { Write-Decision $false 'CLAUDE_CODE_REMOTE'; return }

$mediaPath = Join-Path $env:WINDIR "Media\$WavFileName"
if (-not (Test-Path $mediaPath)) { Write-Decision $false 'wav-not-found'; return }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ForegroundWindowNative
{
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr handle);
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
# Between them, the only unhandled case is "child is node.exe AND CLAUDE_PID was
# inherited from root" -- which the CC_SOUNDS_DEBUG probe below will reveal on a
# real run.
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
if ($isNested -and $EventClass -eq 'completion') {
    Write-Decision $false "nested-claude-session (owner=$ownerClaudePid claudeAncestors=$claudeAncestors)"
    return
}

# Find the terminal window that hosts this hook: the first ancestor that exposes
# a real MainWindowHandle. The hook itself runs windowless.
$terminalWindowHandle = [IntPtr]::Zero
$walkProcessId = $PID
for ($hop = 0; $hop -lt 12; $hop++) {
    $candidate = Get-Process -Id $walkProcessId -ErrorAction SilentlyContinue
    if ($candidate -and $candidate.MainWindowHandle -ne [IntPtr]::Zero) {
        $terminalWindowHandle = $candidate.MainWindowHandle
        break
    }
    $info = $procById[$walkProcessId]
    if (-not $info) { break }
    $walkProcessId = $info.Parent
    if ($walkProcessId -le 0) { break }
}

# No owning terminal window => headless (claude -p / SDK / CI). Nobody is
# watching; stay silent. Otherwise notify only when the terminal is NOT the
# focused, non-minimized foreground window.
if ($terminalWindowHandle -eq [IntPtr]::Zero) { Write-Decision $false 'no-terminal-window'; return }

$foregroundWindowHandle = [ForegroundWindowNative]::GetForegroundWindow()
$isMinimized = [ForegroundWindowNative]::IsIconic($terminalWindowHandle)
$isForeground = ($foregroundWindowHandle -eq $terminalWindowHandle -and -not $isMinimized)

if ($isForeground) { Write-Decision $false 'terminal-foreground'; return }

Write-Decision $true 'terminal-background'
if ($env:CC_SOUNDS_DEBUG) { return }

$player = New-Object Media.SoundPlayer $mediaPath
if ($MaxMilliseconds -le 0) {
    $player.PlaySync()
} else {
    $player.Play()
    Start-Sleep -Milliseconds $MaxMilliseconds
}
