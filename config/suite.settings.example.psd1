@{
    # TranscriptionSuite server and admin token.
    # Find the token in the TranscriptionSuite server logs / dashboard. Keep it private.
    # Alternative: leave this as CHANGE_ME and set the TS_TOKEN environment variable.
    TsServer       = 'http://localhost:9786'
    TsToken        = 'CHANGE_ME'

    # Where finished Markdown transcripts are written. Any folder you like.
    TranscriptsDir = '%USERPROFILE%\Documents\TranscriptionSuite\transcripts'

    # Where OBS writes recordings (must match the OBS profile's recording path).
    RecordingsDir  = '%USERPROFILE%\Documents\TranscriptionSuite\recordings'

    # Watcher, launcher and queue logs.
    LogDir         = '%USERPROFILE%\Documents\TranscriptionSuite\logs'

    # OBS Studio executable and the scene to open when a call starts.
    ObsExe         = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe'
    ObsScene       = 'Teams Meeting'

    # Used by Start-TranscriptionSuite.ps1 only.
    DockerExe      = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    TsComposeDir   = '%LOCALAPPDATA%\Programs\TranscriptionSuite\resources\docker'
    TsEnvFile      = '%USERPROFILE%\Documents\TranscriptionSuite\docker\.env'
}
