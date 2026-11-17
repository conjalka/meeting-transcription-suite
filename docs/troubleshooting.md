# Troubleshooting

Start with the logs in `%USERPROFILE%\Documents\TranscriptionSuite\logs\` (`watcher.log`, `queue.log`, `launcher.log`). Background-job lines in `watcher.log` are tagged `[BG]`.

## Quick diagnosis

| Symptom | Likely cause | Fix |
|---|---|---|
| OBS opens a blank "Untitled" profile, nothing records | `global.ini` does not select the profile and scene collection | Select **TranscriptionSuite** and **Teams Meeting Recording** in OBS once, or set `CurrentProfile` and `CurrentSceneCollection` (see `obs/README.md`). |
| OBS exits immediately, or "Failed to find locale/en-US.ini" | OBS launched without its working directory | The watcher launches it with `-WorkingDirectory` set to the OBS `bin\64bit` folder. If you start OBS yourself from a script, do the same. |
| OBS shows "Crash or unclean shutdown" and recording never starts | Leftover `.sentinel\run_*` files, because OBS is force-closed after each call | The watcher clears `%APPDATA%\obs-studio\.sentinel\` before every launch. If it still appears, check that the watcher is the version in this repo. |
| Recordings are only seconds long | Container formats such as AVI/MKV lose the buffer on force-close | The OBS profile uses audio-only MP3 (libmp3lame, 160 kbps), which survives it. Do not change the output format. |
| No call detected | App does not register as a mic user, or an old Teams client | The watcher watches `MSTeams_8wekyb3d8bbwe`, Zoom, Chrome and Edge. Check with the registry commands in the engineering notes, and adjust `$MIC_APP_PATTERN` in `Watch-TeamsMeeting.ps1`. |
| Short mic use in a browser is ignored | Calls under 90 seconds are not uploaded | Intended. Change `$MIN_CALL_SECS` if you want. |
| Two watchers running | Started twice | A single-instance guard exits the second. If in doubt, stop all watcher processes and start one (see SETUP). |
| Pop-up: "Meeting transcription is DOWN" | TranscriptionSuite failed two health checks in a row | Open Docker Desktop, check the container, and see "TranscriptionSuite is unresponsive" below. Recordings still queue; they are just not transcribed yet. |
| `TsToken is not set` | Settings file has `CHANGE_ME` or no token | Set `TsToken` in `suite.settings.psd1` or the `TS_TOKEN` environment variable. |
| HTTP 401 from TranscriptionSuite | Wrong or rotated admin token | Update `TsToken`, then restart the watcher. |
| HTTP 409 when uploading | TranscriptionSuite is busy with another job | `Process-Queue.ps1` retries automatically. For the watcher, jobs wait on a mutex and a 12-hour idle timeout. |

## PowerShell pitfalls (already handled in the scripts; keep them in mind when editing)

- **Do not use `Invoke-Expression` inside `Start-Job`.** Building helper functions as a string and evaluating them inside the job corrupted string escaping at runtime, and every background export silently failed. Inline the code in the job scriptblock instead.
- **Do not wrap a deserialized array in `@()` inside `Start-Job`.** `@(Invoke-RestMethod ...)` can produce a one-element array containing the whole collection; `.id` then returns every id joined with spaces and the export URL fails with HTTP 422 ("unable to parse string as an integer"). Unpack with `@(foreach ($r in $raw) { $r })` instead.
- **API response shape varies.** `GET /api/notebook/recordings` has returned both a bare array and a `{value: [...]}` object. Handle both.
- **WebSockets are not usable in Windows PowerShell 5.1** here (`System.Net.WebSockets.Client` does not load), so OBS is stopped with `CloseMainWindow()` and an 8-second wait, then a force-kill.
- **Do not stop a script by matching its name in a command that itself contains that name.** `Get-CimInstance ... -like "*Run-Backlog*"` also matches the shell running the command, and the shell is killed (exit code 4294967295). Exclude your own `$PID` (see the restart snippet in SETUP).

## Transcripts missing or wrong

| Symptom | Cause | Fix |
|---|---|---|
| Transcript never appeared, TranscriptionSuite shows the recording as finished | An older script waited for `is_busy` to turn false; a queued job took the slot first, so the wrong or no recording was exported | Fixed in this repo: each job waits for **its own recording by file name**, and uploads are serialized with the `Local\TsUploadLock` mutex. Use `Run-Backlog.ps1` to re-export. |
| All exports fail with HTTP 422 | The `@()`-in-`Start-Job` array bug above | Fixed. Re-export with `Run-Backlog.ps1 -Files ...`. |
| Transcript has the wrong meeting title | Two calendar events overlap the recording, and the nearest start wins | Check the first lines of each transcript and rename the file if needed. |
| File is named `Recovered HH-mm-ss` | No Outlook event matched, or Outlook is not available | Expected without Outlook. The transcript text is fine. |
| Transcript has no Outlook header | Outlook lookup failed (COM error, profile prompt) | Logged as a warning and ignored. Open Outlook once and retry. |
| 0-byte or tiny file uploaded | Recording was empty | The watcher skips files under 10 KB, and `Process-Queue.ps1` skips files under 2 MB. |

## TranscriptionSuite is unresponsive

Symptoms: `http://localhost:9786/health` times out, or a job sits at a fixed progress (for example 649 of 812) and ignores `POST /api/transcribe/cancel`.

1. Check Docker Desktop is running and the `transcriptionsuite-container` container is up.
2. If a job is stuck, restart the container. This takes about 5 to 10 minutes. Run the Docker call inside `Start-Job` so your session is not blocked:
   ```powershell
   Start-Job { docker restart transcriptionsuite-container } | Out-Null
   ```
3. A container restart also kills any queued `Process-Queue.ps1` run. Check `logs\queue.log` afterwards and run the remaining files again with `Run-Backlog.ps1`.
4. If the whole of WSL has hung, run `wsl --shutdown`, then start Docker Desktop and the suite again.

## Speed and memory

- Diarization dominates run time (about 60 to 150 minutes for a long meeting on a laptop CPU). It uses one CPU thread, while Whisper itself uses all cores.
- TranscriptionSuite accepts one job at a time. A second container would help, but each one uses about 9 GB while working, so on a 32 GB machine with a browser open it is usually not worth it.
- To make WSL give idle memory back to Windows, add this to `%USERPROFILE%\.wslconfig` and run `wsl --shutdown` (or reboot):
  ```ini
  [experimental]
  autoMemoryReclaim=gradual
  ```

## Restarting safely

Only restart the watcher when no call is in progress and TranscriptionSuite has no queued job. A running background job is lost if its watcher process is killed. Check TranscriptionSuite with `GET /api/admin/status` (`models.job_tracker.is_busy`) first.

## Still stuck

Collect `watcher.log`, `queue.log`, and the output of `Invoke-RestMethod http://localhost:9786/health`. Remove any tokens, names and meeting titles before sharing them. The full development history, including every root cause found so far, is in [handoff.md](handoff.md).
