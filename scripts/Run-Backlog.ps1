# Run-Backlog.ps1
# Transcribes recordings that were missed (watcher not running, TS down, etc.).
# Hands the work to Process-Queue.ps1. Recordings already in TS are not uploaded again;
# their transcript is just re-exported.
#
# Usage:
#   Run-Backlog.ps1 -Files "2026-11-10 16-17-25.mp3","2026-11-10 14-33-13.mp3"
#   Run-Backlog.ps1 -Since "2026-11-01"        # every .mp3 modified on/after that date
param(
    [string[]] $Files,
    [datetime] $Since
)
. "$PSScriptRoot\Import-SuiteSettings.ps1"
$S = Get-SuiteSettings

if (-not $Files) {
    if (-not $Since) { throw "Specify -Files <names> or -Since <date>." }
    $Files = Get-ChildItem $S.RecordingsDir -Filter *.mp3 |
        Where-Object { $_.LastWriteTime -ge $Since } |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { $_.Name }
}
if (-not $Files) { Write-Host "No recordings matched."; return }

& "$PSScriptRoot\Process-Queue.ps1" -Files $Files
