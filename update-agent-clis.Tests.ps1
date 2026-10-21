$env:AGENT_CLI_UPDATER_IMPORT_ONLY = "1"
. "$PSScriptRoot\update-agent-clis.ps1"
Remove-Item Env:AGENT_CLI_UPDATER_IMPORT_ONLY -ErrorAction SilentlyContinue

$env:AGENT_CLI_UPDATER_IMPORT_ONLY = "1"
. "$PSScriptRoot\register-agent-cli-updater-task.ps1"
Remove-Item Env:AGENT_CLI_UPDATER_IMPORT_ONLY -ErrorAction SilentlyContinue

Describe "Stop-RunningCliProcesses" {
    It "stops only the targeted cli processes" {
        Mock Get-CimInstance {
            @(
                [PSCustomObject]@{
                    ProcessId = 101
                    Name = "powershell.exe"
                    ExecutablePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
                    CommandLine = "powershell -File codex.ps1"
                }
                [PSCustomObject]@{
                    ProcessId = 202
                    Name = "powershell.exe"
                    ExecutablePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
                    CommandLine = "powershell -File claude.ps1"
                }
                [PSCustomObject]@{
                    ProcessId = 303
                    Name = "codex.exe"
                    ExecutablePath = "C:\Users\Administrator\AppData\Roaming\npm\codex.exe"
                    CommandLine = "codex"
                }
            )
        }

        Mock Stop-Process {}

        $stopped = Stop-RunningCliProcesses -CliName "codex"

        $stopped.ProcessId | Should Be @(101, 303)
        Assert-MockCalled Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 101 }
        Assert-MockCalled Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 303 }
        Assert-MockCalled Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 202 }
    }
}

Describe "Get-UpdateStatus" {
    It "treats version changes as updated with warnings when command exits non-zero" {
        $status = Get-UpdateStatus -Execution ([PSCustomObject]@{
            TimedOut = $false
            ExitCode = 1
            StdOut = ""
            StdErr = "warning"
        }) -VersionBefore "1.0.0" -VersionAfter "1.1.0"

        $status | Should Be "updated-with-warnings"
    }
}

Describe "Get-AgentCliUpdaterTaskDefinition" {
    It "uses a daily 02:00 schedule" {
        $taskDefinition = Get-AgentCliUpdaterTaskDefinition -BasePath $PSScriptRoot

        $taskDefinition.TaskName | Should Be "Agent CLI Auto Update"
        $taskDefinition.Schedule | Should Be "DAILY"
        $taskDefinition.StartTime | Should Be "02:00"
        $taskDefinition.LauncherPath | Should Be (Join-Path $PSScriptRoot "run-update-agent-clis.cmd")
    }
}

Describe "run-update-agent-clis.cmd" {
    It "does not wait for interactive input" {
        $launcherPath = Join-Path $PSScriptRoot "run-update-agent-clis.cmd"
        $content = Get-Content -LiteralPath $launcherPath -Raw

        $content | Should Not Match '(?im)^\s*pause\b'
    }
}

Describe "Test-AllowsSelfUpdate" {
    It "disables self-update for claude in unattended runs" {
        (Test-AllowsSelfUpdate -CliName "claude") | Should Be $false
    }

    It "keeps self-update enabled for other CLIs by default" {
        (Test-AllowsSelfUpdate -CliName "gemini") | Should Be $true
    }
}

Describe "Get-PackageManagerForCommand" {
    It "treats delegated codex wrapper as npm-managed without changing the wrapper" {
        $wrapperPath = Join-Path $TestDrive "codex.ps1"
        $realCodexPath = Join-Path $env:APPDATA 'npm\codex.ps1'
        @(
            '#!/usr/bin/env pwsh'
            '$helper = ''C:\Users\Administrator\.local\bin\ensure-codex-watch.ps1'''
            ('$realCodex = ''{0}''' -f $realCodexPath)
            '& $helper'
            '& $realCodex @args'
        ) | Set-Content -LiteralPath $wrapperPath

        $manager = Get-PackageManagerForCommand -CommandPath $wrapperPath -PnpmGlobalBin 'D:\pnpm-global-bin-dir'

        $manager | Should Be 'npm'
    }
}
