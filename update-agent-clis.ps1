param(
    [switch]$SkipMain
)

$ErrorActionPreference = "Stop"
$script:AgentCliUpdaterBaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 1200
    )

    $resolvedCommand = Get-Command $FilePath -ErrorAction SilentlyContinue
    if ($resolvedCommand) {
        $FilePath = if ($resolvedCommand.Source) { $resolvedCommand.Source } else { $resolvedCommand.Path }
    }

    function Quote-Argument {
        param([string]$Value)

        if ($null -eq $Value) {
            return '""'
        }

        if ($Value -notmatch '[\s"]') {
            return $Value
        }

        return '"' + ($Value -replace '(\\*)"', '$1$1\"') + '"'
    }

    $extension = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $runner = $FilePath
    $runnerArgs = $Arguments

    switch ($extension) {
        ".ps1" {
            $runner = "powershell.exe"
            $runnerArgs = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $FilePath) + $Arguments
        }
        ".cmd" {
            $runner = "cmd.exe"
            $runnerArgs = @("/c", $FilePath) + $Arguments
        }
        ".bat" {
            $runner = "cmd.exe"
            $runnerArgs = @("/c", $FilePath) + $Arguments
        }
    }

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $argumentString = ($runnerArgs | ForEach-Object { Quote-Argument $_ }) -join " "
        $proc = Start-Process -FilePath $runner -ArgumentList $argumentString -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -PassThru -NoNewWindow
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch {}
            return [PSCustomObject]@{
                ExitCode = -1
                TimedOut = $true
                StdOut = (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue)
                StdErr = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
            }
        }

        return [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            TimedOut = $false
            StdOut = (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue)
            StdErr = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-PnpmGlobalBin {
    $pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
    if (-not $pnpm) {
        return $null
    }

    try {
        $output = & $pnpm.Source bin -g 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) {
            return ($output | Select-Object -First 1).ToString().Trim()
        }
    }
    catch {}

    return $null
}

function Get-ActiveCommandInfo {
    param([Parameter(Mandatory = $true)][string]$Name)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return $null
    }

    $resolvedPath = $cmd.Source
    if (-not $resolvedPath) {
        $resolvedPath = $cmd.Path
    }

    return [PSCustomObject]@{
        Name = $Name
        Path = $resolvedPath
        CommandType = $cmd.CommandType.ToString()
    }
}

function Get-PackageManagerForCommand {
    param(
        [Parameter(Mandatory = $true)][string]$CommandPath,
        [string]$PnpmGlobalBin
    )

    function Get-DelegatedCommandPath {
        param([Parameter(Mandatory = $true)][string]$Path)

        try {
            $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        }
        catch {
            return $null
        }

        $targetLeaf = [System.IO.Path]::GetFileName($Path)
        $delegatedPathMatches = [regex]::Matches($content, "(?im)['""](?<path>[A-Z]:\\[^'""]+?\.(?:ps1|cmd|bat|exe))['""]")
        $candidates = @()

        foreach ($match in $delegatedPathMatches) {
            $candidatePath = $match.Groups["path"].Value
            if (-not $candidatePath -or $candidatePath -eq $Path) {
                continue
            }
            # 2026-10-21：候选路径可能取自二进制内容的乱码，含非法字符时 Test-Path 会抛终止错误
            # （ErrorActionPreference=Stop 下直接炸掉整个脚本，之前每晚都崩在 claude.exe 上）。
            # 包一层 try/catch，坏候选当不存在。
            $candidateExists = $false
            try {
                $candidateExists = Test-Path -LiteralPath $candidatePath
            }
            catch {
                $candidateExists = $false
            }
            if ($candidateExists) {
                $candidates += $candidatePath
            }
        }

        foreach ($candidatePath in $candidates) {
            if ([System.IO.Path]::GetFileName($candidatePath).Equals($targetLeaf, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $candidatePath
            }
        }

        if ($candidates.Count -gt 0) {
            return $candidates[0]
        }

        return $null
    }

    $effectivePath = $CommandPath
    $delegatedPath = Get-DelegatedCommandPath -Path $CommandPath
    if ($delegatedPath) {
        $effectivePath = $delegatedPath
    }

    $normalizedPath = [System.IO.Path]::GetFullPath($effectivePath).ToLowerInvariant()
    $npmGlobal = [System.IO.Path]::GetFullPath((Join-Path $env:APPDATA "npm")).ToLowerInvariant()

    if ($normalizedPath.StartsWith($npmGlobal)) {
        return "npm"
    }

    if ($PnpmGlobalBin) {
        $normalizedPnpmBin = [System.IO.Path]::GetFullPath($PnpmGlobalBin).ToLowerInvariant()
        if ($normalizedPath.StartsWith($normalizedPnpmBin)) {
            return "pnpm"
        }
    }

    return $null
}

function Get-PackageNameFromCommandWrapper {
    param([Parameter(Mandatory = $true)][string]$CommandPath)

    try {
        $content = Get-Content -LiteralPath $CommandPath -Raw -ErrorAction Stop
    }
    catch {
        return $null
    }

    $match = [regex]::Match($content, 'node_modules[\\/](?<pkg>(?:@[^\\/]+[\\/])?[^\\/]+)[\\/]bin[\\/]')
    if ($match.Success) {
        return ($match.Groups["pkg"].Value -replace '[\\/]', '/')
    }

    return $null
}

function Find-SelfUpdateCommand {
    param([Parameter(Mandatory = $true)][string]$CliName)

    $helpCommands = @(
        @("--help"),
        @("help")
    )

    foreach ($helpArgs in $helpCommands) {
        try {
            $helpResult = Invoke-ExternalCommand -FilePath $CliName -Arguments $helpArgs -TimeoutSeconds 20
            $combined = (($helpResult.StdOut + "`n" + $helpResult.StdErr) | Out-String)
            if ($combined -match '(?im)^\s*update(\s|$)' -or $combined -match '(?im)\bupdate\b') {
                return @("update")
            }
        }
        catch {}
    }

    return $null
}

function Test-AllowsSelfUpdate {
    param([Parameter(Mandatory = $true)][string]$CliName)

    $blockedCliNames = @("claude")
    return $blockedCliNames -notcontains $CliName.ToLowerInvariant()
}

function Get-VersionString {
    param([Parameter(Mandatory = $true)][string]$CliName)

    foreach ($args in @(@("--version"), @("-V"), @("version"))) {
        try {
            $result = Invoke-ExternalCommand -FilePath $CliName -Arguments $args -TimeoutSeconds 20
            $combined = @($result.StdOut, $result.StdErr) -join "`n"
            if ($combined) {
                $firstLine = ($combined.Trim() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                if ($firstLine) {
                    return $firstLine
                }
            }
        }
        catch {}
    }

    return ""
}

function Test-ProcessMatchesCli {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)][string]$CliName
    )

    $cliPattern = "(?i)(^|[\\/\s`"'])$([regex]::Escape($CliName))(\.cmd|\.ps1|\.bat|\.exe)?([\\/\s`"']|$)"

    if ($Process.ExecutablePath) {
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Process.ExecutablePath)
        if ($fileName -and $fileName.Equals($CliName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    if ($Process.CommandLine -and $Process.CommandLine -match $cliPattern) {
        return $true
    }

    return $false
}

function Stop-RunningCliProcesses {
    param([Parameter(Mandatory = $true)][string]$CliName)

    $matched = @()

    try {
        $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $processes = @($allProcesses | Where-Object {
            Test-ProcessMatchesCli -Process $_ -CliName $CliName
        })
    }
    catch {
        $allProcesses = @()
        $processes = @()
    }

    # 2026-10-21：父进程是 cc-connect.exe 的子进程是聊天桥养的常驻会话进程，
    # 强杀会让会话异常退出并向群里推送错误（exit 0xffffffff + 遗留 stderr 被当死因转发）。更新前跳过。
    $parentNames = @{}
    foreach ($p in $allProcesses) { $parentNames[[uint32]$p.ProcessId] = $p.Name }

    foreach ($process in $processes) {
        $parentName = $parentNames[[uint32]$process.ParentProcessId]
        if ($parentName -and $parentName -ieq "cc-connect.exe") {
            Write-Host ("Skipping cc-connect session process: PID " + $process.ProcessId + " (" + $process.Name + ")") -ForegroundColor DarkYellow
            continue
        }

        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            $matched += [PSCustomObject]@{
                ProcessId = $process.ProcessId
                Name = $process.Name
                CommandLine = $process.CommandLine
                Stopped = $true
            }
        }
        catch {
            $matched += [PSCustomObject]@{
                ProcessId = $process.ProcessId
                Name = $process.Name
                CommandLine = $process.CommandLine
                Stopped = $false
            }
        }
    }

    return $matched
}

function Test-UpdateOutputIndicatesChange {
    param(
        [Parameter(Mandatory = $true)]$Execution,
        [string]$PackageName
    )

    $combined = @($Execution.StdOut, $Execution.StdErr) -join "`n"
    if (-not $combined) {
        return $false
    }

    if ($combined -match '(?im)\bchanged\s+\d+\s+packages?\b') {
        return $true
    }

    if ($combined -match '(?im)\badded\s+\d+\s+packages?\b') {
        return $true
    }

    if ($combined -match '(?im)\bup to date\b') {
        return $true
    }

    if ($PackageName -and $combined -match [regex]::Escape($PackageName)) {
        return $true
    }

    return $false
}

function Get-UpdateStatus {
    param(
        [Parameter(Mandatory = $true)]$Execution,
        [string]$VersionBefore,
        [string]$VersionAfter,
        [string]$PackageName
    )

    if ($Execution.TimedOut) {
        return "timeout"
    }

    if ($Execution.ExitCode -eq 0) {
        return "updated"
    }

    if ($VersionBefore -and $VersionAfter -and $VersionBefore -ne $VersionAfter) {
        return "updated-with-warnings"
    }

    if (Test-UpdateOutputIndicatesChange -Execution $Execution -PackageName $PackageName) {
        return "updated-with-warnings"
    }

    return "failed"
}

function Invoke-AgentCliUpdates {
    $baseDir = $script:AgentCliUpdaterBaseDir
    $logDir = Join-Path $baseDir "logs"
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logPath = Join-Path $logDir "agent-cli-update-$timestamp.log"
    Start-Transcript -Path $logPath -Force | Out-Null

    try {
        # 2026-10-21：移除 claude。它已是原生安装（.local\bin\claude.exe，自带 autoUpdatesChannel 自更新），
        # 这里既无法可靠推断包名（会从二进制里抠出乱码导致 Test-Path 抛错），更新前的强杀还会把
        # cc-connect 养的常驻会话进程杀掉，导致飞书群每晚收到 [claude-code:unrecognized_model] 假错误推送。
        $candidatePackages = @(
            @{ Cli = "gemini"; Package = $null },
            @{ Cli = "codex"; Package = "@openai/codex" },
            @{ Cli = "kilo"; Package = $null },
            @{ Cli = "opencode"; Package = $null }
        )

        $pnpmGlobalBin = Resolve-PnpmGlobalBin
        $results = New-Object System.Collections.Generic.List[object]

        Write-Section "Agent CLI Auto Update"
        Write-Host ("Started at: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
        Write-Host ("Log file: " + $logPath)
        Write-Host ("pnpm global bin: " + $(if ($pnpmGlobalBin) { $pnpmGlobalBin } else { "<not detected>" }))

        foreach ($candidate in $candidatePackages) {
            $cliName = $candidate.Cli
            $packageName = $candidate.Package
            Write-Section ("Checking " + $cliName)

            $commandInfo = Get-ActiveCommandInfo -Name $cliName
            if (-not $commandInfo) {
                Write-Host "$cliName not found on PATH. Skipping." -ForegroundColor Yellow
                $results.Add([PSCustomObject]@{
                    Cli = $cliName
                    VersionBefore = ""
                    VersionAfter = ""
                    Strategy = "missing"
                    Status = "skipped"
                    ExitCode = ""
                    Notes = "Command not found on PATH"
                })
                continue
            }

            $versionBefore = Get-VersionString -CliName $cliName
            $selfUpdateArgs = Find-SelfUpdateCommand -CliName $cliName
            $strategy = $null
            $runner = $null
            $args = @()

            Write-Host ("Resolved path: " + $commandInfo.Path)
            if ($versionBefore) {
                Write-Host ("Version before: " + $versionBefore)
            }

            if (-not $packageName -and $commandInfo.Path) {
                $packageName = Get-PackageNameFromCommandWrapper -CommandPath $commandInfo.Path
                if ($packageName) {
                    Write-Host ("Inferred package name: " + $packageName)
                }
            }

            $stoppedProcesses = Stop-RunningCliProcesses -CliName $cliName
            if ($stoppedProcesses.Count -gt 0) {
                $stoppedPids = @($stoppedProcesses | Where-Object { $_.Stopped } | ForEach-Object { $_.ProcessId })
                $failedPids = @($stoppedProcesses | Where-Object { -not $_.Stopped } | ForEach-Object { $_.ProcessId })

                if ($stoppedPids.Count -gt 0) {
                    Write-Host ("Stopped running $cliName processes: " + ($stoppedPids -join ", ")) -ForegroundColor Yellow
                }
                if ($failedPids.Count -gt 0) {
                    Write-Host ("Failed to stop some $cliName processes: " + ($failedPids -join ", ")) -ForegroundColor DarkYellow
                }
            }

            if ($selfUpdateArgs -and (Test-AllowsSelfUpdate -CliName $cliName)) {
                $strategy = "self-update"
                $runner = $cliName
                $args = $selfUpdateArgs
            }
            else {
                $manager = Get-PackageManagerForCommand -CommandPath $commandInfo.Path -PnpmGlobalBin $pnpmGlobalBin
                switch ($manager) {
                    "npm" {
                        if (-not $packageName) {
                            $strategy = "unsupported"
                        }
                        else {
                            $npm = Get-Command npm -ErrorAction SilentlyContinue
                            if ($npm) {
                                $strategy = "npm"
                                $runner = $npm.Source
                                $args = @("install", "-g", "$packageName@latest")
                            }
                            else {
                                $strategy = "unsupported"
                            }
                        }
                    }
                    "pnpm" {
                        if (-not $packageName) {
                            $strategy = "unsupported"
                        }
                        else {
                            $pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
                            if ($pnpm) {
                                $strategy = "pnpm"
                                $runner = $pnpm.Source
                                $args = @("add", "-g", "$packageName@latest")
                            }
                            else {
                                $strategy = "unsupported"
                            }
                        }
                    }
                    default {
                        $strategy = "unsupported"
                    }
                }
            }

            if ($strategy -eq "unsupported") {
                Write-Host "Installed, but update strategy could not be determined safely. Skipping." -ForegroundColor Yellow
                $results.Add([PSCustomObject]@{
                    Cli = $cliName
                    VersionBefore = $versionBefore
                    VersionAfter = $versionBefore
                    Strategy = "unsupported"
                    Status = "skipped"
                    ExitCode = ""
                    Notes = "No self-update command and package-manager ownership was unknown or package name not configured"
                })
                continue
            }

            Write-Host ("Update strategy: " + $strategy) -ForegroundColor Green
            Write-Host ("Running: " + $runner + " " + ($args -join " "))

            $started = Get-Date
            $execution = Invoke-ExternalCommand -FilePath $runner -Arguments $args -TimeoutSeconds 1800
            $ended = Get-Date
            $duration = [math]::Round(($ended - $started).TotalSeconds, 1)

            if ($execution.StdOut) {
                Write-Host "--- stdout ---"
                Write-Host $execution.StdOut.TrimEnd()
            }
            if ($execution.StdErr) {
                Write-Host "--- stderr ---" -ForegroundColor DarkYellow
                Write-Host $execution.StdErr.TrimEnd()
            }

            $versionAfter = Get-VersionString -CliName $cliName
            $status = Get-UpdateStatus -Execution $execution -VersionBefore $versionBefore -VersionAfter $versionAfter -PackageName $packageName

            $results.Add([PSCustomObject]@{
                Cli = $cliName
                VersionBefore = $versionBefore
                VersionAfter = $versionAfter
                Strategy = $strategy
                Status = $status
                ExitCode = $execution.ExitCode
                Notes = "Duration ${duration}s"
            })
        }

        Write-Section "Summary"
        $results | Format-Table -AutoSize

        Write-Host ""
        Write-Host "Log saved to: $logPath" -ForegroundColor Cyan
    }
    finally {
        Stop-Transcript | Out-Null
    }
}

if (-not $SkipMain -and $env:AGENT_CLI_UPDATER_IMPORT_ONLY -ne "1") {
    Invoke-AgentCliUpdates
}
