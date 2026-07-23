# Reads/writes ~/.claude/cc-sounds.json, the user settings for the cc-sounds
# plugin. Backs the /cc-sounds slash command. Prints the resulting config so the
# caller can show it. Creates the file with defaults on first use.
#
# Usage:
#   cc-sounds-config.ps1 status
#   cc-sounds-config.ps1 mute | unmute
#   cc-sounds-config.ps1 flash on | off
#   cc-sounds-config.ps1 event <Stop|StopFailure|PermissionRequest|Elicitation> on | off
#   cc-sounds-config.ps1 sound <EventName> <WavFileNameOrAbsolutePath>
#   cc-sounds-config.ps1 reset
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CmdArgs)

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $env:USERPROFILE '.claude\cc-sounds.json'
$validEvents = @('Stop','StopFailure','PermissionRequest','Elicitation')

function New-DefaultConfig {
    [ordered]@{
        muted = $false
        flash = $true
        events = [ordered]@{
            Stop              = [ordered]@{ enabled = $true; sound = 'Alarm09.wav' }
            StopFailure       = [ordered]@{ enabled = $true; sound = 'Ring02.wav' }
            PermissionRequest = [ordered]@{ enabled = $true; sound = 'Alarm04.wav' }
            Elicitation       = [ordered]@{ enabled = $true; sound = 'Alarm04.wav' }
        }
    }
}

function Read-Config {
    if (Test-Path $configPath) {
        try { return Get-Content -Raw $configPath | ConvertFrom-Json } catch { }
    }
    return (New-DefaultConfig | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
}

function Save-Config($cfg) {
    $dir = Split-Path $configPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $cfg | ConvertTo-Json -Depth 6 | Out-File -FilePath $configPath -Encoding utf8
}

function Ensure-Event($cfg, $name) {
    if (-not $cfg.events) { $cfg | Add-Member -NotePropertyName events -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not ($cfg.events.PSObject.Properties.Name -contains $name)) {
        $cfg.events | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{ enabled = $true; sound = 'Alarm04.wav' }) -Force
    }
}

function Set-Prop($obj, $name, $value) {
    if ($obj.PSObject.Properties.Name -contains $name) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
}

$cfg = Read-Config
$cmd = if ($CmdArgs.Count -ge 1) { $CmdArgs[0].ToLowerInvariant() } else { 'status' }

switch ($cmd) {
    'status' { }
    'reset'  { $cfg = New-DefaultConfig | ConvertTo-Json -Depth 6 | ConvertFrom-Json; Save-Config $cfg }
    'mute'   { Set-Prop $cfg 'muted' $true;  Save-Config $cfg }
    'unmute' { Set-Prop $cfg 'muted' $false; Save-Config $cfg }
    'flash'  {
        $v = if ($CmdArgs.Count -ge 2) { $CmdArgs[1].ToLowerInvariant() } else { '' }
        if ($v -notin @('on','off')) { Write-Output "ERROR: usage: flash on|off"; break }
        Set-Prop $cfg 'flash' ($v -eq 'on'); Save-Config $cfg
    }
    'event'  {
        $name = if ($CmdArgs.Count -ge 2) { $CmdArgs[1] } else { '' }
        $v    = if ($CmdArgs.Count -ge 3) { $CmdArgs[2].ToLowerInvariant() } else { '' }
        if ($name -notin $validEvents) { Write-Output "ERROR: event must be one of: $($validEvents -join ', ')"; break }
        if ($v -notin @('on','off'))   { Write-Output "ERROR: usage: event <Name> on|off"; break }
        Ensure-Event $cfg $name
        Set-Prop $cfg.events.$name 'enabled' ($v -eq 'on'); Save-Config $cfg
    }
    'sound'  {
        $name = if ($CmdArgs.Count -ge 2) { $CmdArgs[1] } else { '' }
        $wav  = if ($CmdArgs.Count -ge 3) { $CmdArgs[2] } else { '' }
        if ($name -notin $validEvents) { Write-Output "ERROR: event must be one of: $($validEvents -join ', ')"; break }
        if (-not $wav)                 { Write-Output "ERROR: usage: sound <Name> <wavFileOrPath>"; break }
        $resolved = if ([System.IO.Path]::IsPathRooted($wav)) { $wav } else { Join-Path $env:WINDIR "Media\$wav" }
        if (-not (Test-Path $resolved)) { Write-Output "ERROR: sound file not found: $resolved"; break }
        Ensure-Event $cfg $name
        Set-Prop $cfg.events.$name 'sound' $wav; Save-Config $cfg
    }
    default  { Write-Output "ERROR: unknown command '$cmd'. Try: status | mute | unmute | flash on|off | event <Name> on|off | sound <Name> <wav> | reset" }
}

Write-Output "cc-sounds settings ($configPath):"
Write-Output (Read-Config | ConvertTo-Json -Depth 6)
