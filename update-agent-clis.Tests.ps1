$env:AGENT_CLI_UPDATER_IMPORT_ONLY = "1"
. "$PSScriptRoot\update-agent-clis.ps1"
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
