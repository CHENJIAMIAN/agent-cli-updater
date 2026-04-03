$ErrorActionPreference = "Stop"

$taskName = "Agent CLI Auto Update"
$launcherPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "run-update-agent-clis.cmd"

if (-not (Test-Path -LiteralPath $launcherPath)) {
    throw "Launcher not found: $launcherPath"
}

schtasks /Create /TN $taskName /TR $launcherPath /SC HOURLY /MO 6 /RL HIGHEST /F /IT | Out-Null

Write-Host "Registered scheduled task: $taskName"
Write-Host "Launcher: $launcherPath"
Write-Host "Runs every 6 hours with highest privileges while the current user is logged in."
