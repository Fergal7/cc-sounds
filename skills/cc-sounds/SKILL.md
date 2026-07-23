---
name: cc-sounds
description: >
  Configure cc-sounds notifications — master mute, per-event enable/disable,
  custom sound per event, and taskbar flash. Invoked by the user via
  /cc-sounds (e.g. "/cc-sounds mute", "/cc-sounds sound Stop tada.wav").
disable-model-invocation: true
argument-hint: status | mute | unmute | flash on|off | event <Name> on|off | sound <Name> <wav> | reset
---

# /cc-sounds

Configure the cc-sounds notification plugin by running its settings helper with
the arguments the user passed to `/cc-sounds`, then reporting the result.

## Steps

1. Locate the helper script `cc-sounds-config.ps1`. It ships inside this plugin
   under `scripts/`. Prefer `${CLAUDE_PLUGIN_ROOT}/scripts/cc-sounds-config.ps1`
   if that variable resolves. Otherwise find it with Glob:
   `**/cc-sounds/**/scripts/cc-sounds-config.ps1` (it lives in the plugin cache).

2. Run it, passing the user's arguments **verbatim**. If the user gave no
   arguments, use `status`:

   ```
   powershell -NoProfile -File "<path>/cc-sounds-config.ps1" <arguments>
   ```

3. Summarise the resulting settings in one or two lines: master mute state,
   taskbar flash state, and any per-event enable/disable or custom-sound change.
   If the helper printed a line starting with `ERROR:`, show it verbatim along
   with the correct usage.

## Reference

Valid events: `Stop`, `StopFailure`, `PermissionRequest`, `Elicitation`.

Examples:
- `/cc-sounds status`
- `/cc-sounds mute` · `/cc-sounds unmute`
- `/cc-sounds flash off`
- `/cc-sounds event Stop off`
- `/cc-sounds sound Stop tada.wav`
- `/cc-sounds reset`
