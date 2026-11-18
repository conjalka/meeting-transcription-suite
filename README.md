# Meeting Transcription Suite

Automatically record your online meetings and turn them into speaker-labelled Markdown transcripts, **entirely on your own PC**.

- Detects when a call starts and ends (Microsoft Teams, Zoom, and Google Meet or other web calls in Chrome/Edge).
- Records the call audio (system sound plus your microphone) with OBS Studio, as an MP3.
- Transcribes it locally with [TranscriptionSuite](https://github.com/homelab-00/TranscriptionSuite) (Whisper large-v3, with PyAnnote speaker diarization), running in Docker.
- Saves a Markdown file per meeting, named after the matching Outlook calendar event when one is found.

> **Privacy:** nothing leaves your machine. There are no cloud transcription APIs and no bots joining your meetings. The only network calls are to `localhost`, plus model downloads the first time TranscriptionSuite starts. Make sure you have the right to record the calls you use this on; many organisations and jurisdictions require consent.

TranscriptionSuite is a separate project under the GPL-3.0 license. This repo only drives it through its HTTP API and Docker and does not include or redistribute it.

This is a personal project. It is not affiliated with or endorsed by any employer, by TranscriptionSuite, by OBS, or by Microsoft, Zoom or Google.

## How it works

```
Teams / Zoom / Chrome / Edge microphone use  (Windows registry, polled every 3 s)
        |
Watch-TeamsMeeting.ps1  (PowerShell watcher, runs hidden)
        |  call starts -> launch OBS
        |  call ends   -> stop OBS -> background job
        v
OBS Studio  (desktop audio + mic -> MP3 in recordings\)
        |
Background job
   - upload the MP3 to TranscriptionSuite (one upload at a time, guarded by a mutex)
   - wait until its own recording finishes (matched by file name)
   - export Markdown from TranscriptionSuite
   - look up the Outlook calendar event, prepend a header, save as <date>_<subject>.md
        |
TranscriptionSuite  (Docker, http://localhost:9786)
   - Whisper large-v3 (faster-whisper, CPU, int8)
   - PyAnnote speaker-diarization-3.1
```

Detection signal: Windows records which apps hold the microphone under `HKCU\...\CapabilityAccessManager\ConsentStore\microphone`. While an app has the mic open its `LastUsedTimeStop` value is `0`. The watcher treats that as "in a call". Calls shorter than 90 seconds are not uploaded.

## Requirements

- Windows 11 with Windows PowerShell 5.1 (the version that ships with Windows). Developed and tested on Windows 11 Enterprise only.
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) with WSL2.
- [TranscriptionSuite](https://github.com/homelab-00/TranscriptionSuite) desktop app. Developed against **v1.3.8** and running on **v1.3.9**; other versions may need adjustments.
- [OBS Studio](https://obsproject.com/) 30 or later.
- A free [Hugging Face](https://huggingface.co/) account and read token, with the model terms accepted for `pyannote/speaker-diarization-3.1` and `pyannote/speaker-diarization-community-1` (the two the author accepted). This is only needed to download the diarization models.
- Optional: classic Outlook desktop, for calendar-based file names and headers. Without it, transcripts are named from the TranscriptionSuite title or `Recovered HH-mm-ss`.
- Roughly 9 GB of free RAM while TranscriptionSuite is working, and patience (see Limitations).

## Quick start

```powershell
git clone https://github.com/conjalka/meeting-transcription-suite.git
cd meeting-transcription-suite
.\install.ps1 -WhatIf        # preview: shows what would be created or updated, writes nothing
.\install.ps1                # install into %USERPROFILE%\Documents\TranscriptionSuite
```

Then edit two files the installer created, and follow [docs/SETUP.md](docs/SETUP.md) for the one-time OBS selection and verification:

1. `suite.settings.psd1`: set `TsToken` (the TranscriptionSuite admin token).
2. `docker\.env`: set `HUGGINGFACE_TOKEN`.

Start everything with `scripts\Start-TranscriptionSuite.ps1`, or install the login shortcut with `.\install.ps1 -InstallStartup`.

## What is in the repo

| Path | Purpose |
|---|---|
| `install.ps1` | Idempotent installer. Supports `-WhatIf`, never deletes, backs up changed files as `*.bak`. Uninstall steps are in its help. |
| `scripts/Watch-TeamsMeeting.ps1` | The watcher: detects calls, drives OBS, runs the post-call upload and export job. |
| `scripts/Process-Queue.ps1` | Transcribe specific recordings one at a time (for recovery or backlog). |
| `scripts/Run-Backlog.ps1` | Wrapper: `-Files <names>` or `-Since <date>`. |
| `scripts/Start-TranscriptionSuite.ps1` | Launcher: starts Docker Desktop, the TS container, then the watcher. |
| `scripts/Import-SuiteSettings.ps1` | Loads `suite.settings.psd1`; the token can instead come from the `TS_TOKEN` environment variable. |
| `config/` | `suite.settings.example.psd1`, `config.yaml` (TranscriptionSuite settings), `.env.example`. |
| `obs/` | OBS profile template and scene collection. See `obs/README.md`. |
| `startup/` | Optional login launcher (`.vbs`). |
| `docs/` | Setup guide, troubleshooting, and the original engineering notes. |

## Secrets

Real tokens live only in `suite.settings.psd1`, `docker\.env` or the `TS_TOKEN` environment variable, all outside the repo and ignored by `.gitignore`. A pre-commit hook (`hooks/pre-commit`) blocks commits that contain token-like strings or personal paths. Enable it after cloning:

```powershell
git config core.hooksPath hooks
```

## Network exposure

In its default plain-HTTP mode, TranscriptionSuite did not check tokens on the machine this was built on: every API call, including the recordings list and exports, answered without one. Docker also publishes port 9786 on all network interfaces, so other devices on the same network could reach it. Before using this on a shared or public network, restrict port 9786 to this PC (for example with a Windows Firewall rule that blocks inbound connections to it) or enable TLS in TranscriptionSuite, which makes it require the token.

## Limitations

- Windows and PowerShell 5.1 only.
- Teams detection relies on the new Teams client's registry key name (`MSTeams_8wekyb3d8bbwe`).
- CPU-only diarization is slow: roughly 60 to 150 minutes for a long meeting on the reference laptop. It runs mostly on a single core.
- TranscriptionSuite processes one job at a time, so the suite queues uploads. A long backlog takes a long time.
- The calendar title can be wrong when two meetings overlap. Check the first lines of each transcript.
- OBS is force-closed when the call ends, which is why the watcher clears OBS crash sentinel files before each launch.

## Documentation

- [docs/SETUP.md](docs/SETUP.md): step-by-step install and verification.
- [docs/troubleshooting.md](docs/troubleshooting.md): symptoms, causes and fixes.
- [docs/handoff.md](docs/handoff.md): the original engineering notes and fix history.

## Support

Provided as-is, with no warranty and no support commitment. It was built for one Windows setup and shared in case it helps someone else. Issues and pull requests may go unanswered.

## License

[MIT](LICENSE) (c) Jonathan Hill

This repository contains glue scripts and configuration only. TranscriptionSuite, OBS Studio, Docker, Whisper and PyAnnote are separate projects with their own licenses and terms.
