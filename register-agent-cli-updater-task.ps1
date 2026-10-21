$ErrorActionPreference = "Stop"
$script:AgentCliUpdaterScriptRoot = Split-Path -Parent $PSCommandPath

function Get-AgentCliUpdaterTaskDefinition {
    [CmdletBinding()]
    param(
        [string]$BasePath = $script:AgentCliUpdaterScriptRoot
    )

    $launcherPath = Join-Path $BasePath "run-update-agent-clis.cmd"

    if (-not (Test-Path -LiteralPath $launcherPath)) {
        throw "Launcher not found: $launcherPath"
    }

    return [PSCustomObject]@{
        TaskName = "Agent CLI Auto Update"
        LauncherPath = $launcherPath
        Schedule = "DAILY"
        StartTime = "02:00"
    }
}

function Invoke-AgentCliUpdaterTaskRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$TaskDefinition
    )

    schtasks /Create /TN $TaskDefinition.TaskName /TR $TaskDefinition.LauncherPath /SC $TaskDefinition.Schedule /ST $TaskDefinition.StartTime /RL HIGHEST /F /IT | Out-Null
}

function Register-AgentCliUpdaterTask {
    [CmdletBinding()]
    param(
        [string]$BasePath = $script:AgentCliUpdaterScriptRoot
    )

    $taskDefinition = Get-AgentCliUpdaterTaskDefinition -BasePath $BasePath
    Invoke-AgentCliUpdaterTaskRegistration -TaskDefinition $taskDefinition

    Write-Host "Registered scheduled task: $($taskDefinition.TaskName)"
    Write-Host "Launcher: $($taskDefinition.LauncherPath)"
    Write-Host "Runs daily at 02:00 with highest privileges while the current user is logged in."
}

if (-not $env:AGENT_CLI_UPDATER_IMPORT_ONLY) {
    Register-AgentCliUpdaterTask
}
