# cc-sounds

Notification sounds for [Claude Code](https://claude.com/claude-code) on Windows. Get an audible cue when Claude finishes, hits an error, or needs your input — so you can look away and still know when to come back.

| Event | Sound | When it plays |
|-------|-------|---------------|
| Finished | `Alarm09.wav` | a turn completes |
| Error | `Ring02.wav` | a turn ends in failure |
| Needs you | `Alarm04.wav` | a permission prompt or question appears |

Sounds **only play when the terminal is in the background or minimized** — it stays silent while you're actively watching the session, so it never interrupts you mid-flow.

## Requirements

- **Windows.** Uses PowerShell and the built-in `.wav` files in `%WINDIR%\Media`. It's a no-op on macOS/Linux, so it's safe to install anywhere.

## Install

```
/plugin marketplace add Fergal7/cc-sounds
/plugin install cc-sounds@cc-sounds
```

Then restart Claude Code so the hooks load.

## Customise the sounds

The three sounds are stock Windows `.wav` files under `C:\Windows\Media`. To change one, edit `hooks/hooks.json` and swap the wav filename argument for any file in that folder (e.g. `Ring05.wav`, `Chord.wav`).

The trailing number after the filename caps playback length in milliseconds:
- `0` → play the wav in full (used for finish/error, where nothing is waiting).
- `1500` → cap at 1.5s (used for the input cues, so they stay short and snappy).

## How it works

`hooks/hooks.json` wires four Claude Code hook events (`Stop`, `StopFailure`, `PermissionRequest`, `Elicitation`) to `scripts/play-if-background.ps1`, which:

1. Resolves the requested wav under `%WINDIR%\Media`.
2. Walks the process tree to find the terminal window hosting the session.
3. Plays the sound only if that window **isn't** the focused foreground window.

Paths use `${CLAUDE_PLUGIN_ROOT}`, so the script resolves correctly on any machine with no manual editing.

## Licence

MIT — do whatever you like with it.
