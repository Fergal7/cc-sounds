# Plays a Windows media .wav for Claude Code hook notifications, but ONLY
# when the hosting terminal is NOT the focused foreground window (i.e. it
# is minimized or in the background). Keeps quiet while you are actively
# looking at the session.
#
# Playback is capped at MaxMilliseconds because the stock Windows alarm
# wavs run ~5s; a short clip is enough to notify without being annoying.
# Pass MaxMilliseconds = 0 to play the wav in full (used for the finish
# sound, where the turn has already ended so blocking costs nothing).
#
# Usage: play-if-background.ps1 <WavFileName> [MaxMilliseconds]
#        e.g. play-if-background.ps1 Alarm04.wav 1500
param(
    [string]$WavFileName,
    [int]$MaxMilliseconds = 1500
)

$mediaPath = Join-Path $env:WINDIR "Media\$WavFileName"
if (-not (Test-Path $mediaPath)) { return }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ForegroundWindowNative
{
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr handle);
}
"@

# Walk the parent-process chain to find the terminal window that hosts this
# hook. The hook itself runs windowless, so its owning terminal is the first
# ancestor that exposes a real MainWindowHandle. A single process snapshot is
# taken up front so the walk stays in memory (per-hop CIM queries are slow).
$parentByProcessId = @{}
foreach ($process in Get-CimInstance Win32_Process) {
    $parentByProcessId[[int]$process.ProcessId] = [int]$process.ParentProcessId
}

$terminalWindowHandle = [IntPtr]::Zero
$walkProcessId = $PID
for ($hop = 0; $hop -lt 8; $hop++) {
    $candidate = Get-Process -Id $walkProcessId -ErrorAction SilentlyContinue
    if ($candidate -and $candidate.MainWindowHandle -ne [IntPtr]::Zero) {
        $terminalWindowHandle = $candidate.MainWindowHandle
        break
    }
    if (-not $parentByProcessId.ContainsKey($walkProcessId)) { break }
    $walkProcessId = $parentByProcessId[$walkProcessId]
    if ($walkProcessId -le 0) { break }
}

# Default to playing. Only suppress when we positively identify the terminal
# AND it is the focused, non-minimized foreground window.
$shouldPlay = $true
if ($terminalWindowHandle -ne [IntPtr]::Zero) {
    $foregroundWindowHandle = [ForegroundWindowNative]::GetForegroundWindow()
    $isMinimized = [ForegroundWindowNative]::IsIconic($terminalWindowHandle)
    if ($foregroundWindowHandle -eq $terminalWindowHandle -and -not $isMinimized) {
        $shouldPlay = $false
    }
}

if ($shouldPlay) {
    $player = New-Object Media.SoundPlayer $mediaPath
    if ($MaxMilliseconds -le 0) {
        $player.PlaySync()
    } else {
        $player.Play()
        Start-Sleep -Milliseconds $MaxMilliseconds
    }
}
