# Meeting Transcription System - Engineering Notes (historical handoff)

> Originally written as a hand-off note for the author's own setup, then extended through 2026-11-12.
> It is kept as a development log: what was built, what broke, and why. Tokens, passwords, personal
> names, meeting titles and absolute user paths have been removed or replaced with placeholders.
> For current install and usage instructions see the [README](../README.md) and [SETUP.md](SETUP.md).

---

## What This System Does

Automatically records every Microsoft Teams meeting using OBS, transcribes it locally with Whisper large-v3 + PyAnnote speaker diarization, and saves a Markdown transcript to a transcripts folder (default shown below; configurable in `suite.settings.psd1`):

```
%USERPROFILE%\Documents\TranscriptionSuite\transcripts\
```

**All processing is local — no cloud APIs, no bots joining meetings.**

---

## Hardware

Reference machine: Dell Pro 14 Premium — Intel Core Ultra 7 268V / Arc 140V / 32 GB RAM / Windows 11 Enterprise.
Whisper runs on CPU (no GPU offload configured).

---

## Architecture

```
Teams mic registry (HKCU:\..\MSTeams_8wekyb3d8bbwe)
        ↓ poll every 3s
Watch-TeamsMeeting.ps1  (PowerShell watcher daemon)
        ↓ call start → clear OBS sentinel files → launch OBS
OBS Studio  (audio capture → MP3 to recordings/)
        ↓ call end → force-stop OBS → background job (Start-Job)
Start-PostCallJob background job
   └── upload MP3 to TranscriptionSuite
   └── poll until transcription complete
   └── export Markdown from TS
   └── look up Outlook calendar event → prepend header
   └── save to transcripts/YYYY-MM-DD_<Meeting Subject>.md
TranscriptionSuite  (Docker, localhost:9786)
   └── Whisper large-v3 (CPU, int8)
   └── PyAnnote speaker-diarization-3.1
```

**Detection signal:** Teams sets `LastUsedTimeStop = 0` in the registry while the mic is open (in a call). The watcher polls this every 3 seconds.

---

## File Locations

| File | Path |
|---|---|
| Watcher script | `%USERPROFILE%\Documents\TranscriptionSuite\scripts\Watch-TeamsMeeting.ps1` |
| Launcher script | `%USERPROFILE%\Documents\TranscriptionSuite\scripts\Start-TranscriptionSuite.ps1` |
| Watcher log | `%USERPROFILE%\Documents\TranscriptionSuite\logs\watcher.log` |
| Recordings output | `%USERPROFILE%\Documents\TranscriptionSuite\recordings\` |
| Transcript output | `%USERPROFILE%\Documents\TranscriptionSuite\transcripts\` |
| OBS profile config | `%APPDATA%\obs-studio\basic\profiles\TranscriptionSuite\basic.ini` |
| OBS scene | `%APPDATA%\obs-studio\basic\scenes\Teams Meeting Recording.json` |
| OBS global config | `%APPDATA%\obs-studio\global.ini` |
| OBS sentinel dir | `%APPDATA%\obs-studio\.sentinel\` — cleared before every OBS launch |
| Docker env | `%USERPROFILE%\Documents\TranscriptionSuite\docker\.env` |
| TS config | `%USERPROFILE%\Documents\TranscriptionSuite\config.yaml` |
| Login auto-start | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\TranscriptionSuite.vbs` |

---

## Service Details

### TranscriptionSuite (Docker)
- URL: `http://localhost:9786`
- Admin token: `<TS_TOKEN>`
- Model: `Systran/faster-whisper-large-v3`, CPU, int8
- Diarization: `pyannote/speaker-diarization-3.1` (enabled, HuggingFace licenses accepted)
- Status check: `GET /api/admin/status`
- **API response shape:** `GET /api/notebook/recordings` returns a **`{value:[...]}`** wrapped object (not a bare array). The watcher handles both shapes via a type-check guard.

### OBS Studio
- Executable: `C:\Program Files\obs-studio\bin\64bit\obs64.exe`
- **Must be launched with `-WorkingDirectory "C:\Program Files\obs-studio\bin\64bit"`** — without it OBS throws "Failed to find locale/en-US.ini" and exits silently.
- Profile: `TranscriptionSuite`
- Scene collection: `Teams Meeting Recording`
- Scene: `Teams Meeting` — two audio sources: Desktop Audio (`wasapi_output_capture`) + Mic/Aux (`wasapi_input_capture`), both on default device, no video sources
- Output: **Advanced mode, Custom FFmpeg, audio-only MP3 (`libmp3lame`, 160 kbps)**
  - A 27-minute meeting produces ~30 MB
- `global.ini` must have `CurrentProfile=TranscriptionSuite` and `CurrentSceneCollection=Teams Meeting Recording`
- **Sentinel files:** Watcher clears all files in `%APPDATA%\obs-studio\.sentinel\` before every OBS launch to prevent the "Crash or unclean shutdown" dialog that blocks recording.

### OBS WebSocket
- Port 4455, password `<OBS_WEBSOCKET_PASSWORD>`, currently **enabled**
- Note: PowerShell 5.1 on this machine cannot load `System.Net.WebSockets.Client` — WebSocket-based stop was abandoned. The watcher uses `CloseMainWindow` with an 8-second wait then force-kill.

---

## Update 2026-11-11

- Transcripts stopped after 10/30 because TS became overloaded, then WSL hung. OBS recording was never broken.
- Recovered the 11/11 Zoom meeting by hand and exported two 10/30 recordings that TS had finished (named `<date>_Recovered ...`).
- Backlog from 10/30 to 11/11 (about 35 MP3s in `recordings\`) still needs upload. Each long meeting takes 60 to 150 minutes on CPU, almost all of it diarization. Run them one at a time.
- Watcher script patched (Zoom/Chrome/Edge detection, 90 second minimum, TS health alert). Running on the new code since 16:09.
- 2026-11-12: a finished transcript was skipped (09:01 meeting). The job waited for TS `is_busy` to read false, but a queued job grabbed the slot first. Fixed in the script (not live until the watcher restarts): each job now waits for its own recording by file name, uploads are serialized with a mutex, and the idle wait is 12 hours (was 2). Restart the watcher only when the queue is empty.
- 2026-11-12: speed. Diarization runs on one CPU thread (about 90% of one core) while the other 7 cores sit idle; Whisper itself uses all cores and is the smaller share. TS accepts one job at a time. A second container would help, but RAM is tight (Chrome about 11 GB, each TS container about 9 GB while working). Decision: stay with one container for now.
- 2026-11-12: added `%USERPROFILE%\.wslconfig` with `autoMemoryReclaim=gradual` so WSL returns idle memory to Windows. It applies after the next `wsl --shutdown` or reboot.
- 2026-11-12 (evening): the fixed watcher is now live. Restarted at 21:58 with no call or TS job running. It matches its recording by file name, serializes uploads with the `Local\TsUploadLock` mutex, and waits up to 12 hours for TS to go idle.
- 2026-11-12: a backlog job stalled at 649 of 812 and ignored `POST /api/transcribe/cancel`. `docker restart transcriptionsuite-container` cleared it (about 5 to 10 minutes; wrap the docker call in `Start-Job`). The container restart also kills any queued script, so check `queue.log` afterward.
- 2026-11-12: new helper `scripts\Process-Queue.ps1 -Files "<name>.mp3",...` runs recordings one at a time. It matches by file name, skips files under 2 MB, retries on HTTP 409, names each transcript from the Outlook calendar, and logs to `logs\queue.log`. `scripts\Run-Backlog.ps1` is a thin wrapper that calls it for a list of files or everything since a date, newest first. It replaces `Process-Backlog.ps1` and `Process-Catchup.ps1`, which have the `is_busy` skip bug.
- 2026-11-12: the calendar title can be wrong when two meetings overlap (a 10:01 recording was tagged with the title of an overlapping call). Check the first lines of each transcript.
- Do not stop a script by matching "Run-Backlog" or "Watch-Teams" in a command that itself contains that text. The command line matches itself and the shell exits with code 4294967295.



## Current Status (as of 2026-10-05; see the 2026-11-11 update above)

| Component | Status |
|---|---|
| TranscriptionSuite Docker stack | ✅ Running |
| Watcher daemon | ✅ Running (restarted on fixed script 2026-10-05) |
| OBS profile (MP3 audio-only) | ✅ Configured |
| Sentinel file cleanup | ✅ Fixed |
| 0-byte upload guard | ✅ Fixed |
| Calendar all-day event priority | ✅ Fixed |
| `$callStart` StrictMode bug | ✅ Fixed — `$callStart = $null` initialized before main loop |
| **`Start-PostCallJob` export (9/22)** | ✅ **FIXED 2026-09-22** — removed `Invoke-Expression $funcBlock`; inlined Outlook COM calendar lookup. |
| **`Start-Job` array deserialization bug** | ✅ **FIXED 2026-10-05** — `@(Invoke-RestMethod ...)` inside `Start-Job` wrapped the deserialized array as a 1-element object; `.id` on the wrapper returned all IDs space-joined, causing every export to fail with HTTP 422 since 2026-09-23. Fixed by replacing `@(Invoke-RestMethod...)` + `if (-not ($recs -is [System.Array]))` with explicit `foreach` unpack. See fix section below. |
| End-to-end recording → transcript | ✅ Fixed |
| Speaker diarization | ✅ Working (TS side) |
| Backlog processing | ✅ Complete (21 recordings processed 2026-09-22) |
| **Transcripts since 9/24** | ⚠️ All recordings from 2026-09-23 onward transcribed correctly by TS but NOT exported due to the array bug above. Backlog of ~30+ unexported recordings sits in TS. Manual export needed — see section below. |

---

## Fix Applied 2026-10-05: `Start-Job` Array Deserialization Bug

**Root cause confirmed:** Since 2026-09-23, every background export job failed with:
```
HTTP 422: {"detail":[{"type":"int_parsing","loc":["path","recording_id"],"msg":"Input should be a valid integer, unable to parse string as an integer","input":"26 25 24 23 22 ..."}]}
```

Inside `Start-Job`, PowerShell serializes/deserializes arguments and return values. `@(Invoke-RestMethod ...)` when the API returns a bare JSON array is deserialized as a single `Deserialized.System.Object[]` wrapper — so `@($that)` creates a **1-element array containing the whole collection**. `Sort-Object id -Descending` then operates on that single wrapper object, `Select-Object -First 1` returns the wrapper, and `$wrapper.id` expands all child `.id` values as a space-joined string (e.g. `"26 25 24 23..."`). That string is then interpolated into the export URL, causing HTTP 422 on every call.

This was triggered by the growth of the TS recordings database past the point where the `{value:[...]}` guard was needed — the API switched to a bare array response as the count grew, and the `@()` wrapping broke inside `Start-Job`.

**Fix applied (lines 233–239 of `Watch-TeamsMeeting.ps1`):**
- Replaced: `$recs = @(Invoke-RestMethod ...)`  + the `if (-not ($recs -is [System.Array]))` block
- With: call without `@()`, unwrap `.value` if present, then force a true array via `@(foreach ($r in $rawRecs) { $r })` — `foreach` enumerates the deserialized collection element-by-element, yielding real scalar objects.

**Verified:** Tested inside `Start-Job` — `$newest.id` now returns `Int32 '53'` instead of `Object[] '53 52 51...'`.

---

## Fix Applied 2026-09-22: `Start-PostCallJob`

**Root cause confirmed:** The `Invoke-Expression $funcBlock` try/catch block inside the `Start-Job -ScriptBlock {}` corrupted PowerShell string escaping at runtime, causing every background job to fail with "Failed to load helper functions from script: At line:145 char:76".

**Fix applied:**
1. Removed the entire `try { $src = ... Invoke-Expression $funcBlock } catch { ... return }` block (18 lines)
2. Inlined the Outlook COM calendar lookup directly in the job — replacing the call to `Get-CalendarEvent` which was never defined in the script
3. Removed `$ScriptPath` parameter from `Start-PostCallJob`, the `Start-Job` param block, and the `-ArgumentList` list since it is no longer needed
4. Watcher restarted on the fixed script — confirmed clean startup in `watcher.log`

The calendar logic now lives entirely inside the `Start-Job` scriptblock: opens the default Outlook calendar via COM, restricts to items overlapping `[RecStart-15min, recEnd+15min]`, prefers timed events over all-day (best overlap wins), falls back to all-day if no timed match.


## How to Check If It's Working Right Now

```powershell
# 1. Is the watcher running?
Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*Watch-TeamsMeeting*" } |
    Select-Object ProcessId

# 2. What does the log say?
Get-Content "$env:USERPROFILE\Documents\TranscriptionSuite\logs\watcher.log" -Tail 30

# 3. Is OBS running?
Get-Process obs64 -ErrorAction SilentlyContinue

# 4. Is TranscriptionSuite up?
Invoke-RestMethod "http://localhost:9786/api/admin/status" `
    -Headers @{Authorization="Bearer <TS_TOKEN>"}

# 5. What recordings exist?
Get-ChildItem "$env:USERPROFILE\Documents\TranscriptionSuite\recordings" |
    Sort-Object LastWriteTime -Descending | Format-Table Name, Length, LastWriteTime

# 6. What transcripts exist?
Get-ChildItem "%USERPROFILE%\Documents\TranscriptionSuite\transcripts"
```

---

## How to Manually Export a Recording Already in TranscriptionSuite

```powershell
$TS_SERVER = "http://localhost:9786"
$TS_TOKEN  = "<TS_TOKEN>"
$TRANSCRIPT_DIR = "%USERPROFILE%\Documents\TranscriptionSuite\transcripts"
$ID = 16   # change this

$rec    = Invoke-RestMethod "$TS_SERVER/api/notebook/recordings/$ID" -Headers @{Authorization="Bearer $TS_TOKEN"}
$md     = Invoke-RestMethod "$TS_SERVER/api/notebook/recordings/$ID/export?format=md" -Headers @{Authorization="Bearer $TS_TOKEN"} -TimeoutSec 30
$mdText = if ($md -is [string]) { $md } else { $md | ConvertTo-Json -Depth 10 }

$dateStr  = ([datetime]$rec.recorded_at).ToString("yyyy-MM-dd")
$safeName = ($rec.title -replace '[\\/:*?"<>|]', '_').Trim()
$outFile  = Join-Path $TRANSCRIPT_DIR "${dateStr}_${safeName}.md"
[System.IO.File]::WriteAllText($outFile, $mdText, [System.Text.Encoding]::UTF8)
Write-Host "Saved: $outFile"
```

---

## How to Manually Upload and Transcribe a Recording

```powershell
$TS_SERVER = "http://localhost:9786"
$TS_TOKEN  = "<TS_TOKEN>"
$file      = Get-Item "%USERPROFILE%\Documents\TranscriptionSuite\recordings\<filename>"

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

$response = $client.PostAsync("$TS_SERVER/api/notebook/transcribe/upload", $content).Result
$fileStream.Dispose(); $client.Dispose()
$response.Content.ReadAsStringAsync().Result  # prints {"job_id":"..."}
```

Then poll and export:

```powershell
# Poll until done
do {
    Start-Sleep 15
    $s = Invoke-RestMethod "http://localhost:9786/api/admin/status" -Headers @{Authorization="Bearer <TS_TOKEN>"}
    Write-Host "busy: $($s.models.job_tracker.is_busy)"
} while ($s.models.job_tracker.is_busy)

# Export most recent recording
$recs    = Invoke-RestMethod "http://localhost:9786/api/notebook/recordings" -Headers @{Authorization="Bearer <TS_TOKEN>"}
$list    = if ($recs -is [System.Array]) { $recs } else { $recs.value }
$rec     = $list | Sort-Object id -Descending | Select-Object -First 1
$md      = Invoke-RestMethod "http://localhost:9786/api/notebook/recordings/$($rec.id)/export?format=md" `
               -Headers @{Authorization="Bearer <TS_TOKEN>"}
$mdText  = if ($md -is [string]) { $md } else { $md | ConvertTo-Json -Depth 10 }
$outFile = "%USERPROFILE%\Documents\TranscriptionSuite\transcripts\$(Get-Date -f yyyy-MM-dd)_$($rec.title).md"
[System.IO.File]::WriteAllText($outFile, $mdText, [System.Text.Encoding]::UTF8)
Write-Host "Saved: $outFile"
```

---

## How to Restart the Watcher

```powershell
$myPid = $PID
Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*Watch-TeamsMeeting*" -and $_.ProcessId -ne $myPid } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }

Start-Process powershell.exe `
    -ArgumentList '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "%USERPROFILE%\Documents\TranscriptionSuite\scripts\Watch-TeamsMeeting.ps1"' `
    -WindowStyle Hidden
```

---

## Known Issues / History of Root Causes Fixed

| Issue | Root Cause | Fix Applied |
|---|---|---|
| OBS crashed on every launch | Missing `-WorkingDirectory` | Added `-WorkingDirectory (Split-Path $OBS_EXE)` |
| OBS loaded blank "Untitled" profile | `global.ini` missing `CurrentProfile` / `CurrentSceneCollection` | Added both entries |
| Every recording was 7–34 seconds | AVI/MKV only flushed buffer on force-kill | Switched to `hybrid_mp4`, then audio-only MP3 |
| `--stoprecording` CLI flag didn't work | OBS 30+ spawns new instance for CLI flags | Replaced with `CloseMainWindow()` / force-kill |
| Multiple watcher instances | No deduplication on restart | Single-instance guard at startup |
| Watcher started mid-call, didn't launch OBS | `$handledStart = $inCall` skipped launch | Added mid-call startup check |
| `CloseMainWindow` always failed | OBS minimized to tray / shows confirmation dialog during recording | Removed `--minimize-to-tray`; 8s wait then force-kill |
| WebSocket stop failed | `System.Net.WebSockets.Client` not available in PS 5.1 | Abandoned; force-kill sufficient |
| Export failed with "property 'value' not found" | StrictMode + bare array response from TS | Type-check guard: `if ($recs -is [System.Array])` |
| OBS showed crash dialog on every launch | Leftover `.sentinel\run_*` files from force-kills | Watcher clears `.sentinel\` before every launch |
| 0-byte files uploaded | No size guard | Skip upload if `$File.Length -lt 10240` |
| Calendar matched all-day OOO event | `Restrict` called on wrong `$items`; all-day events sorted before timed ones | Call `Restrict` on configured `$items`; prefer timed over all-day |
| Watcher blocked on transcription | `Wait-ForTranscription` ran in main loop | Moved to `Start-Job` background job |
| `$callStart` not set on mid-call restart | Variable never initialized before main loop | Added `$callStart = $null` before main loop |
| **Background job export always fails** | `Invoke-Expression $funcBlock` inside job — the `Write-Log` stripping regex is corrupted at runtime inside a `Start-Job` scriptblock. Every job since 9/14 logged "Failed to load helper functions from script: At line:145 char:76" and returned early without exporting. | **FIXED 2026-09-22** — removed the entire `Invoke-Expression` block; inlined Outlook COM calendar lookup directly in the job scriptblock; removed `$ScriptPath` param. |
| **No transcripts saved since 2026-09-23** | `@(Invoke-RestMethod ...)` inside `Start-Job` wraps the deserialized array as a 1-element object; `$recs.id` returns all IDs space-joined; every export hits HTTP 422 "Input should be a valid integer". Transcription itself worked fine — all recordings landed in TS. | **FIXED 2026-10-05** — replaced `@(Invoke-RestMethod ...)` + type-check guard with `foreach`-based unpack: `$recs = @(foreach ($r in $rawRecs) { $r })`. Watcher restarted. |

---

## HuggingFace Licenses

Both model licenses accepted under the HuggingFace account associated with the token in `docker/.env`:
- `pyannote/speaker-diarization-3.1`
- `pyannote/speaker-diarization-community-1` (sub-component)

Token stored in `%USERPROFILE%\Documents\TranscriptionSuite\docker\.env` as `HUGGINGFACE_TOKEN=...`.
