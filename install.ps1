#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the meeting transcription suite from this repo into your profile.
.DESCRIPTION
    Copies scripts, config templates and the OBS profile/scene to their working locations.
    Safe to re-run:
      - Never deletes anything.
      - A file that already exists and differs is backed up first as <name>.<timestamp>.bak.
      - Settings, .env and config.yaml are only created when missing, never overwritten.
      - Recordings, transcripts and logs are never touched.
    Use -WhatIf first to see exactly what would happen. Nothing is written in that mode.

    Targets:
      scripts\*.ps1             -> <Target>\scripts\
      config\config.yaml        -> <Target>\config.yaml                (only if missing)
      config\suite.settings.*   -> <Target>\suite.settings.psd1        (only if missing)
      config\.env.example       -> <Target>\docker\.env                (only if missing)
      obs\basic.ini.template    -> <ObsDir>\basic\profiles\TranscriptionSuite\basic.ini
      obs\Teams Meeting ...json -> <ObsDir>\basic\scenes\
      startup\*.vbs             -> Windows Startup folder             (only with -InstallStartup)

    OBS global.ini is not modified. See obs\README.md for the two keys it needs.

    UNINSTALL (manual, by design; this script never deletes anything):
      1. Stop the watcher: end the powershell process running Watch-TeamsMeeting.ps1 (Task Manager).
      2. Delete <Target>\scripts\, suite.settings.psd1, config.yaml and docker\.env if you no longer want them.
         Keep <Target>\recordings and your transcripts folder if you want those files.
      3. Delete the OBS profile folder <ObsDir>\basic\profiles\TranscriptionSuite and the scene file
         <ObsDir>\basic\scenes\Teams Meeting Recording.json.
      4. If you used -InstallStartup, delete TranscriptionSuite.vbs from the Windows Startup folder
         (Win+R, shell:startup).
      5. Any *.bak files next to updated files are your previous versions; delete them when satisfied.
.PARAMETER Target
    Install root. Default: %USERPROFILE%\Documents\TranscriptionSuite
.PARAMETER RecordingsDir
    Where OBS writes recordings (substituted into the OBS profile). Default: <Target>\recordings
.PARAMETER ObsDir
    OBS config root. Default: %APPDATA%\obs-studio
.PARAMETER InstallStartup
    Also install the login shortcut (startup\TranscriptionSuite.vbs). Off by default.
.EXAMPLE
    .\install.ps1 -WhatIf
.EXAMPLE
    .\install.ps1 -InstallStartup
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Target        = (Join-Path $env:USERPROFILE 'Documents\TranscriptionSuite'),
    [string] $RecordingsDir,
    [string] $ObsDir        = (Join-Path $env:APPDATA 'obs-studio'),
    [switch] $InstallStartup
)

$ErrorActionPreference = 'Stop'
$repo  = $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $RecordingsDir) { $RecordingsDir = Join-Path $Target 'recordings' }
$counts = @{ NEW = 0; UPDATE = 0; SAME = 0; KEEP = 0; SKIP = 0 }

function Write-Status([string]$Status, [string]$Path, [string]$Note = '') {
    $counts[$Status]++
    $line = '{0,-7} {1}' -f $Status, $Path
    if ($Note) { $line += "  ($Note)" }
    Write-Host $line
}

function Read-Source([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom   = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    [pscustomobject]@{ Text = [IO.File]::ReadAllText($Path); Bom = $bom }
}

function Install-Text {
    param(
        [Parameter(Mandatory)][string] $Dest,
        [Parameter(Mandatory)][string] $Text,
        [bool]   $Bom = $false,
        [switch] $OnlyIfMissing
    )
    $exists = Test-Path -LiteralPath $Dest
    if ($exists -and $OnlyIfMissing) { Write-Status KEEP $Dest 'exists, not overwritten'; return }

    $backup = $null
    if ($exists) {
        $cur = [IO.File]::ReadAllText($Dest)
        if ($cur.Replace("`r`n", "`n") -eq $Text.Replace("`r`n", "`n")) { Write-Status SAME $Dest; return }
        $backup = "$Dest.$stamp.bak"
    }

    $action = if ($backup) { "Back up to $(Split-Path $backup -Leaf), then overwrite" } else { 'Create' }
    if ($PSCmdlet.ShouldProcess($Dest, $action)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Dest) | Out-Null
        if ($backup) { Copy-Item -LiteralPath $Dest -Destination $backup }
        [IO.File]::WriteAllText($Dest, $Text, (New-Object System.Text.UTF8Encoding($Bom)))
    }
    if ($backup) { Write-Status UPDATE $Dest "backup: $(Split-Path $backup -Leaf)" } else { Write-Status NEW $Dest }
}

function Install-File([string]$Src, [string]$Dest, [switch]$OnlyIfMissing) {
    $s = Read-Source $Src
    Install-Text -Dest $Dest -Text $s.Text -Bom $s.Bom -OnlyIfMissing:$OnlyIfMissing
}

Write-Host "Repo:    $repo"
Write-Host "Target:  $Target"
Write-Host "OBS dir: $ObsDir"
if ($WhatIfPreference) { Write-Host 'Dry run (-WhatIf): nothing will be written.' }
Write-Host ''

# 1. Scripts (always refreshed, with backup when different)
foreach ($f in Get-ChildItem (Join-Path $repo 'scripts') -Filter *.ps1) {
    Install-File $f.FullName (Join-Path $Target "scripts\$($f.Name)")
}

# 2. Config templates (create only; never overwrite real settings or secrets)
Install-File (Join-Path $repo 'config\config.yaml')                 (Join-Path $Target 'config.yaml')         -OnlyIfMissing
# The example settings use the default folders. Point them at a custom -Target / -RecordingsDir.
$defaultRoot = '%USERPROFILE%\Documents\TranscriptionSuite'
$set = Read-Source (Join-Path $repo 'config\suite.settings.example.psd1')
$setText = $set.Text.Replace("$defaultRoot\recordings", $RecordingsDir).Replace($defaultRoot, $Target)
Install-Text -Dest (Join-Path $Target 'suite.settings.psd1') -Text $setText -Bom $set.Bom -OnlyIfMissing
Install-File (Join-Path $repo 'config\.env.example')                (Join-Path $Target 'docker\.env')         -OnlyIfMissing

# 3. OBS profile and scene
if (Get-Process obs64 -ErrorAction SilentlyContinue) {
    Write-Warning 'OBS is running. It rewrites its profile on exit, so close OBS before a real install.'
}
$ini = Read-Source (Join-Path $repo 'obs\basic.ini.template')
$iniText = $ini.Text.Replace('@RECORDINGS_DIR@', $RecordingsDir.Replace('\', '/'))
Install-Text -Dest (Join-Path $ObsDir 'basic\profiles\TranscriptionSuite\basic.ini') -Text $iniText -Bom $ini.Bom
Install-File (Join-Path $repo 'obs\Teams Meeting Recording.json') (Join-Path $ObsDir 'basic\scenes\Teams Meeting Recording.json')

# 4. Login shortcut (opt-in)
$startupDest = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\TranscriptionSuite.vbs'
if ($InstallStartup) {
    Install-File (Join-Path $repo 'startup\TranscriptionSuite.vbs') $startupDest
} else {
    Write-Status SKIP $startupDest 'startup shortcut not requested; use -InstallStartup'
}

# Never-touched folders: just make sure they exist so the scripts can write to them.
foreach ($d in @($RecordingsDir, (Join-Path $Target 'logs'))) {
    if (-not (Test-Path -LiteralPath $d) -and $PSCmdlet.ShouldProcess($d, 'Create directory')) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
}

Write-Host ''
Write-Host ("Summary: {0} new, {1} updated, {2} unchanged, {3} kept, {4} skipped" -f `
    $counts.NEW, $counts.UPDATE, $counts.SAME, $counts.KEEP, $counts.SKIP)

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host 'Next steps:'
    Write-Host "  1. Edit $Target\suite.settings.psd1 and set TsToken (and TranscriptsDir if you want another folder)."
    Write-Host "  2. Edit $Target\docker\.env and set HUGGINGFACE_TOKEN."
    Write-Host '  3. Open OBS once, pick Profile > TranscriptionSuite and Scene Collection > Teams Meeting Recording (see obs\README.md).'
    Write-Host '  4. Start .\scripts\Start-TranscriptionSuite.ps1, or sign out and back in if you used -InstallStartup.'
    Write-Host '  An already-running watcher keeps using the old script until it is restarted.'
}
