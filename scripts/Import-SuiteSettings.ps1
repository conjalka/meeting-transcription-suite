# Import-SuiteSettings.ps1
# Shared settings loader. Dot-source it, then call Get-SuiteSettings:
#   . "$PSScriptRoot\Import-SuiteSettings.ps1"
#   $S = Get-SuiteSettings
#
# Settings file search order (first match wins):
#   1. <scripts folder>\..\suite.settings.psd1                 (installed layout)
#   2. <scripts folder>\..\config\suite.settings.local.psd1    (repo checkout layout)
#   3. %USERPROFILE%\Documents\TranscriptionSuite\suite.settings.psd1
# Copy config\suite.settings.example.psd1 to one of these names and edit it.
#
# String values may use %ENVVAR% placeholders. The TS_TOKEN environment variable,
# when set, overrides TsToken from the file.

function Get-SuiteSettings {
    param([switch]$NoToken)   # launcher does not need the token
    $root   = Join-Path $env:USERPROFILE 'Documents\TranscriptionSuite'
    $parent = Split-Path $PSScriptRoot -Parent

    $s = @{
        TsServer       = 'http://localhost:9786'
        TsToken        = ''
        RecordingsDir  = (Join-Path $root 'recordings')
        TranscriptsDir = (Join-Path $root 'transcripts')
        LogDir         = (Join-Path $root 'logs')
        ObsExe         = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe'
        ObsScene       = 'Teams Meeting'
        DockerExe      = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
        TsComposeDir   = (Join-Path $env:LOCALAPPDATA 'Programs\TranscriptionSuite\resources\docker')
        TsEnvFile      = (Join-Path $root 'docker\.env')
    }

    $candidates = @(
        (Join-Path $parent 'suite.settings.psd1'),
        (Join-Path $parent 'config\suite.settings.local.psd1'),
        (Join-Path $root   'suite.settings.psd1')
    )
    $file = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($file) {
        $user = Import-PowerShellDataFile -Path $file
        foreach ($k in $user.Keys) { $s[$k] = $user[$k] }
    }

    if ($env:TS_TOKEN) { $s.TsToken = $env:TS_TOKEN }

    foreach ($k in @($s.Keys)) {
        if ($s[$k] -is [string]) { $s[$k] = [Environment]::ExpandEnvironmentVariables($s[$k]) }
    }

    if (-not $NoToken -and ([string]::IsNullOrWhiteSpace($s.TsToken) -or $s.TsToken -eq 'CHANGE_ME')) {
        throw "TsToken is not set. Copy config\suite.settings.example.psd1 to suite.settings.psd1 and set TsToken, or set the TS_TOKEN environment variable."
    }
    return $s
}
