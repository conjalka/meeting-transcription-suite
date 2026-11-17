# OBS files

| File | Goes to | Notes |
|---|---|---|
| `basic.ini.template` | `%APPDATA%\obs-studio\basic\profiles\TranscriptionSuite\basic.ini` | Contains the placeholder `@RECORDINGS_DIR@` on the `RecFilePath` and `FFFilePath` lines. `install.ps1` replaces it with your recordings folder, using forward slashes (OBS format). |
| `Teams Meeting Recording.json` | `%APPDATA%\obs-studio\basic\scenes\Teams Meeting Recording.json` | Scene collection. One scene, `Teams Meeting`, with Desktop Audio and Mic/Aux set to the default devices. Audio only, no video sources. |

The profile records MP3 (libmp3lame, 160 kbps) through the FFmpeg output, with no video track.

## Making OBS use them

OBS picks the profile and scene collection from `%APPDATA%\obs-studio\global.ini`. Under `[General]` it needs:

```ini
CurrentProfile=TranscriptionSuite
CurrentSceneCollection=Teams Meeting Recording
```

`global.ini` also holds window geometry, hotkeys and an install GUID, so it is not copied. The simplest way to set these two keys is to open OBS once, choose **Profile > TranscriptionSuite** and **Scene Collection > Teams Meeting Recording**, then close it.

The watcher launches OBS with `--scene "Teams Meeting" --startrecording`, so the scene name must match `ObsScene` in your settings file.
