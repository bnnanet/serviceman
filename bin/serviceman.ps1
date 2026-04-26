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
$Script:Version  = 'v1.0.1'
$Script:Date     = '2026-04-21T01:22-06:00'
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
    <#
    Consume the next positional arg, or the inline =value if present.
    Exits with an error if the flag is trailing and has no value.
    #>
    param(
        [string]$Flag,
        [bool]$HasInline,
        [string]$InlineValue,
        [string[]]$Argv,
        [ref]$Index
    )
    if ($HasInline) { return $InlineValue }
    if ($Index.Value -ge $Argv.Count) {
        Write-Host "error: '$Flag' requires a value" -ForegroundColor Red
        exit 1
    }
    $Value = $Argv[$Index.Value]
    $Index.Value++
    return $Value
}

function ConvertTo-CmdSafe {
    <# Escape % for use inside a .cmd batch file (where %x triggers expansion). #>
    param([string]$Value)
    return $Value -replace '%', '%%'
}

function Build-CmdLine {
    <#
    Quote and join a command path + arguments for a .cmd wrapper.
    Escapes embedded quotes and %; wraps in "..." when the arg contains
    whitespace or cmd metacharacters.
    #>
    param(
        [string]$CmdPath,
        [string[]]$CmdArgs
    )
    $Parts = [System.Collections.Generic.List[string]]::new()
    $Parts.Add("`"$(ConvertTo-CmdSafe $CmdPath)`"")
    foreach ($Arg in $CmdArgs) {
        $Safe = ConvertTo-CmdSafe $Arg
        if ($Safe -match '[\s&|<>^"()]' -or $Safe -eq '') {
            $Parts.Add("`"$($Safe -replace '"', '\"')`"")
        } else {
            $Parts.Add($Safe)
        }
    }
    return $Parts -join ' '
}

function Test-ValidTaskName {
    <# Return $true if $Name is a legal Windows Task Scheduler task name. #>
    param([string]$Name)
    if (-not $Name) { return $false }
    if ($Name -match '[\\/:*?"<>|]') { return $false }
    if ($Name -match '[\x00-\x1f]') { return $false }
    return $true
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
    --agent (default)  user login service (not always-on)
"@
    Show-ManageHelp 'SERVICE_NAME' -IsAgent
}

function Show-AddHelp {
    Write-Output @"

USAGE
    serviceman add [add-opts] -- <command> [command-opts]

FLAGS
    --nofiles-limit <n>  max open file descriptors (no effect on Windows)
    --dryrun  output service file without modifying system
    --force  install even if command or directory does not exist
    --daemon  system startup service (requires Administrator)
    --agent (default)  user login service (not always-on)
    --  stop reading flags (to prevent conflict with command)

OPTIONS
    --name <name>  the service name, defaults to the binary name
    --desc <description>  a brief description of the service
    --path <PATH>  defaults to current `$env:PATH (set to '' to disable)
    --title <title>  the service name, stylized
    --url <link-to-docs>  link to documentation or homepage
    --user <username>  defaults to '$env:USERNAME' (or SYSTEM for --daemon)
    --workdir <dirpath>  where the command runs, defaults to current directory

ADMINISTRATOR (--daemon mode)
    Run as Administrator, or grant rights in Local Security Policy.

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
    --agent (default)  list user login services (not always-on)

"@
}

function Show-StateHelp {
    param([string]$State)

    Write-Output @"

USAGE
    serviceman $State [flags] <name>

FLAGS
    --daemon  system startup service (requires Administrator)
    --agent (default)  user login service (not always-on)

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
            '--name'  { $Name    = Read-NextArg $Arg $HasInline $InlineValue $Argv ([ref]$i) }
            '--desc'  { $Desc    = Read-NextArg $Arg $HasInline $InlineValue $Argv ([ref]$i) }
            '--title' { $Title   = Read-NextArg $Arg $HasInline $InlineValue $Argv ([ref]$i) }
            '--url'   { $Url     = Read-NextArg $Arg $HasInline $InlineValue $Argv ([ref]$i) }
            '--user'  { $User    = Read-NextArg $Arg $HasInline $InlineValue $Argv ([ref]$i) }
            '--path'  { $SvcPath = Read-NextArg $Arg $HasInline $InlineValue $Argv ([ref]$i) }
            '--workdir' {
                $Raw = Read-NextArg $Arg $HasInline $InlineValue $Argv ([ref]$i)
                $Workdir = (Resolve-Path $Raw).Path
            }

            # ── Platform-inapplicable flags (consume value, warn) ──────────
            '--group' {
                $null = Read-NextArg $Arg $HasInline $InlineValue $Argv ([ref]$i)
                Write-Warning '--group has no effect on Windows'
            }
            '--rdns' {
                $null = Read-NextArg $Arg $HasInline $InlineValue $Argv ([ref]$i)
                Write-Warning '--rdns is only valid for launchctl (macOS)'
            }
            '--no-cap-net-bind'   { Write-Warning '--no-cap-net-bind has no effect on Windows' }
            '--nofiles-limit' {
                $null = Read-NextArg $Arg $HasInline $InlineValue $Argv ([ref]$i)
                Write-Warning '--nofiles-limit has no effect on Windows'
            }
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

    if ($IsDaemon -and $User -ne 'SYSTEM') {
        Write-Host "error: --daemon --user only supports 'SYSTEM' (Task Scheduler requires stored credentials for other accounts)" -ForegroundColor Red
        exit 1
    }

    # ── Resolve command ────────────────────────────────────────────────────

    $CmdInfo = Get-Command $Exec -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $CmdPath = if ($CmdInfo) { $CmdInfo.Source } else { '' }

    if (-not $CmdPath) {
        if (-not $Force) {
            Write-Host "error: '$Exec' not found (use --force to ignore)" -ForegroundColor Red
            exit 1
        }
        $CmdPath = $Exec
    }

    if (-not $Name)  { $Name  = [IO.Path]::GetFileNameWithoutExtension($Exec) }
    if (-not $Title) { $Title = $Name }
    if (-not $Desc)  { $Desc  = "$Title daemon" }

    if (-not (Test-ValidTaskName $Name)) {
        Write-Host "error: invalid service name '$Name' (must not contain \ / : * ? `" < > | or control chars)" -ForegroundColor Red
        exit 1
    }

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

    $CmdArgArray = $CmdArgs.ToArray()
    $SummaryParams = @{
        IsAgent = $IsAgent
        Name    = $Name
        Title   = $Title
        Desc    = $Desc
        Url     = $Url
        User    = $User
        Workdir = $Workdir
        SvcPath = $SvcPath
        CmdPath = $CmdPath
        CmdArgs = $CmdArgArray
        DryRun  = $DryRun
    }
    Write-ArgsSummary @SummaryParams
    Write-Host ''
    Start-Sleep -Milliseconds 500

    # ── Build wrapper ──────────────────────────────────────────────────────
    # Note: % must be escaped as %% in a .cmd file to avoid variable expansion.

    $ExecLine    = Build-CmdLine $CmdPath $CmdArgArray
    $SafeTitle   = ConvertTo-CmdSafe $Title
    $SafeDesc    = ConvertTo-CmdSafe $Desc
    $SafeUrl     = ConvertTo-CmdSafe $Url
    $SafeWorkdir = ConvertTo-CmdSafe $Workdir
    $SafePath    = ConvertTo-CmdSafe $SvcPath
    $SafeLog     = ConvertTo-CmdSafe $LogFile

    $WrapperContent = @"
@echo off
:: Generated for serviceman. Edit as needed. Keep this line for 'serviceman list'.
:: $SafeTitle - $SafeDesc
:: $SafeUrl

cd /d "$SafeWorkdir"
set "PATH=$SafePath"
$ExecLine >> "$SafeLog" 2>&1
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
    Write-Output "ok: $Name"
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
    Write-Host 'Task Scheduler (excluding Microsoft built-ins):'
    Write-Host ''

    # Skip Microsoft\ hierarchy — thousands of built-in Windows tasks that
    # drown out anything serviceman users actually care about.
    $Tasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -notmatch '^\\Microsoft\\' } |
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

    Write-Host "[serviceman\$($Parsed.Name)] starting..."
    Start-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name
}

function Invoke-Stop {
    param([string[]]$Argv)
    $Parsed = Read-StateArgs 'stop' $Argv
    if ($null -eq $Parsed) { return }

    Write-Host "[serviceman\$($Parsed.Name)] stopping..."
    Stop-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name
}

function Invoke-Restart {
    param([string[]]$Argv)
    $Parsed = Read-StateArgs 'restart' $Argv
    if ($null -eq $Parsed) { return }

    Write-Host "[serviceman\$($Parsed.Name)] restarting..."
    Stop-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Start-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name
}

function Invoke-Enable {
    param([string[]]$Argv)
    $Parsed = Read-StateArgs 'enable' $Argv
    if ($null -eq $Parsed) { return }

    Write-Host "[serviceman\$($Parsed.Name)] enabling..."
    Enable-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name | Out-Null
    Start-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name
}

function Invoke-Disable {
    param([string[]]$Argv)
    $Parsed = Read-StateArgs 'disable' $Argv
    if ($null -eq $Parsed) { return }

    Write-Host "[serviceman\$($Parsed.Name)] disabling..."
    Stop-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Parsed.Name -ErrorAction SilentlyContinue
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

    Write-Host "[serviceman\$($Parsed.Name)] tailing $LogFile"
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
