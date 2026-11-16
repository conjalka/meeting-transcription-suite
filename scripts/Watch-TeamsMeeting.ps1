#Requires -Version 5.1
<#
.SYNOPSIS
    Teams Meeting Watcher - auto-records Teams calls with OBS and auto-transcribes with TranscriptionSuite.
.DESCRIPTION
    Polls the Windows microphone capability registry key for MSTeams.
    When Teams opens the mic (call starts): starts OBS recording.
    When Teams releases the mic (call ends): stops OBS, then fires a background job that
    uploads the recording to TranscriptionSuite, waits for transcription, and exports the
    diarized Markdown transcript to the configured transcripts folder.
    The main poll loop returns within ~25s of call end and is never blocked by transcription.
    Background job log lines are tagged [BG].
    Detection signal:
      HKCU:\...\CapabilityAccessManager\ConsentStore\microphone\MSTeams_8wekyb3d8bbwe
        LastUsedTimeStop = 0    -> mic open  -> IN CALL
        LastUsedTimeStop != 0   -> mic released -> NOT IN CALL
.NOTES
    Runs as a background process at login. Logs to:
      %USERPROFILE%\Documents\TranscriptionSuite\logs\watcher.log
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# --- Configuration -----------------------------------------------------------
# Server, token, paths and OBS settings come from suite.settings.psd1 (see
# config\suite.settings.example.psd1). The token can also come from $env:TS_TOKEN.
. "$PSScriptRoot\Import-SuiteSettings.ps1"
$SETTINGS = Get-SuiteSettings
$TS_SERVER      = $SETTINGS.TsServer
$TS_TOKEN       = $SETTINGS.TsToken
$OBS_EXE        = $SETTINGS.ObsExe
$OBS_SCENE      = $SETTINGS.ObsScene
$REC_DIR        = $SETTINGS.RecordingsDir
$LOG_FILE       = Join-Path $SETTINGS.LogDir "watcher.log"
$TRANSCRIPT_DIR = $SETTINGS.TranscriptsDir
$POLL_MS        = 3000
$STOP_DELAY     = 5
$FILE_WAIT      = 15
$MIC_ROOT = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"
$MIC_KEY  = "$MIC_ROOT\MSTeams_8wekyb3d8bbwe"
# Non-packaged apps that count as a call when they hold the mic: Zoom, and Chrome/Edge (Google Meet, web calls).
# Registry key names use '#' in place of '\' in the exe path.
$MIC_APP_PATTERN = '(?i)#(Zoom|chrome|msedge)\.exe$'
$MIN_CALL_SECS   = 90      # calls shorter than this are not uploaded (filters brief browser mic use)
$HEALTH_EVERY    = 300     # seconds between TranscriptionSuite health checks

# --- Single-instance guard ---------------------------------------------------
$myPid = $PID
Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.ProcessId -ne $myPid -and $_.CommandLine -like "*Watch-TeamsMeeting*"
} | ForEach-Object {
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO] Killing duplicate watcher PID $($_.ProcessId)"
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

# --- Helpers -----------------------------------------------------------------
function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts [$Level] $Msg"
    Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8
    Write-Host $line
}

function Test-TeamsInCall {
    try {
        $props = Get-ItemProperty $MIC_KEY -ErrorAction Stop
        return ($props.LastUsedTimeStop -eq 0)
    } catch { return $false }
}

function Test-OtherAppInCall {
    try {
        foreach ($k in (Get-ChildItem "$MIC_ROOT\NonPackaged" -ErrorAction Stop)) {
            if ($k.PSChildName -notmatch $MIC_APP_PATTERN) { continue }
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.PSObject.Properties['LastUsedTimeStop'] -and $p.LastUsedTimeStop -eq 0) { return $true }
        }
    } catch { }
    return $false
}

function Test-InCall {
    return ((Test-TeamsInCall) -or (Test-OtherAppInCall))
}

function Test-TsHealthy {
    try {
        Invoke-RestMethod "$TS_SERVER/health" -TimeoutSec 5 | Out-Null
        return $true
    } catch { return $false }
}

function Test-ObsRunning {
    return [bool](Get-Process obs64 -ErrorAction SilentlyContinue)
}

function Start-OBSRecording {
    Write-Log "Starting OBS recording..."
    if (-not (Test-ObsRunning)) {
        $sentinelDir = "$env:APPDATA\obs-studio\.sentinel"
        if (Test-Path $sentinelDir) {
            Get-ChildItem $sentinelDir -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared OBS sentinel files (prevents crash dialog on launch)"
        }
        Start-Process -FilePath $OBS_EXE `
            -WorkingDirectory (Split-Path $OBS_EXE) `
            -ArgumentList "--scene `"$OBS_SCENE`" --startrecording" `
            -WindowStyle Minimized
        Start-Sleep -Seconds 5
        Write-Log "OBS launched and recording started"
    } else {
        Write-Log "OBS already running - recording assumed in progress"
    }
}

function Get-LatestRecording {
    param([int]$WithinMinutes = 120)
    # Use Where-Object instead of -Include to avoid PS5.1 -Include/-Recurse quirk
    $cutoff = (Get-Date).AddMinutes(-$WithinMinutes)
    return Get-ChildItem $REC_DIR -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.mp3','.mp4','.mov','.mkv','.avi','.hybrid_mp4') `
                       -and $_.LastWriteTime -gt $cutoff } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Stop-OBSRecording {
    Write-Log "Call ended - waiting ${STOP_DELAY}s before stopping OBS (goodbye audio)..."
    Start-Sleep -Seconds $STOP_DELAY

    $obsProc = Get-Process obs64 -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $obsProc) {
        Write-Log "OBS process not found - may have already stopped" -Level "WARN"
    } else {
        Write-Log "Stopping OBS (PID $($obsProc.Id))..."
        $obsProc.CloseMainWindow() | Out-Null
        $waited = 0
        while (-not $obsProc.HasExited -and $waited -lt 8) {
            Start-Sleep -Seconds 2; $waited += 2
        }
        if (-not $obsProc.HasExited) {
            Write-Log "CloseMainWindow did not exit OBS - force killing (MP3/FFmpeg safe)"
            $obsProc | Stop-Process -Force
            Start-Sleep -Seconds 4
        } else {
            Write-Log "OBS exited cleanly after ${waited}s"
        }
    }

    $waited = 0
    while ($waited -lt $FILE_WAIT) {
        $f = Get-LatestRecording
        if ($f -and $f.Length -gt 0) {
            $locked = $true
            for ($i = 0; $i -lt 5; $i++) {
                try {
                    $fs = [System.IO.File]::Open($f.FullName,
                        [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read,
                        [System.IO.FileShare]::None)
                    $fs.Dispose(); $locked = $false; break
                } catch { Start-Sleep -Seconds 2 }
            }
            if ($locked) { Write-Log "Recording file still locked after 10s - proceeding anyway" -Level "WARN" }
            Write-Log "Recording file ready: $($f.Name) ($([math]::Round($f.Length/1MB,1)) MB)"
            return
        }
        Start-Sleep -Seconds 2; $waited += 2
    }
    Write-Log "Recording file not found after ${FILE_WAIT}s wait" -Level "WARN"
}

function Start-PostCallJob {
    param(
        [string]   $FilePath,
        [datetime] $RecStart,
        [string]   $TsServer,
        [string]   $TsToken,
        [string]   $TransDir,
        [string]   $LogPath
    )
    $jobName = "Transcribe_$(Get-Date -f HHmmss)"

    Start-Job -Name $jobName -ScriptBlock {
        param([string]$FilePath, [datetime]$RecStart, [string]$TsServer,
              [string]$TsToken, [string]$TransDir, [string]$LogPath)

        # Intentionally NOT dot-sourcing the parent script - that would re-run the config
        # block and overwrite our params with the hardcoded on-disk values.
        # We inline the minimal set of helpers needed; the rest we extract from the script.
        $TS_SERVER      = $TsServer
        $TS_TOKEN       = $TsToken
        $TRANSCRIPT_DIR = $TransDir
        $LOG_FILE       = $LogPath
        $ErrorActionPreference = "Continue"

        function Write-Log {
            param([string]$Msg, [string]$Level = "INFO")
            $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Add-Content -Path $LOG_FILE -Value "$ts [$Level] [BG] $Msg" -Encoding UTF8
        }

        try {
            $file   = Get-Item $FilePath -ErrorAction Stop
            $recEnd = Get-Date

            Add-Type -AssemblyName System.Net.Http
            $client = New-Object System.Net.Http.HttpClient
            $client.DefaultRequestHeaders.Add("Authorization", "Bearer $TS_TOKEN")
            $client.Timeout = [TimeSpan]::FromMinutes(30)
            $content     = New-Object System.Net.Http.MultipartFormDataContent
            $fileStream  = [System.IO.File]::OpenRead($file.FullName)
            $fileContent = New-Object System.Net.Http.StreamContent -ArgumentList $fileStream
            $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("audio/mpeg")
            $content.Add($fileContent, "file", $file.Name)
            $content.Add((New-Object System.Net.Http.StringContent "en"), "language")
            $content.Add((New-Object System.Net.Http.StringContent "1"),  "enable_word_timestamps")
            $content.Add((New-Object System.Net.Http.StringContent "1"),  "enable_diarization")

            # One upload at a time across all background jobs (TS is single-job). Without
            # this, two queued jobs both see TS go idle and one gets HTTP 409 and is lost.
            $mtx = New-Object System.Threading.Mutex($false, "Local\TsUploadLock")
            try { [void]$mtx.WaitOne() } catch [System.Threading.AbandonedMutexException] { }

            # Wait for TS to be idle before uploading - avoids HTTP 409 Conflict
            # when the backlog batch or another job is still running
            $waitIdle = 0; $maxIdle = 12 * 60 * 60
            while ($waitIdle -lt $maxIdle) {
                try {
                    $chk = Invoke-RestMethod "$TS_SERVER/api/admin/status" -Headers @{Authorization="Bearer $TS_TOKEN"} -TimeoutSec 10
                    if (-not $chk.models.job_tracker.is_busy) { break }
                    Write-Log "TS busy - waiting before upload... ($([math]::Round($waitIdle/60,1)) min)"
                } catch { Write-Log "TS status check error: $_" -Level "WARN" }
                Start-Sleep 20; $waitIdle += 20
            }
            if ($waitIdle -ge $maxIdle) { Write-Log "Timed out waiting for TS to become idle" -Level "WARN"; return }

            Write-Log "Uploading: $($file.Name) ($([math]::Round($file.Length/1MB,1)) MB)"
            $response = $client.PostAsync("$TS_SERVER/api/notebook/transcribe/upload", $content).Result
            $body     = $response.Content.ReadAsStringAsync().Result | ConvertFrom-Json
            $fileStream.Dispose(); $client.Dispose()

            if (-not $response.IsSuccessStatusCode) {
                Write-Log "Upload failed: HTTP $($response.StatusCode)" -Level "ERROR"; return
            }
            $tsJobId = $body.job_id
            Write-Log "Upload accepted - job ID: $tsJobId"

            # Wait for OUR recording to appear in TS (matched by file name). Do not poll the
            # global is_busy flag: when another queued job grabs the slot the instant ours
            # finishes, is_busy never reads false and the export is skipped.
            $maxWait = 240 * 60; $elapsed = 0; $pollSec = 15; $newest = $null
            while ($elapsed -lt $maxWait -and -not $newest) {
                Start-Sleep -Seconds $pollSec; $elapsed += $pollSec
                try {
                    $rawRecs = Invoke-RestMethod "$TS_SERVER/api/notebook/recordings" `
                        -Headers @{Authorization="Bearer $TS_TOKEN"} -TimeoutSec 20
                    # Inside Start-Job, @() wraps a deserialized array as a 1-element object.
                    # Unwrap a .value property first, then force a true array via foreach.
                    if ($rawRecs.PSObject.Properties['value']) { $rawRecs = $rawRecs.value }
                    $recs = @(foreach ($r in $rawRecs) { $r })
                    $newest = $recs | Where-Object { $_.filename -eq $file.Name } |
                              Sort-Object id -Descending | Select-Object -First 1
                    if ($newest) {
                        Write-Log "Transcription complete ($([math]::Round($elapsed/60,1)) min)"
                    } elseif ($elapsed % 120 -eq 0) {
                        Write-Log "Still transcribing... ($([math]::Round($elapsed/60,1)) min)"
                    }
                } catch { Write-Log "Recording poll error: $_" -Level "WARN" }
            }
            if (-not $newest) { Write-Log "Transcription timed out" -Level "WARN"; return }
            Write-Log "Exporting recording id=$($newest.id) '$($newest.title)' words=$($newest.word_count) diarized=$($newest.has_diarization)"

            # Export
            $md = Invoke-RestMethod "$TS_SERVER/api/notebook/recordings/$($newest.id)/export?format=md" `
                -Headers @{Authorization="Bearer $TS_TOKEN"} -TimeoutSec 30
            $mdText = if ($md -is [string]) { $md } else { $md | ConvertTo-Json -Depth 10 }

            # Calendar annotation - inline Outlook COM lookup (Get-CalendarEvent was never defined)
            $calEvent = $null
            try {
                $outlook  = New-Object -ComObject Outlook.Application -ErrorAction Stop
                $ns       = $outlook.GetNamespace("MAPI")
                $calendar = $ns.GetDefaultFolder(9)  # olFolderCalendar = 9
                $items    = $calendar.Items
                $items.IncludeRecurrences = $true
                $items.Sort("[Start]")
                $filter = "[Start] <= `"$($recEnd.AddMinutes(15).ToString('g'))`" AND [End] >= `"$($RecStart.AddMinutes(-15).ToString('g'))`""
                $restricted = $items.Restrict($filter)
                # Prefer timed events over all-day; among timed events pick the one whose
                # start time is closest to RecStart (i.e. the meeting that most likely just
                # started when recording began). Use overlap as a tiebreaker only.
                $bestEvent = $null
                $bestStartDelta = [TimeSpan]::MaxValue
                $bestOverlap    = [TimeSpan]::Zero
                foreach ($evt in $restricted) {
                    if ($evt.AllDayEvent) { continue }
                    $overlapStart = if ($evt.Start -gt $RecStart) { $evt.Start } else { $RecStart }
                    $overlapEnd   = if ($evt.End   -lt $recEnd)   { $evt.End }   else { $recEnd }
                    if ($overlapEnd -gt $overlapStart) {
                        $overlap     = $overlapEnd - $overlapStart
                        $startDelta  = [math]::Abs(($evt.Start - $RecStart).TotalSeconds)
                        $startDeltaTS = [TimeSpan]::FromSeconds($startDelta)
                        if ($startDeltaTS -lt $bestStartDelta -or
                            ($startDeltaTS -eq $bestStartDelta -and $overlap -gt $bestOverlap)) {
                            $bestStartDelta = $startDeltaTS
                            $bestOverlap    = $overlap
                            $bestEvent      = $evt
                        }
                    }
                }
                # Fall back to all-day events if no timed overlap found
                if (-not $bestEvent) {
                    foreach ($evt in $restricted) {
                        if ($evt.AllDayEvent) { $bestEvent = $evt; break }
                    }
                }
                $calEvent = $bestEvent
            } catch {
                Write-Log "Outlook calendar lookup failed: $_" -Level "WARN"
            }
            if ($calEvent) {
                $attendeeNames = @($calEvent.Recipients | ForEach-Object { $_.Name }) -join ", "
                $header  = "# $($calEvent.Subject)`n`n"
                $header += "| | |`n|---|---|`n"
                $header += "| **Date** | $($calEvent.Start.ToString('dddd, MMMM d, yyyy')) |`n"
                $header += "| **Time** | $($calEvent.Start.ToString('h:mm tt')) - $($calEvent.End.ToString('h:mm tt')) |`n"
                $header += "| **Organizer** | $($calEvent.Organizer) |`n"
                $header += "| **Attendees** | $attendeeNames |`n`n---`n`n"
                $mdText = $header + ($mdText -replace '^# [^\n]+\n+\*\*Date:\*\*[^\n]+\n+---\n+', '')
                Write-Log "Calendar match: '$($calEvent.Subject)' ($attendeeNames)"
            } else {
                Write-Log "No calendar event found overlapping recording window" -Level "WARN"
            }

            $dateStr  = $RecStart.ToString("yyyy-MM-dd")
            $baseName = if ($calEvent) { $calEvent.Subject } else { $newest.title }
            $safeName = ($baseName -replace '[\\/:*?"<>|]', '_').Trim()
            $outFile  = Join-Path $TRANSCRIPT_DIR "${dateStr}_${safeName}.md"
            New-Item -ItemType Directory -Force $TRANSCRIPT_DIR | Out-Null
            [System.IO.File]::WriteAllText($outFile, $mdText, [System.Text.Encoding]::UTF8)
            Write-Log "Transcript saved: $outFile"
        } catch {
            Write-Log "Background job error: $_" -Level "ERROR"
        } finally {
            try { if ($mtx) { $mtx.ReleaseMutex() } } catch { }
        }
    } -ArgumentList $FilePath, $RecStart, $TsServer, $TsToken, $TransDir, $LogPath | Out-Null

    Write-Log "Background transcription job '$jobName' started for: $(Split-Path $FilePath -Leaf)"
}

# --- Main loop ---------------------------------------------------------------
New-Item -ItemType Directory -Force (Split-Path $LOG_FILE) | Out-Null
Write-Log "Teams Meeting Watcher started (poll interval: ${POLL_MS}ms)"
Write-Log "TranscriptionSuite: $TS_SERVER"
Write-Log "Recordings dir: $REC_DIR"
Write-Log "Transcript dir: $TRANSCRIPT_DIR"

$inCall       = Test-InCall
$wasInCall    = $inCall
$handledStart = $inCall
$handledEnd   = -not $inCall
$callStart    = $null
$lastHealth   = Get-Date
$tsDown       = $false
$tsFails      = 0
Write-Log "Initial state: $(if ($inCall) { 'IN CALL' } else { 'not in call' })"

if ($inCall) {
    Write-Log "Started mid-call - ensuring OBS is recording..."
    try { Start-OBSRecording } catch { Write-Log "Failed to start OBS on startup: $_" -Level "ERROR" }
}

while ($true) {
    try {
        $inCall = Test-InCall

        # Periodic TranscriptionSuite health check; alert once per outage.
        if (((Get-Date) - $lastHealth).TotalSeconds -ge $HEALTH_EVERY) {
            $lastHealth = Get-Date
            if (Test-TsHealthy) {
                if ($tsDown) { Write-Log "TranscriptionSuite is responding again" }
                $tsDown = $false; $tsFails = 0
            } else {
                $tsFails++
                if ($tsFails -ge 2 -and -not $tsDown) {
                    $tsDown = $true
                    Write-Log "TranscriptionSuite is NOT responding ($TS_SERVER). Recordings will queue but not transcribe. Check Docker Desktop / WSL." -Level "ERROR"
                    try { & msg.exe $env:USERNAME /TIME:0 "Meeting transcription is DOWN: TranscriptionSuite is not responding. Recordings will not be transcribed until Docker Desktop/WSL is fixed." } catch { }
                }
            }
        }

        # NOT in call -> IN call
        if ($inCall -and -not $wasInCall -and -not $handledStart) {
            $handledStart = $true
            $handledEnd   = $false
            $callStart    = Get-Date
            Write-Log "*** CALL STARTED - starting OBS recording ***"
            try { Start-OBSRecording } catch { Write-Log "Failed to start OBS: $_" -Level "ERROR" }
        }

        # IN call -> NOT in call
        elseif (-not $inCall -and $wasInCall -and -not $handledEnd) {
            $handledEnd   = $true
            $handledStart = $false
            Write-Log "*** CALL ENDED - stopping recording ***"
            try {
                Stop-OBSRecording
                $recordingFile = Get-LatestRecording
                if ($recordingFile) {
                    Write-Log "Found recording: $($recordingFile.FullName)"
                    if ($recordingFile.Length -lt 10240) {
                        Write-Log "Recording $($recordingFile.Length) bytes - too small, skipping upload" -Level "WARN"
                    } elseif ($callStart -and ((Get-Date) - $callStart).TotalSeconds -lt $MIN_CALL_SECS) {
                        Write-Log "Call under ${MIN_CALL_SECS}s - skipping upload (likely brief mic use)" -Level "WARN"
                    } else {
                        # Use callStart if set; otherwise fall back to file creation time
                        # (callStart is null when watcher started mid-call)
                        $effectiveStart = if ($callStart) { $callStart } else {
                            Write-Log "callStart not set (mid-call startup) - using file creation time" -Level "WARN"
                            $recordingFile.CreationTime
                        }
                        Start-PostCallJob `
                            -FilePath   $recordingFile.FullName `
                            -RecStart   $effectiveStart `
                            -TsServer   $TS_SERVER `
                            -TsToken    $TS_TOKEN `
                            -TransDir   $TRANSCRIPT_DIR `
                            -LogPath    $LOG_FILE
                    }
                } else {
                    Write-Log "No recording file found in $REC_DIR" -Level "WARN"
                }
            } catch {
                Write-Log "Post-call processing error: $_" -Level "ERROR"
            }
        }

        $wasInCall = $inCall
    } catch {
        Write-Log "Unexpected error in main loop: $_" -Level "ERROR"
    }
    Start-Sleep -Milliseconds $POLL_MS
}