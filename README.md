# cc-sounds

Notification sounds — plus a taskbar flash — for [Claude Code](https://claude.com/claude-code) on Windows. Get an audible **and** visual cue when Claude finishes, hits an error, or needs your input, so you can look away and still know when (and which terminal) to come back to.

| Event | Default sound | When it plays |
|-------|---------------|---------------|
| Finished | `Alarm09.wav` | a turn completes |
| Error | `Ring02.wav` | a turn ends in failure |
| Needs you | `Alarm04.wav` | a permission prompt or question appears |

Notifications fire **only when the terminal is in the background or minimized** — silent while you're actively watching the session, so it never interrupts you mid-flow.

## Highlights

- **Sound + taskbar flash.** When a background terminal needs you, its taskbar button pulses until you focus it — so with several windows open you can *see* which one pinged. In VS Code it targets the correct window by matching the workspace name (Electron shares one process across windows, which breaks the naive approach).
- **Root-session only.** Tools that spawn a *nested* Claude Code session — e.g. a second-opinion / multi-model MCP — would otherwise make every sub-session jingle. cc-sounds detects nested sessions and stays silent; only the session you actually started makes noise. (A nested session that blocks waiting on *your* input still pings.)
- **Configurable live** via the `/cc-sounds` command — mute, per-event toggles, custom sounds, flash on/off. No restart, no file editing.
- **Cross-platform-safe.** A no-op on macOS/Linux, so it's safe to install anywhere.

## Requirements

- **Windows.** Uses PowerShell and the built-in `.wav` files in `%WINDIR%\Media`.

## Install

```
/plugin marketplace add Fergal7/cc-sounds
/plugin install cc-sounds@cc-sounds
```

Then restart Claude Code so the hooks and the `/cc-sounds` command load.

Already installed and want a newer version? `/plugin marketplace update`, then restart.

## Configure — `/cc-sounds`

Settings live in `~/.claude/cc-sounds.json` and are read on every notification, so changes take effect immediately.

| Command | Effect |
|---------|--------|
| `/cc-sounds status` | show current settings |
| `/cc-sounds mute` · `/cc-sounds unmute` | master mute |
| `/cc-sounds flash on` · `off` | toggle the taskbar flash |
| `/cc-sounds event <Name> on` · `off` | enable/disable one event |
| `/cc-sounds sound <Name> <wav>` | set a custom sound for one event |
| `/cc-sounds reset` | restore defaults |

`<Name>` is one of `Stop`, `StopFailure`, `PermissionRequest`, `Elicitation`.
`<wav>` is any file in `C:\Windows\Media` (e.g. `tada.wav`, `chimes.wav`, `ding.wav`) or an absolute path to your own `.wav`.

```
/cc-sounds sound Stop tada.wav
/cc-sounds event StopFailure off
/cc-sounds flash off
```

### Environment overrides (per instance)

- `CC_SOUNDS_DISABLE` — set to anything to force this Claude instance silent.
- `CC_SOUNDS_DEBUG` — print the play/skip decision to stderr (and a log under `%TEMP%`) instead of playing, for troubleshooting.

## How it works

`hooks/hooks.json` wires four Claude Code hook events (`Stop`, `StopFailure`, `PermissionRequest`, `Elicitation`) to `scripts/play-if-background.ps1`, which:

1. Loads `~/.claude/cc-sounds.json` (mute / per-event / custom sound / flash).
2. **Detects nested sessions** — via the owning Claude Code process (`CLAUDE_PID`) and a scan for a parent `claude.exe`. Completion sounds from spawned sub-sessions are suppressed; the root session is the only "everything's done" signal.
3. Finds the hosting terminal window — for VS Code, by matching the workspace title (`MainWindowHandle` is unreliable for Electron's multi-window model); otherwise by walking the process tree.
4. Plays the sound and flashes the taskbar **only** when that window isn't the focused foreground window (and isn't headless / remote).

Paths use `${CLAUDE_PLUGIN_ROOT}`, so everything resolves on any machine with no manual editing.

### Notes & limits

- The taskbar flash is per **window**, not per terminal *tab*. Multiple tabs in one VS Code window share a window handle, so the flash points at the window; the sound still fires from the right session.
- Two VS Code windows open on the *same* folder can't be told apart by title — the flash targets the first match.

## Licence

MIT — do whatever you like with it.
