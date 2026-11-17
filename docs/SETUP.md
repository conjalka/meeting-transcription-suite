# Setup guide

Follow these steps once. Every command is PowerShell 5.1. Replace `<TS_TOKEN>` with your own token; never paste a real token into a file that is committed.

## 1. Install the prerequisites

1. Install **Docker Desktop** and let it set up WSL2. Reboot if asked.
2. Install the **TranscriptionSuite** desktop app (v1.3.8 was used for development). Start it once so it creates its Docker files, and confirm the dashboard opens.
3. Install **OBS Studio** and start it once so it creates `%APPDATA%\obs-studio`. Close it.
4. Create a Hugging Face account and a **read** token. While signed in, open the pages for `pyannote/speaker-diarization-3.1` and `pyannote/speaker-diarization-community-1` and accept their terms.

Check the TranscriptionSuite compose files exist (the launcher uses them):

```powershell
Get-ChildItem "$env:LOCALAPPDATA\Programs\TranscriptionSuite\resources\docker" -Filter docker-compose*.yml | Select-Object Name
```

If TranscriptionSuite is installed elsewhere, set `TsComposeDir` in `suite.settings.psd1` (step 3).

## 2. Install the suite

```powershell
git clone https://github.com/conjalka/meeting-transcription-suite.git
cd meeting-transcription-suite
git config core.hooksPath hooks      # only needed if you plan to commit changes
.\install.ps1 -WhatIf                # preview only
.\install.ps1                        # install
```

Useful options:

| Option | Meaning |
|---|---|
| `-Target <dir>` | Install somewhere other than `%USERPROFILE%\Documents\TranscriptionSuite`. |
| `-RecordingsDir <dir>` | Where OBS writes recordings (also written into the OBS profile and the settings file). |
| `-ObsDir <dir>` | OBS config folder if it is not `%APPDATA%\obs-studio`. |
| `-InstallStartup` | Also install the login launcher into the Windows Startup folder. |

Close OBS before a real install: OBS rewrites its profile when it exits.

The installer never deletes anything. A file that already exists and differs is saved as `<name>.<timestamp>.bak` first, and `config.yaml`, `suite.settings.psd1` and `docker\.env` are never overwritten once they exist.

## 3. Add your secrets and settings

Edit `<Target>\suite.settings.psd1`:

- `TsToken`: the TranscriptionSuite admin token. Find it in the TranscriptionSuite dashboard or its server logs. Alternatively leave `CHANGE_ME` and set the `TS_TOKEN` environment variable.
- `TranscriptsDir`: where Markdown transcripts go. Any folder; the default is `<Target>\transcripts`.
- `ObsExe`, `DockerExe`, `TsComposeDir`: change only if your installs are in non-default places.

Edit `<Target>\docker\.env`:

- `HUGGINGFACE_TOKEN=<your Hugging Face read token>`

`config.yaml` is the TranscriptionSuite server configuration (Whisper large-v3, int8, CPU, diarization on). Adjust the model or device there if you have a GPU. The Docker `.env` file must point `USER_CONFIG_DIR` at your install folder so the container reads that `config.yaml`; the TranscriptionSuite app normally writes this for you.

## 4. Select the OBS profile once

OBS decides the active profile and scene collection from `%APPDATA%\obs-studio\global.ini`, which the installer deliberately does not modify. Either:

- Open OBS, choose **Profile > TranscriptionSuite** and **Scene Collection > Teams Meeting Recording**, then close OBS; or
- Edit `global.ini` as described in [`obs/README.md`](../obs/README.md).

Without this OBS opens a blank "Untitled" profile and nothing is recorded.

## 5. Start it

```powershell
& "$env:USERPROFILE\Documents\TranscriptionSuite\scripts\Start-TranscriptionSuite.ps1"
```

This starts Docker Desktop if needed, brings the TranscriptionSuite container up, waits for `/health`, and starts the watcher hidden. Sign out and in again if you installed the login shortcut.

The first start downloads the models and can take a long time.

## 6. Verify

```powershell
$root = "$env:USERPROFILE\Documents\TranscriptionSuite"

# 1. Is the watcher running?
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*Watch-TeamsMeeting*" } | Select-Object ProcessId

# 2. What does the watcher log say?
Get-Content "$root\logs\watcher.log" -Tail 30

# 3. Is TranscriptionSuite healthy? (no token needed)
Invoke-RestMethod http://localhost:9786/health

# 4. Admin status (token needed; keep the token out of shared logs and screenshots)
Invoke-RestMethod http://localhost:9786/api/admin/status -Headers @{ Authorization = "Bearer <TS_TOKEN>" }

# 5. Recordings and transcripts so far
Get-ChildItem "$root\recordings" | Sort-Object LastWriteTime -Descending | Format-Table Name, Length, LastWriteTime
Get-ChildItem "$root\transcripts"
```

End-to-end test: start a Teams, Zoom or web call (a call with only yourself is fine), speak for over 90 seconds, then leave. The log should show `CALL STARTED`, then `CALL ENDED`, an MP3 in `recordings\`, and later a Markdown file in your transcripts folder. Allow an hour or more for a long meeting.

## Everyday operations

Restart the watcher (only when no transcription job is running):

```powershell
$myPid = $PID
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*Watch-TeamsMeeting*" -and $_.ProcessId -ne $myPid } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
& "$env:USERPROFILE\Documents\TranscriptionSuite\scripts\Start-TranscriptionSuite.ps1"
```

Transcribe recordings that were missed (watcher off, TranscriptionSuite down):

```powershell
.\scripts\Run-Backlog.ps1 -Since "2026-01-01"
.\scripts\Run-Backlog.ps1 -Files "2026-01-05 10-01-18.mp3","2026-01-05 13-00-02.mp3"
```

Recordings already in TranscriptionSuite are not uploaded again; only their transcript is exported. Progress goes to `logs\queue.log`.

Update after pulling new repo changes: run `.\install.ps1 -WhatIf`, then `.\install.ps1`, then restart the watcher.

## Uninstall

See the `UNINSTALL` section in the header of `install.ps1` (`Get-Help .\install.ps1 -Full`). In short: stop the watcher, delete the installed scripts and settings you no longer want, remove the OBS profile and scene, and delete the Startup shortcut if you installed it. Recordings and transcripts are never touched by the installer.
