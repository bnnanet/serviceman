#Requires -Version 5.1

<#
.SYNOPSIS
    Cross-platform service manager for Windows.

.DESCRIPTION
    Manages Windows Scheduled Tasks as system (startup) and user (logon) services.
    Wraps executables in a .cmd launcher with log redirection and registers them
    as scheduled tasks under Task Scheduler Library > serviceman.

    Daemon mode (--daemon): runs as SYSTEM at startup, requires Administrator.
    Agent mode  (--agent):  runs as current user at logon (default).

.EXAMPLE
    serviceman add --name 'foo-app' -- .\foo-app.exe --bar

.EXAMPLE
    serviceman list

.LINK
    https://github.com/bnnanet/serviceman-sh
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ──────────────────────────────────────────────────────────────────

$Script:Year     = '2024'
$Script:Version  = 'v0.9.5'
$Script:Date     = '2024-12-23T00:25:00-07:00'
$Script:License  = 'MPL-2.0'
$Script:TaskPath = '\serviceman\'

# ── Config ─────────────────────────────────────────────────────────────────────

function Import-ConfigEnv {
    $ConfigPath = Join-Path $env:USERPROFILE '.config\serviceman\config.env'
    if (-not (Test-Path $ConfigPath)) { return }

    Write-Host "Loading $ConfigPath..."
    foreach ($Line in Get-Content $ConfigPath) {
        $Line = $Line.Trim()
        if ($Line -match '^export\s+(.+)$') { $Line = $Matches[1] }
        if (-not $Line -or $Line.StartsWith('#')) { continue }

        $Key, $Value = $Line -split '=', 2
        if ($null -ne $Value) {
            [Environment]::SetEnvironmentVariable($Key.Trim(), $Value.Trim().Trim("'`""), 'Process')
        }
    }
}

Import-ConfigEnv

# ── Helpers ────────────────────────────────────────────────────────────────────

function Test-Administrator {
    $Principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-NextArg {
    <# Consume the next positional arg, or the inline =value if present. #>
    param(
        [bool]$HasInline,
        [string]$InlineValue,
        [string[]]$Argv,
        [ref]$Index
    )
    if ($HasInline) { return $InlineValue }
    $Value = $Argv[$Index.Value]
    $Index.Value++
    return $Value
}

function Build-CmdLine {
    <# Quote and join a command path + arguments for a .cmd wrapper. #>
    param(
        [string]$CmdPath,
        [string[]]$CmdArgs
    )
    $Parts = [System.Collections.Generic.List[string]]::new()
    $Parts.Add("`"$CmdPath`"")
    foreach ($Arg in $CmdArgs) {
        if ($Arg -match '[\s&|<>^"%]') {
            $Parts.Add("`"$($Arg -replace '"', '\"')`"")
        } else {
            $Parts.Add($Arg)
        }
    }
    return $Parts -join ' '
}

# ── Help Display ───────────────────────────────────────────────────────────────

function Show-Version {
    Write-Output @"
serviceman $Script:Version ($Script:Date)
Copyright $Script:Year AJ ONeal
Licensed under the $Script:License
"@
}

function Show-Help {
    Show-Version
    Write-Output @"

USAGE
    serviceman <subcommand> --help

EXAMPLES
    serviceman add --name 'foo-app' -- .\foo-app.exe --bar
    serviceman list --all
    serviceman logs 'foo-app'

    serviceman disable 'foo-app'
    serviceman enable 'foo-app'
    serviceman start 'foo-app'
    serviceman stop 'foo-app'
    serviceman restart 'foo-app'

    serviceman help
    serviceman version

GLOBAL FLAGS
    --help can be used with any subcommand
    --daemon  system startup service (requires Administrator)
    --agent (default)  user login service
"@
    Show-ManageHelp 'SERVICE_NAME' -IsAgent
}

function Show-AddHelp {
    Write-Output @"

USAGE
    serviceman add [add-opts] -- <command> [command-opts]

FLAGS
    --dryrun  output service file without modifying system
    --force  install even if command or directory does not exist
    --daemon  system startup service (requires Administrator)
    --agent (default)  user login service
    --  stop reading flags (to prevent conflict with command)

OPTIONS
    --name <name>  the service name, defaults to binary or workdir name
    --desc <description>  a brief description of the service
    --path <PATH>  defaults to current `$env:PATH (set to '' to disable)
    --title <title>  the service name, stylized
    --url <link-to-docs>  link to documentation or homepage
    --user <username>  defaults to '$env:USERNAME' (or SYSTEM for --daemon)
    --workdir <dirpath>  where the command runs, defaults to current directory

EXAMPLES
    caddy:   serviceman add -- caddy.exe run --envfile .\.env --config .\Caddyfile --adapter caddyfile
    node:    serviceman add --workdir . --name 'api' -- node .\server.js
    pg:      serviceman add --name postgres -- pg_ctl.exe start -D C:\pgsql\data
    python:  serviceman add --name 'thing' -- python .\thing.py
    shell:   serviceman add --name 'foo' -- pwsh -File .\foo.ps1 --bar .\baz

"@
}

function Show-ListHelp {
    Write-Output @"

USAGE
    serviceman list [--all]

FLAGS
    --all  show all scheduled tasks, not just those generated by serviceman
    --daemon  list system startup services
    --agent (default)  list user login services

"@
}

function Show-StateHelp {
    param([string]$State)

    Write-Output @"

USAGE
    serviceman $State [flags] <name>

FLAGS
    --daemon  system startup service (requires Administrator)
    --agent (default)  user login service

"@
}

function Show-ManageHelp {
    param(
        [string]$Name,
        [switch]$IsAgent
    )

    $ServiceDir = if ($IsAgent) {
        "~\.local\share\$Name\"
    } else {
        "`$env:ProgramData\serviceman\$Name\"
    }

    Write-Output @"

How To Manage
    serviceman start '$Name'
    serviceman stop '$Name'
    serviceman restart '$Name'
    serviceman enable '$Name'
    serviceman disable '$Name'

Task Scheduler Location
    Task Scheduler Library > serviceman

Service File Locations
    $ServiceDir

How To View Logs
    serviceman logs '$Name'

"@
}

function Write-ArgsSummary {
    param(
        [bool]$IsAgent,
        [string]$Name,
        [string]$Title,
        [string]$Desc,
        [string]$Url,
        [string]$User,
        [string]$Workdir,
        [string]$SvcPath,
        [string]$CmdPath,
        [string[]]$CmdArgs,
        [bool]$DryRun
    )

    $QuotedArgs = @("'$CmdPath'") + ($CmdArgs | ForEach-Object { "'$_'" })
    $ArgsLine = $QuotedArgs -join ' '

    $ModeFlag = if ($IsAgent) { '--agent' } else { '--daemon' }
    $DryRunLine = if ($DryRun) { "        --dryrun ```n" } else { '' }

    Write-Host @"

Running 'serviceman' with the following options:
(may include ENVs from ~\.config\serviceman\config.env)

PATH=$SvcPath

    serviceman add ``
        --name '$Name' ``
        --url '$Url' ``
        --title '$Title' ``
        --desc '$Desc' ``
        --user '$User' ``
        --path "`$env:PATH" # SEE ABOVE ``
        --workdir '$Workdir' ``
        $ModeFlag ``
$DryRunLine        -- ``
        $ArgsLine
"@
}

# ── Arg Parsing ────────────────────────────────────────────────────────────────

function Read-StateArgs {
    <#
    Parse [--agent|--daemon] <name> for start/stop/restart/enable/disable/logs.
    Returns $null if --help was shown (caller should return).
    Exits on error.
    #>
    param(
        [string]$State,
        [string[]]$Argv
    )

    if ($null -eq $Argv) { $Argv = @() }

    $IsDaemon = $false
    $IsAgent  = $true
    $Name     = ''

    foreach ($Arg in $Argv) {
        if (-not $Arg) { continue }
        switch ($Arg) {
            { $_ -in 'help', '--help' } {
                Show-StateHelp $State
                return $null
            }
            '--agent' {
                $IsDaemon = $false
                $IsAgent  = $true
            }
            '--daemon' {
                $IsDaemon = $true
                $IsAgent  = $false
            }
            default {
                if ($Arg.StartsWith('-')) {
                    Write-Host "error: unrecognized option '$Arg'" -ForegroundColor Red
                    Show-StateHelp $State
                    exit 1
                }
                if ($Name) {
                    Write-Host "error: unrecognized argument '$Arg'" -ForegroundColor Red
                    Show-StateHelp $State
                    exit 1
                }
                $Name = $Arg
            }
        }
    }

    if (-not $Name) {
        Write-Host 'error: missing command name' -ForegroundColor Red
        exit 1
    }

    [PSCustomObject]@{
        Name     = $Name
        IsDaemon = $IsDaemon
        IsAgent  = $IsAgent
    }
}

# ── Commands ───────────────────────────────────────────────────────────────────

function Invoke-Add {
    param([string[]]$Argv)

    if ($null -eq $Argv) { $Argv = @() }

    # Parsed state
    $Exec        = ''
    $Name        = ''
    $Title       = ''
    $Desc        = ''
    $Url         = ''
    $Workdir     = ''
    $SvcPath     = $env:PATH
    $User        = ''
    $DryRun      = $false
    $Force       = $false
    $IsAgent     = $true
    $IsDaemon    = $false
    $DaemonSet   = $false
    $AgentSet    = $false
    $CmdArgs     = [System.Collections.Generic.List[string]]::new()
    $PastSep     = $false

    $i = 0
    while ($i -lt $Argv.Count) {
        $Arg = $Argv[$i]
        $i++

        # After --, everything is the command and its arguments
        if ($PastSep) {
            if (-not $Exec) { $Exec = $Arg } else { $CmdArgs.Add($Arg) }
            continue
        }

        # Split --key=value
        $HasInline   = $false
        $InlineValue = ''
        if ($Arg -match '^(--.+?)=(.*)$') {
            $HasInline   = $true
            $InlineValue = $Matches[2]
            $Arg         = $Matches[1]
        }

        switch ($Arg) {
            '--' {
                $PastSep = $true
            }
            { $_ -in 'help', '--help' } {
                Show-AddHelp
                return
            }

            # ── Boolean flags ──────────────────────────────────────────────
            '--dryrun' { $DryRun = $true }
            '--force'  { $Force  = $true }
            '--daemon' {
                $DaemonSet = $true
                if ($AgentSet) {
                    Write-Host 'error: --daemon and --agent are mutually exclusive' -ForegroundColor Red
                    exit 1
                }
                $IsDaemon = $true
                $IsAgent  = $false
            }
            '--agent' {
                $AgentSet = $true
                if ($DaemonSet) {
                    Write-Host 'error: --daemon and --agent are mutually exclusive' -ForegroundColor Red
                    exit 1
                }
                $IsDaemon = $false
                $IsAgent  = $true
            }

            # ── Options with values ────────────────────────────────────────
            '--name'  { $Name    = Read-NextArg $HasInline $InlineValue $Argv ([ref]$i) }
            '--desc'  { $Desc    = Read-NextArg $HasInline $InlineValue $Argv ([ref]$i) }
            '--title' { $Title   = Read-NextArg $HasInline $InlineValue $Argv ([ref]$i) }
            '--url'   { $Url     = Read-NextArg $HasInline $InlineValue $Argv ([ref]$i) }
            '--user'  { $User    = Read-NextArg $HasInline $InlineValue $Argv ([ref]$i) }
            '--path'  { $SvcPath = Read-NextArg $HasInline $InlineValue $Argv ([ref]$i) }
            '--workdir' {
                $Raw = Read-NextArg $HasInline $InlineValue $Argv ([ref]$i)
                $Workdir = (Resolve-Path $Raw).Path
            }

            # ── Platform-inapplicable flags (consume value, warn) ──────────
            '--group' {
                $null = Read-NextArg $HasInline $InlineValue $Argv ([ref]$i)
                Write-Warning '--group has no effect on Windows'
            }
            '--rdns' {
                $null = Read-NextArg $HasInline $InlineValue $Argv ([ref]$i)
                Write-Warning '--rdns is only valid for launchctl (macOS)'
            }
            '--no-cap-net-bind'   { Write-Warning '--no-cap-net-bind has no effect on Windows' }
            '--ignore-logind-ipc' { Write-Warning '--ignore-logind-ipc only applies to systemd service units' }

            # ── Bare argument = the executable ─────────────────────────────
            default {
                if ($Arg.StartsWith('--')) {
                    Write-Host "error: unrecognized option '$Arg'" -ForegroundColor Red
                    Show-AddHelp
                    exit 1
                }
                $Exec = $Arg
                while ($i -lt $Argv.Count) {
                    $CmdArgs.Add($Argv[$i])
                    $i++
                }
            }
        }
    }

    # ── Defaults & validation ──────────────────────────────────────────────

    if (-not $Exec) {
        Write-Host 'error: you must give at least the command to run' -ForegroundColor Red
        exit 1
    }

    if (-not $Url)     { $Url     = '(none)' }
    if (-not $Workdir) { $Workdir = (Get-Location).Path }
    if (-not $User) {
        $User = if ($IsDaemon) { 'SYSTEM' } else { $env:USERNAME }
    }

    if ($IsAgent -and $User -ne $env:USERNAME) {
        Write-Host "error: login services for '$env:USERNAME' cannot be set to '$User'" -ForegroundColor Red
        exit 1
    }

    if ($IsDaemon -and -not (Test-Administrator)) {
        Write-Host 'error: --daemon requires running as Administrator' -ForegroundColor Red
        exit 1
    }

    # ── Resolve command ────────────────────────────────────────────────────

    $CmdInfo = Get-Command $Exec -ErrorAction SilentlyContinue
    $CmdPath = if ($CmdInfo) { $CmdInfo.Source } else { '' }

    if (-not $CmdPath) {
        if (-not $Force) {
            Write-Host "error: '$Exec' not found (use --force to ignore)" -ForegroundColor Red
            exit 1
        }
        $CmdPath = $Exec
    }

    # Interpreted scripts default to workdir name; binaries default to exe name
    $IsInterpreted = $CmdPath -match '\.(py|js|rb|pl|php|ps1)$'

    if (-not $Name) {
        $Name = if ($IsInterpreted) {
            Split-Path -Leaf $Workdir
        } else {
            [IO.Path]::GetFileNameWithoutExtension($Exec)
        }
    }
    if (-not $Title) { $Title = $Name }
    if (-not $Desc)  { $Desc  = "$Title daemon" }

    # ── Validate path-like arguments ───────────────────────────────────────

    foreach ($PathArg in $CmdArgs) {
        # Absolute Windows path
        if ($PathArg -match '^[A-Za-z]:\\' -or $PathArg -match '^\/') {
            if (Test-Path $PathArg) { continue }
            if (-not $Force) {
                Write-Host "error: file or dir does not exist: '$PathArg' (use --force to ignore)" -ForegroundColor Red
                exit 1
            }
            Write-Warning "file or dir does not exist: '$PathArg'"
            continue
        }

        # Relative path with explicit prefix
        if ($PathArg -match '^\.[\\/]' -or $PathArg -match '^\.\.[\\\/]') {
            if (Test-Path (Join-Path $Workdir $PathArg)) { continue }
            if (-not $Force) {
                Write-Host "error: file or dir does not exist: '$PathArg' (use --force to ignore)" -ForegroundColor Red
                exit 1
            }
            Write-Warning "file or dir does not exist: '$PathArg'"
            continue
        }

        # Bare name that happens to exist as a file
        if ((Test-Path $PathArg) -or (Test-Path (Join-Path $Workdir $PathArg))) {
            if (-not $Force) {
                Write-Host "error: use .\ prefix for file or dir '$PathArg' (use --force to ignore)" -ForegroundColor Red
                exit 1
            }
            Write-Warning "use .\ prefix for file or dir '$PathArg'"
        }
    }

    # ── Paths ──────────────────────────────────────────────────────────────

    $ServiceDir = if ($IsDaemon) {
        Join-Path $env:ProgramData "serviceman\$Name"
    } else {
        Join-Path $env:USERPROFILE ".local\share\$Name"
    }
    $LogDir     = Join-Path $ServiceDir 'var\log'
    $LogFile    = Join-Path $LogDir "$Name.log"
    $WrapperCmd = Join-Path $ServiceDir "$Name.wrapper.cmd"

    # ── Summary ────────────────────────────────────────────────────────────

    Write-ArgsSummary `
        -IsAgent  $IsAgent `
        -Name     $Name `
        -Title    $Title `
        -Desc     $Desc `
        -Url      $Url `
        -User     $User `
        -Workdir  $Workdir `
        -SvcPath  $SvcPath `
        -CmdPath  $CmdPath `
        -CmdArgs  $CmdArgs.ToArray() `
        -DryRun   $DryRun
    Write-Host ''
    Start-Sleep -Milliseconds 500

    # ── Build wrapper ──────────────────────────────────────────────────────

    $ExecLine = Build-CmdLine $CmdPath $CmdArgs.ToArray()
    $WrapperContent = @"
@echo off
:: Generated for serviceman. Edit as needed. Keep this line for 'serviceman list'.
:: $Title - $Desc
:: $Url

cd /d "$Workdir"
set "PATH=$SvcPath"
$ExecLine >> "$LogFile" 2>&1
"@

    if ($DryRun) {
        Write-Output $WrapperContent
        return
    }

    # ── Install ────────────────────────────────────────────────────────────

    Write-Host 'Initializing scheduled task service...'

    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

    Write-Host "    create $WrapperCmd"
    Set-Content -Path $WrapperCmd -Value $WrapperContent -Encoding ASCII

    Write-Host "    create $LogFile"
    if (-not (Test-Path $LogFile)) {
        New-Item -Path $LogFile -ItemType File -Force | Out-Null
    }

    # ── Scheduled task ─────────────────────────────────────────────────────

    $Action = New-ScheduledTaskAction `
        -Execute 'cmd.exe' `
        -Argument "/c `"$WrapperCmd`"" `
        -WorkingDirectory $Workdir

    $Trigger = if ($IsDaemon) {
        New-ScheduledTaskTrigger -AtStartup
    } else {
        New-ScheduledTaskTrigger -AtLogon -User $User
    }

    $Principal = if ($IsDaemon) {
        New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    } else {
        New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    }

    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Seconds 3) `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew

    # Replace existing task if present
    $Existing = Get-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Name -ErrorAction SilentlyContinue
    if ($Existing) {
        Write-Host "    stop existing task: serviceman\$Name"
        Stop-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Name -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        Write-Host "    unregister existing task: serviceman\$Name"
        Unregister-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Name -Confirm:$false
    }

    Write-Host "    register task: serviceman\$Name"
    $TaskDef = New-ScheduledTask `
        -Action $Action `
        -Trigger $Trigger `
        -Principal $Principal `
        -Settings $Settings `
        -Description "$Title - $Desc"
    Register-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Name -InputObject $TaskDef | Out-Null

    Write-Host "    start task: serviceman\$Name"
    Start-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Name

    Start-Sleep -Milliseconds 500

    # Status
    $Info  = Get-ScheduledTaskInfo -TaskPath $Script:TaskPath -TaskName $Name
    $State = (Get-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Name).State
    Write-Host ''
    Write-Host "    Status: $State"
    Write-Host "    Last Run: $($Info.LastRunTime)"
    Write-Host "    Last Result: $($Info.LastTaskResult)"
    Write-Host ''
    Write-Host 'done'

    $ManageParams = @{ Name = $Name }
    if ($IsAgent) { $ManageParams.IsAgent = $true }
    Show-ManageHelp @ManageParams
}

function Invoke-List {
    param([string[]]$Argv)

    if ($null -eq $Argv) { $Argv = @() }

    $ShowAll = $false

    foreach ($Arg in $Argv) {
        if (-not $Arg) { continue }
        switch ($Arg) {
            { $_ -in 'help', '--help' } { Show-ListHelp; return }
            '--all'    { $ShowAll = $true }
            '--agent'  { <# accepted for compatibility #> }
            '--daemon' { <# accepted for compatibility #> }
            default {
                Write-Host "error: unrecognized option '$Arg'" -ForegroundColor Red
                Show-ListHelp
                exit 1
            }
        }
    }

    if (-not $ShowAll) {
        Write-Host ''
        Write-Host "Task Scheduler > serviceman: (Generated for serviceman)"
        Write-Host ''

        $Tasks = Get-ScheduledTask -TaskPath $Script:TaskPath -ErrorAction SilentlyContinue
        if (-not $Tasks) {
            Write-Host '    (none)'
        } else {
            foreach ($Task in $Tasks) {
                Write-Host "    $($Task.TaskName)"
            }
        }
        Write-Host ''
        return
    }

    Write-Host ''
    Write-Host 'Task Scheduler:'
    Write-Host ''

    $Tasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
        Sort-Object TaskPath, TaskName
    if (-not $Tasks) {
        Write-Host '    (none)'
    } else {
        foreach ($Task in $Tasks) {
            $Mark = if ($Task.TaskPath -eq $Script:TaskPath) { '*' } else { '' }
            Write-Host "    $($Task.TaskPath)$($Task.TaskName)$Mark"
        }
    }
    Write-Host ''
    Write-Host '* Generated for serviceman'
    Write-Host ''
}

function Invoke-Start {
    param([string[]]$Argv)
    $Parsed = Read-StateArgs 'start' $Argv
    if ($null -eq $Parsed) { return }

    Write-Host "Start-ScheduledTask -TaskPath '$Script:TaskPath' -TaskName '$($Parsed.Name)'"
    Start-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name
}

function Invoke-Stop {
    param([string[]]$Argv)
    $Parsed = Read-StateArgs 'stop' $Argv
    if ($null -eq $Parsed) { return }

    Write-Host "Stop-ScheduledTask -TaskPath '$Script:TaskPath' -TaskName '$($Parsed.Name)'"
    Stop-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name
}

function Invoke-Restart {
    param([string[]]$Argv)
    $Parsed = Read-StateArgs 'restart' $Argv
    if ($null -eq $Parsed) { return }

    Write-Host "Stop-ScheduledTask -TaskPath '$Script:TaskPath' -TaskName '$($Parsed.Name)'"
    Stop-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Write-Host "Start-ScheduledTask -TaskPath '$Script:TaskPath' -TaskName '$($Parsed.Name)'"
    Start-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name
}

function Invoke-Enable {
    param([string[]]$Argv)
    $Parsed = Read-StateArgs 'enable' $Argv
    if ($null -eq $Parsed) { return }

    Write-Host "Enable-ScheduledTask -TaskPath '$Script:TaskPath' -TaskName '$($Parsed.Name)'"
    Enable-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name | Out-Null
    Write-Host "Start-ScheduledTask -TaskPath '$Script:TaskPath' -TaskName '$($Parsed.Name)'"
    Start-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name
}

function Invoke-Disable {
    param([string[]]$Argv)
    $Parsed = Read-StateArgs 'disable' $Argv
    if ($null -eq $Parsed) { return }

    Write-Host "Stop-ScheduledTask -TaskPath '$Script:TaskPath' -TaskName '$($Parsed.Name)'"
    Stop-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name -ErrorAction SilentlyContinue
    Write-Host "Disable-ScheduledTask -TaskPath '$Script:TaskPath' -TaskName '$($Parsed.Name)'"
    Disable-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name | Out-Null
}

function Invoke-Logs {
    param([string[]]$Argv)
    $Parsed = Read-StateArgs 'logs' $Argv
    if ($null -eq $Parsed) { return }

    $LogFile = if ($Parsed.IsDaemon) {
        Join-Path $env:ProgramData "serviceman\$($Parsed.Name)\var\log\$($Parsed.Name).log"
    } else {
        Join-Path $env:USERPROFILE ".local\share\$($Parsed.Name)\var\log\$($Parsed.Name).log"
    }

    if (-not (Test-Path $LogFile)) {
        Write-Host "error: log file not found: $LogFile" -ForegroundColor Red
        exit 1
    }

    Write-Host "Get-Content -Wait '$LogFile'"
    Get-Content -Wait -Tail 50 $LogFile
}

# ── Entry Point ────────────────────────────────────────────────────────────────

$Cmd     = if ($args.Count -gt 0) { $args[0] } else { '' }
$CmdArgs = if ($args.Count -gt 1) { @($args[1..($args.Count - 1)]) } else { @() }

switch ($Cmd) {
    'add'       { Invoke-Add $CmdArgs }
    'list'      { Invoke-List $CmdArgs }
    'start'     { Invoke-Start $CmdArgs }
    'stop'      { Invoke-Stop $CmdArgs }
    'restart'   { Invoke-Restart $CmdArgs }
    'enable'    { Invoke-Enable $CmdArgs }
    'disable'   { Invoke-Disable $CmdArgs }
    'logs'      { Invoke-Logs $CmdArgs }
    '__noop__'  { <# source without running #> }
    { $_ -in 'help', '--help' }              { Show-Help }
    { $_ -in 'version', '--version', '-V' }  { Show-Version }
    default {
        Write-Host "error: unrecognized option '$Cmd'" -ForegroundColor Red
        Write-Host ''
        Show-Help
        exit 1
    }
}
