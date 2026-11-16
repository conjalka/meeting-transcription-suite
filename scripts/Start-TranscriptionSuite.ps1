#Requires -Version 5.1
<#
.SYNOPSIS
    Start-TranscriptionSuite.ps1
    One-click launcher: waits for Docker, starts the TS server, then starts the Teams meeting watcher.
    Run this at login or pin it to the taskbar.
#>

$ErrorActionPreference = "SilentlyContinue"
. "$PSScriptRoot\Import-SuiteSettings.ps1"
$S = Get-SuiteSettings -NoToken
$LOG = Join-Path $S.LogDir "launcher.log"
New-Item -ItemType Directory -Force (Split-Path $LOG) | Out-Null

function Write-Log {
    param([string]$Msg)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Msg"
    Add-Content -Path $LOG -Value $line -Encoding UTF8
    Write-Host $line
}

# -- 1. Ensure Docker Desktop is running ---------------------------------------
Write-Log "Checking Docker Desktop..."
$dockerRunning = [bool](Get-Process "Docker Desktop" -ErrorAction SilentlyContinue)
if (-not $dockerRunning) {
    Write-Log "Starting Docker Desktop..."
    Start-Process $S.DockerExe
    Write-Log "Waiting for Docker engine (up to 90 seconds)..."
    $waited = 0
    while ($waited -lt 90) {
        Start-Sleep -Seconds 5
        $waited += 5
        $result = docker info 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        Write-Log "  ...still waiting (${waited}s)"
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: Docker did not start in time. Aborting."
        exit 1
    }
}
Write-Log "Docker is running."

# -- 2. Start TranscriptionSuite container (idempotent) ------------------------
Write-Log "Starting TranscriptionSuite server..."
$composeBase = Join-Path $S.TsComposeDir "docker-compose.yml"
$composeVM   = Join-Path $S.TsComposeDir "docker-compose.desktop-vm.yml"
$envFile     = $S.TsEnvFile

docker compose --env-file $envFile -f $composeBase -f $composeVM -p transcriptionsuite up -d 2>&1 | ForEach-Object { Write-Log "  docker: $_" }

# Wait for the server to become healthy
Write-Log "Waiting for TranscriptionSuite to be ready..."
$waited = 0
while ($waited -lt 120) {
    Start-Sleep -Seconds 5
    $waited += 5
    try {
        $h = Invoke-RestMethod "$($S.TsServer)/health" -TimeoutSec 3 -ErrorAction Stop
        if ($h.status -eq "healthy") { break }
    } catch {}
    Write-Log "  ...still waiting (${waited}s)"
}
Write-Log "TranscriptionSuite is ready."

# -- 3. Start the Teams meeting watcher in a hidden background job -------------
Write-Log "Starting Teams meeting watcher..."
$watcherPath = Join-Path $PSScriptRoot "Watch-TeamsMeeting.ps1"
Start-Process powershell.exe `
    -ArgumentList "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherPath`"" `
    -WindowStyle Hidden

Write-Log "All services started. Watcher is running in the background."
Write-Log "Dashboard: $($S.TsServer)"
Write-Log "Logs: $($S.LogDir)"
