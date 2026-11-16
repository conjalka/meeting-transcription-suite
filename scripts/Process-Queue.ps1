# Process-Queue.ps1
# Sequentially transcribes a list of recordings through TranscriptionSuite and exports Markdown.
# Fixes the old Process-Backlog skip bug: matches the TS recording by FILE NAME, not by the
# global is_busy flag, and shares the watcher's Local\TsUploadLock mutex.
# Usage: Process-Queue.ps1 -Files "2026-11-12 10-01-18.mp3","2026-11-11 10-00-29.mp3"
# Any parameter left out falls back to suite.settings.psd1 (see Import-SuiteSettings.ps1).
param(
    [Parameter(Mandatory)][string[]] $Files,
    [string] $RecDir,
    [string] $OutDir,
    [string] $LogFile,
    [string] $Server,
    [string] $Token
)
$ErrorActionPreference = "Continue"
. "$PSScriptRoot\Import-SuiteSettings.ps1"
$S = Get-SuiteSettings
if (-not $RecDir)  { $RecDir  = $S.RecordingsDir }
if (-not $OutDir)  { $OutDir  = $S.TranscriptsDir }
if (-not $LogFile) { $LogFile = Join-Path $S.LogDir "queue.log" }
if (-not $Server)  { $Server  = $S.TsServer }
if (-not $Token)   { $Token   = $S.TsToken }
New-Item -ItemType Directory -Force (Split-Path $LogFile), $OutDir | Out-Null
$H = @{ Authorization = "Bearer $Token" }
function Log($m, $l = "INFO") { Add-Content $LogFile "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') [$l] $m" -Encoding UTF8 }
function Get-Recs {
    $raw = Invoke-RestMethod "$Server/api/notebook/recordings" -Headers $H -TimeoutSec 30
    @(foreach ($r in $raw) { $r })
}
function Get-Cal($start, $end) {
    try {
        $ns = (New-Object -ComObject Outlook.Application).GetNamespace("MAPI")
        $items = $ns.GetDefaultFolder(9).Items
        $items.IncludeRecurrences = $true; $items.Sort("[Start]")
        $f = "[Start] <= `"$($end.AddMinutes(15).ToString('g'))`" AND [End] >= `"$($start.AddMinutes(-15).ToString('g'))`""
        $best = $null; $bd = [double]::MaxValue
        foreach ($e in $items.Restrict($f)) {
            if ($e.AllDayEvent) { continue }
            $d = [math]::Abs(($e.Start - $start).TotalSeconds)
            if ($d -lt $bd) { $bd = $d; $best = $e }
        }
        return $best
    } catch { Log "Calendar lookup failed: $_" "WARN"; return $null }
}

foreach ($name in $Files) {
    try {
        $path = Join-Path $RecDir $name
        if (-not (Test-Path $path)) { Log "Missing file: $name" "WARN"; continue }
        $file = Get-Item $path
        if ($file.Length -lt 2MB) { Log "Skipping tiny file: $name" "WARN"; continue }
        $recStart = [datetime]::ParseExact(($name -replace '\.mp3$',''), 'yyyy-MM-dd HH-mm-ss', $null)
        $recEnd   = $file.LastWriteTime

        $existing = Get-Recs | Where-Object { $_.filename -eq $name } | Sort-Object id -Descending | Select-Object -First 1
        if (-not $existing) {
            $mtx = New-Object System.Threading.Mutex($false, "Local\TsUploadLock")
            try { [void]$mtx.WaitOne() } catch [System.Threading.AbandonedMutexException] { }
            try {
                Add-Type -AssemblyName System.Net.Http
                $accepted = $false
                for ($attempt = 1; $attempt -le 20 -and -not $accepted; $attempt++) {
                    while ($true) {
                        try {
                            $s = Invoke-RestMethod "$Server/api/admin/status" -Headers $H -TimeoutSec 10
                            if (-not $s.models.job_tracker.is_busy) { break }
                        } catch { Log "Status check error: $_" "WARN" }
                        Start-Sleep 20
                    }
                    $client = New-Object System.Net.Http.HttpClient
                    $client.DefaultRequestHeaders.Add("Authorization", "Bearer $Token")
                    $client.Timeout = [TimeSpan]::FromMinutes(30)
                    $content = New-Object System.Net.Http.MultipartFormDataContent
                    $fs = [System.IO.File]::OpenRead($file.FullName)
                    $fc = New-Object System.Net.Http.StreamContent -ArgumentList $fs
                    $fc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("audio/mpeg")
                    $content.Add($fc, "file", $file.Name)
                    $content.Add((New-Object System.Net.Http.StringContent "en"), "language")
                    $content.Add((New-Object System.Net.Http.StringContent "1"), "enable_word_timestamps")
                    $content.Add((New-Object System.Net.Http.StringContent "1"), "enable_diarization")
                    Log "Uploading $name ($([math]::Round($file.Length/1MB,1)) MB), attempt $attempt"
                    $resp = $client.PostAsync("$Server/api/notebook/transcribe/upload", $content).Result
                    $fs.Dispose(); $client.Dispose()
                    if ($resp.IsSuccessStatusCode) {
                        $accepted = $true
                        Log "Upload accepted: $name"
                        # Hold the lock until TS reports busy, so the next job cannot see a false idle.
                        for ($w = 0; $w -lt 12; $w++) {
                            try {
                                $s = Invoke-RestMethod "$Server/api/admin/status" -Headers $H -TimeoutSec 10
                                if ($s.models.job_tracker.is_busy) { break }
                            } catch { }
                            Start-Sleep 5
                        }
                    } else {
                        Log "Upload rejected: HTTP $($resp.StatusCode) for $name - retrying" "WARN"
                        Start-Sleep 30
                    }
                }
                if (-not $accepted) { Log "Upload failed after retries: $name" "ERROR"; continue }
            } finally { try { $mtx.ReleaseMutex() } catch { } }

            $elapsed = 0
            while ($elapsed -lt 14400 -and -not $existing) {
                Start-Sleep 30; $elapsed += 30
                try { $existing = Get-Recs | Where-Object { $_.filename -eq $name } | Sort-Object id -Descending | Select-Object -First 1 }
                catch { Log "Poll error: $_" "WARN" }
            }
            if (-not $existing) { Log "Timed out waiting for $name" "ERROR"; continue }
        }
        Log "TS recording id=$($existing.id) words=$($existing.word_count) for $name"

        $md = Invoke-RestMethod "$Server/api/notebook/recordings/$($existing.id)/export?format=md" -Headers $H -TimeoutSec 60
        $mdText = if ($md -is [string]) { $md } else { $md | ConvertTo-Json -Depth 10 }
        $cal = Get-Cal $recStart $recEnd
        $base = if ($cal) { $cal.Subject } else { "Recovered " + $recStart.ToString("HH-mm-ss") }
        if ($cal) {
            $att = @($cal.Recipients | ForEach-Object { $_.Name }) -join ", "
            $hdr = "# $($cal.Subject)`n`n| | |`n|---|---|`n| **Date** | $($cal.Start.ToString('dddd, MMMM d, yyyy')) |`n| **Time** | $($cal.Start.ToString('h:mm tt')) - $($cal.End.ToString('h:mm tt')) |`n| **Organizer** | $($cal.Organizer) |`n| **Attendees** | $att |`n`n---`n`n"
            $mdText = $hdr + ($mdText -replace '^# [^\n]+\n+\*\*Date:\*\*[^\n]+\n+---\n+', '')
        }
        $safe = ($base -replace '[\\/:*?"<>|]', '_').Trim()
        $out = Join-Path $OutDir "$($recStart.ToString('yyyy-MM-dd'))_$safe.md"
        if (Test-Path $out) { $out = Join-Path $OutDir "$($recStart.ToString('yyyy-MM-dd'))_$safe ($($recStart.ToString('HH-mm'))).md" }
        [System.IO.File]::WriteAllText($out, $mdText, [System.Text.Encoding]::UTF8)
        Log "Saved: $out"
    } catch { Log "Error on ${name}: $_" "ERROR" }
}
Log "Queue finished"
