#Requires -Version 5.1
<#
.SYNOPSIS
    Behavioural tests for the parts of ServerPatchTool.ps1 that do not need a
    live server or a window.
.DESCRIPTION
    The tool is a single file that builds a WPF window at load time, so it
    cannot simply be dot-sourced. Instead each unit under test is located in
    the real file with the PowerShell parser and evaluated on its own, against
    stubs. That way these tests exercise the shipped code rather than a copy of
    it, and they fail loudly if the code they target is moved or renamed.

    Covered:
      1. Job completion timer  - callbacks that start further jobs must not
                                 break the tick that is running them.
      2. Install result        - a partly failed install must not be reported
                                 as a clean one, and a watch that ran out of
                                 time must not be reported as a failure.
      3. Credential selection  - a server must use its own credential, and a
                                 credential that no longer exists must not be
                                 substituted silently.
      4. Credential removal    - a deleted account must not come back after a
                                 restart, including the last one.
      5. Post-reboot monitor   - losing the monitor must not be reported as a
                                 broken server, and never without a reason.
      6. Monitor launch        - the watch must be handed a real script block
                                 and a server name, neither of which survives
                                 being started from inside a closure.
      7. AD import             - found servers must reach the grid, once each.
      8. Sequential queues     - the "run in progress" flags must be cleared
                                 when the queue drains, closures included.
      9. Deferred re-checks    - a server the tool stopped watching must be
                                 asked again, and eventually given up on.
     10. Time limits           - the install and reboot settings are read,
                                 with sane fallbacks.

    Not covered: anything that talks to a live server, and the UI event
    handlers whose logic still sits inside the handler itself.

    Exits with code 1 if any check fails.
.NOTES
    Run: powershell -NoProfile -ExecutionPolicy Bypass -File _tests.ps1
#>

$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot 'ServerPatchTool.ps1'

$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    Write-Host "Cannot run: ServerPatchTool.ps1 has syntax errors. Run _validate.ps1." -ForegroundColor Red
    exit 1
}

# ---- harness ----------------------------------------------------------------
$script:Failures = 0
$script:Checks   = 0

function Section { param([string]$Title) Write-Host ""; Write-Host "=== $Title ===" -ForegroundColor Cyan }
function Case    { param([string]$Title) Write-Host "  $Title" -ForegroundColor Gray }

function Check {
    param([string]$Label, $Condition)
    $script:Checks++
    if ($Condition) {
        Write-Host "    OK   $Label" -ForegroundColor Green
    } else {
        Write-Host "    FAIL $Label" -ForegroundColor Red
        $script:Failures++
    }
}

# Source of one function from the real file. The caller runs it through
# Invoke-Expression at script level: doing that in here would define the
# function inside this function's own scope, where it dies on return.
function Get-FunctionText {
    param([string]$Name)
    $fn = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq $Name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "function '$Name' not found in ServerPatchTool.ps1" }
    return $fn.Extent.Text
}

# Source of one top-level assignment (a setting, a default), so the tests
# follow the shipped value instead of restating it.
function Get-AssignmentText {
    param([string]$VariablePath)
    $node = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq $VariablePath }, $true) | Select-Object -First 1
    if (-not $node) { throw "assignment to '$VariablePath' not found in ServerPatchTool.ps1" }
    return $node.Extent.Text
}

# Returns the body of an event handler, e.g. the argument of $timer.Add_Tick({...}).
function Get-HandlerBody {
    param([string]$Member)
    $call = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member.Value -eq $Member }, $true) | Select-Object -First 1
    if (-not $call) { throw "handler '$Member' not found in ServerPatchTool.ps1" }
    return [ScriptBlock]::Create($call.Arguments[0].ScriptBlock.EndBlock.Extent.Text)
}

# ---- shared stubs -----------------------------------------------------------
$script:Logged = @()
function Write-Log { param($Message, $Level = 'INFO') $script:Logged += "$Level|$Message" }
function Show-Progress { param([bool]$Visible) }
function Step-Progress { }
function Update-StatusBar { param($Text) }

# The re-check settings are real, so the messages that quote them read the same
# here as they do in the tool. The two functions start as stubs because the job
# timer and the install handler call them long before the section that tests
# them; that section replaces these with the shipped versions.
Invoke-Expression (Get-AssignmentText -VariablePath '$script:PendingRechecks')
Invoke-Expression (Get-AssignmentText -VariablePath '$script:RecheckInterval')
Invoke-Expression (Get-AssignmentText -VariablePath '$script:RecheckAttempts')
function Add-PendingRecheck   { param([string]$ServerName) }
function Step-PendingRechecks { }

function Get-LoggedLike { param([string]$Pattern) @($script:Logged | Where-Object { $_ -like $Pattern }) }


# =============================================================================
Section "Job completion timer"
# The tick used to enumerate $ActiveJobs live while callbacks added to it, which
# throws "Collection was modified" - and every sequential install and every
# reboot does exactly that.
# =============================================================================
$tick = Get-HandlerBody -Member 'Add_Tick'

$script:ActiveJobs      = [System.Collections.Generic.List[PSObject]]::new()
$script:SequentialQueue = [System.Collections.Generic.Queue[string]]::new()
$script:RebootQueue     = [System.Collections.Generic.Queue[string]]::new()
$ui = @{ btnStop = (New-Object PSObject -Property @{ IsEnabled = $false }) }

$script:Disposed = @()
function New-FakeJob {
    param([string]$Name, [ScriptBlock]$OnComplete, [bool]$Completed = $true)
    $ps = New-Object PSObject
    $ps | Add-Member NoteProperty JobName $Name
    $ps | Add-Member ScriptMethod EndInvoke { param($h) return "result-of-$($this.JobName)" }
    $ps | Add-Member ScriptMethod Dispose   { $script:Disposed += $this.JobName }
    [PSCustomObject]@{
        PowerShell = $ps
        Handle     = [PSCustomObject]@{ IsCompleted = $Completed }
        OnComplete = $OnComplete
        Name       = $Name
    }
}

function Invoke-Tick {
    $script:TickError = $null
    try { & $tick } catch { $script:TickError = $_ }
}

Case "a callback starts the next job, as a sequential install does"
$script:Ran = @(); $script:Logged = @(); $script:Disposed = @()
$chained = {
    param($result)
    $script:Ran += 'first'
    $next = New-FakeJob -Name 'second' -OnComplete { param($r) $script:Ran += 'second' } -Completed $false
    $script:ActiveJobs.Add($next)
}
$script:ActiveJobs.Add((New-FakeJob -Name 'first' -OnComplete $chained))
Invoke-Tick
Check "tick did not throw"                     ($null -eq $script:TickError)
if ($script:TickError) { Write-Host "         $($script:TickError.Exception.Message)" -ForegroundColor DarkRed }
Check "the callback ran"                       ($script:Ran -contains 'first')
Check "finished job left ActiveJobs"           (-not (@($script:ActiveJobs).Name -contains 'first'))
Check "newly started job stayed in ActiveJobs" (@($script:ActiveJobs).Name -contains 'second')
Check "nothing logged as a job error"          ((Get-LoggedLike '*Job error*').Count -eq 0)
Check "finished job disposed exactly once"     (@($script:Disposed | Where-Object { $_ -eq 'first' }).Count -eq 1)

Case "the next tick must not process the same job again"
$script:Ran = @(); $script:Logged = @()
Invoke-Tick
Check "callback did not run a second time"     (-not ($script:Ran -contains 'first'))
Check "no phantom job error appeared"          ((Get-LoggedLike '*Job error*').Count -eq 0)

Case "several jobs finish in one tick, each starting another"
$script:ActiveJobs.Clear(); $script:Ran = @(); $script:Logged = @()
foreach ($n in 'a', 'b', 'c') {
    # Built as text rather than with .GetNewClosure(): a closure is bound to a
    # module of its own, so "$script:Ran +=" inside one would never reach this
    # script's $Ran and the case would silently prove nothing.
    $cb = [ScriptBlock]::Create(@"
param(`$result)
`$script:Ran += '$n'
`$follow = New-FakeJob -Name '$n-follow' -OnComplete { param(`$r) } -Completed `$false
`$script:ActiveJobs.Add(`$follow)
"@)
    $script:ActiveJobs.Add((New-FakeJob -Name $n -OnComplete $cb))
}
Invoke-Tick
Check "tick did not throw"                     ($null -eq $script:TickError)
Check "all three callbacks ran in one tick"    ($script:Ran.Count -eq 3)
Check "all three follow-ups are queued"        (@($script:ActiveJobs).Count -eq 3)
Check "no finished job was left behind"        (@(@($script:ActiveJobs).Name | Where-Object { $_ -in 'a', 'b', 'c' }).Count -eq 0)

Case "a callback that throws must not abandon the rest of the tick"
$script:ActiveJobs.Clear(); $script:Ran = @(); $script:Logged = @()
$script:ActiveJobs.Add((New-FakeJob -Name 'boom' -OnComplete { param($r) throw 'callback exploded' }))
$script:ActiveJobs.Add((New-FakeJob -Name 'ok'   -OnComplete { param($r) $script:Ran += 'ok' }))
Invoke-Tick
Check "tick did not throw"                     ($null -eq $script:TickError)
Check "the failure was logged once"            ((Get-LoggedLike 'ERROR|Job error*').Count -eq 1)
Check "the following job still ran"            ($script:Ran -contains 'ok')
Check "ActiveJobs is empty afterwards"         (@($script:ActiveJobs).Count -eq 0)


# =============================================================================
Section "Install result reporting"
# A partly failed install used to be shown as "Up to date" with Available = 0.
# =============================================================================
Invoke-Expression (Get-FunctionText -Name 'Complete-InstallResult')

$script:Props   = @{}
$script:Rescans = @()
function Update-ServerEntry { param($ServerName, $Properties) $script:Props = $Properties }
function Invoke-ScanServer  { param($ServerName, [switch]$NoProgress) $script:Rescans += $ServerName }

function Invoke-Install {
    param([string]$ServerName, [hashtable]$Result)
    $script:Props = @{}; $script:Rescans = @(); $script:Logged = @()
    Complete-InstallResult -ServerName $ServerName -Result ([PSCustomObject]$Result)
}

Case "three updates installed, two failed, no reboot"
Invoke-Install -ServerName 'srv-a' -Result @{
    Success = $true; InstalledCount = 3; FailedCount = 2; RebootRequired = $false
    InstalledTitles = @('KB1', 'KB2', 'KB3')
    FailedTitles    = @('Update X (result code 4)', 'Update Y (result code 4)')
    Message = 'Installed 3 of 5 update(s), 2 failed'; Error = '2 update(s) failed to install'
}
Check "status is not a clean one"              ($script:Props.Status -eq 'Completed with errors')
Check "the two failures count as available"    ($script:Props.Available -eq '2')
Check "installed count is reported"            ($script:Props.Installed -eq '3')
Check "details name the failed updates"        ($script:Props.Details -match 'Update X' -and $script:Props.Details -match 'Update Y')
Check "each failure is logged as a warning"    ((Get-LoggedLike 'WARN|*').Count -ge 2)
Check "a confirming rescan was started"        ($script:Rescans -contains 'srv-a')

Case "everything installed, no reboot needed"
Invoke-Install -ServerName 'srv-b' -Result @{
    Success = $true; InstalledCount = 4; FailedCount = 0; RebootRequired = $false
    InstalledTitles = @('KB1'); FailedTitles = @(); Message = 'Installed 4 update(s)'; Error = $null
}
Check "status is up to date"                   ($script:Props.Status -eq 'Up to date')
Check "nothing is left available"              ($script:Props.Available -eq '0')
Check "a confirming rescan was started"        ($script:Rescans -contains 'srv-b')

Case "everything installed, reboot needed"
Invoke-Install -ServerName 'srv-c' -Result @{
    Success = $true; InstalledCount = 2; FailedCount = 0; RebootRequired = $true
    InstalledTitles = @('KB1'); FailedTitles = @(); Message = 'Installed 2 update(s)'; Error = $null
}
Check "status asks for a reboot"               ($script:Props.Status -eq 'Reboot Required')
Check "the reboot column says Yes"             ($script:Props.RebootRequired -eq 'Yes')
Check "no rescan before the reboot"            ($script:Rescans.Count -eq 0)

Case "partly failed and a reboot is needed"
Invoke-Install -ServerName 'srv-d' -Result @{
    Success = $true; InstalledCount = 1; FailedCount = 1; RebootRequired = $true
    InstalledTitles = @('KB1'); FailedTitles = @('Update Z (result code 5)')
    Message = 'Installed 1 of 2 update(s), 1 failed'; Error = '1 update(s) failed to install'
}
Check "the errors take the status"             ($script:Props.Status -eq 'Completed with errors')
Check "reboot flag survives for Reboot All"    ($script:Props.RebootRequired -eq 'Yes')
Check "the post-reboot monitor rescans, not us" ($script:Rescans.Count -eq 0)

Case "the tool stopped watching before the install ended"
Invoke-Install -ServerName 'srv-e' -Result @{
    Success = $false; TimedOut = $true; TaskName = 'SPT_Install_0000'
    Error = "Install still going after 90 minutes. Task 'SPT_Install_0000' was left running on SRV-E"
    Message = 'Still running'
}
Check "this is not reported as an error"       ($script:Props.Status -eq 'Still installing')
Check "details say the install continues"      ($script:Props.Details -match 'still running on the server')
Check "no rescan is started yet"               ($script:Rescans.Count -eq 0)

Case "the operation really failed"
Invoke-Install -ServerName 'srv-f' -Result @{ Success = $false; Error = 'WinRM connection failed' }
Check "status is an error"                     ($script:Props.Status -eq 'Error')
Check "the cause is kept"                      ($script:Props.Details -match 'WinRM connection failed')
Check "no rescan after a failure"              ($script:Rescans.Count -eq 0)


# =============================================================================
Section "Credential selection"
# Removing a credential could leave servers pointing at it; the substitute must
# at least be recorded.
# =============================================================================
Invoke-Expression (Get-FunctionText -Name 'Get-ServerCredential')

# A plain hashtable, as the tool itself uses - an [ordered] one has no
# ContainsKey and would fail for a reason that has nothing to do with the code
# under test. Key order is therefore undefined, so no case below may depend on
# which credential the fallback happens to pick.
$script:Credentials = @{ 'DOM1\user-a' = 'cred-A'; 'DOM2\user-b' = 'cred-B' }
$script:DefaultCredentialLabel = 'DOM1\user-a'
$script:ServerData = @(
    [PSCustomObject]@{ ServerName = 'srv-own';     CredentialLabel = 'DOM2\user-b' }
    [PSCustomObject]@{ ServerName = 'srv-default'; CredentialLabel = '' }
    [PSCustomObject]@{ ServerName = 'srv-stale';   CredentialLabel = 'DOM3\deleted' }
)

Case "a server with its own credential"
$script:Logged = @()
Check "its own credential is used"             ((Get-ServerCredential -ServerName 'srv-own') -eq 'cred-B')
Check "nothing is warned about"                ((Get-LoggedLike 'WARN|*').Count -eq 0)

Case "a server without one falls back to the default"
$script:Logged = @()
Check "the default is used"                    ((Get-ServerCredential -ServerName 'srv-default') -eq 'cred-A')
Check "nothing is warned about"                ((Get-LoggedLike 'WARN|*').Count -eq 0)

Case "a server pointing at a credential that was removed"
$script:Logged = @()
$got = Get-ServerCredential -ServerName 'srv-stale'
Check "some credential is still returned"      ($null -ne $got)
Check "the substitution is warned about"       ((Get-LoggedLike 'WARN|*no longer exists*').Count -eq 1)
Check "the warning names the server"           ((Get-LoggedLike 'WARN|srv-stale*').Count -eq 1)

Case "no credentials at all"
$script:Credentials = @{}
$script:DefaultCredentialLabel = $null
Check "nothing is invented"                    ($null -eq (Get-ServerCredential -ServerName 'srv-own'))


# =============================================================================
Section "Credential removal survives a restart"
# Removing a credential updated memory and servers.json but never rewrote
# credentials.json, so the next launch read the deleted account back in.
# These cases run the real save/load pair over a temporary file.
# =============================================================================
Invoke-Expression (Get-FunctionText -Name 'Remove-CredentialSet')
Invoke-Expression (Get-FunctionText -Name 'Save-Credentials')
Invoke-Expression (Get-FunctionText -Name 'Load-Credentials')
Invoke-Expression (Get-FunctionText -Name 'Remove-SavedCredentials')

function Update-CredentialStatus { }
function Save-ServerList { }

$script:CredDir  = Join-Path $env:TEMP "spt-tests-$PID"
$script:CredFile = Join-Path $script:CredDir 'credentials.json'
$ui = @{
    chkRememberCredentials = [PSCustomObject]@{ IsChecked = $true }
    dgServers              = [PSCustomObject]@{ Items = (New-Object PSObject) }
}
$ui.dgServers.Items | Add-Member ScriptMethod Refresh { }

# Synthetic accounts with a throwaway password - never a real secret.
function New-TestCredential {
    param([string]$UserName)
    New-Object System.Management.Automation.PSCredential(
        $UserName, (ConvertTo-SecureString 'placeholder-not-a-secret' -AsPlainText -Force))
}

function Reset-CredentialFixture {
    $script:Credentials = @{
        'DOM1\user-a' = (New-TestCredential 'DOM1\user-a')
        'DOM2\user-b' = (New-TestCredential 'DOM2\user-b')
    }
    $script:DefaultCredentialLabel = 'DOM1\user-a'
    $script:ServerData = @([PSCustomObject]@{ ServerName = 'srv-1'; CredentialLabel = 'DOM2\user-b' })
    $script:Logged = @()
    Save-Credentials
}

# Stands in for closing and reopening the tool: memory is dropped, disk is not.
function Invoke-Restart {
    $script:Credentials = @{}
    $script:DefaultCredentialLabel = $null
    Load-Credentials | Out-Null
}

Case "a removed credential must not come back after a restart"
Reset-CredentialFixture
Check "both accounts were saved to begin with" ((Get-Content -LiteralPath $script:CredFile -Raw) -match 'DOM2')
Remove-CredentialSet -Label 'DOM2\user-b' | Out-Null
Check "it is gone from memory straight away"   (-not $script:Credentials.ContainsKey('DOM2\user-b'))
Invoke-Restart
Check "it is still gone after a restart"       (-not $script:Credentials.ContainsKey('DOM2\user-b'))
Check "the other account survived"             ($script:Credentials.ContainsKey('DOM1\user-a'))

Case "removing the default one keeps a usable default after a restart"
Reset-CredentialFixture
Remove-CredentialSet -Label 'DOM1\user-a' | Out-Null
Invoke-Restart
Check "the deleted default did not come back"  (-not $script:Credentials.ContainsKey('DOM1\user-a'))
Check "the survivor became the default"        ($script:DefaultCredentialLabel -eq 'DOM2\user-b')

Case "removing the last credential leaves nothing behind"
Reset-CredentialFixture
Remove-CredentialSet -Label 'DOM1\user-a' | Out-Null
Remove-CredentialSet -Label 'DOM2\user-b' | Out-Null
Invoke-Restart
Check "no credential is restored"              ($script:Credentials.Count -eq 0)
Check "no misleading decryption warning"       ((Get-LoggedLike '*could not be decrypted*').Count -eq 0)

Case "removing something that is not there changes nothing"
Reset-CredentialFixture
$before = $script:Credentials.Count
Check "the call reports it did nothing"        ((Remove-CredentialSet -Label 'DOM9\nobody') -eq $false)
Check "no credential was dropped"              ($script:Credentials.Count -eq $before)

if (Test-Path -LiteralPath $script:CredDir) {
    Remove-Item -LiteralPath $script:CredDir -Recurse -Force -ErrorAction SilentlyContinue
}


# =============================================================================
Section "Reboot monitor launch"
# The monitor used to be started from inside the reboot callback, which is a
# closure. A closure sees neither $script: variables nor anything captured by an
# enclosing closure, so the job was handed a null script block - finishing at
# once with no output - and its own callback had no server name in it.
# =============================================================================
Invoke-Expression (Get-AssignmentText -VariablePath '$script:RebootMonitorScript')
Invoke-Expression (Get-AssignmentText -VariablePath '$script:RebootTimeoutDefault')
Invoke-Expression (Get-FunctionText   -Name 'Get-RebootTimeout')
Invoke-Expression (Get-FunctionText   -Name 'Start-RebootMonitor')

$script:Launched = $null
$script:Watched  = @()
$script:Advanced = 0
function Start-AsyncJob {
    param([ScriptBlock]$ScriptBlock, [object[]]$Arguments, [ScriptBlock]$OnComplete)
    $script:Launched = [PSCustomObject]@{
        ScriptBlock = $ScriptBlock; Arguments = $Arguments; OnComplete = $OnComplete
    }
}
function Get-ServerCredential   { param([string]$ServerName) "cred-for-$ServerName" }
function Complete-RebootMonitor { param([string]$ServerName, $Monitor) $script:Watched += $ServerName }
function Step-RebootQueue       { param([switch]$AfterFailure) $script:Advanced++ }

$baseline = Get-Date

Case "the job is given everything it needs"
$script:Launched = $null; $script:Watched = @(); $script:Advanced = 0
Start-RebootMonitor -ServerName 'srv-x' -BootBefore $baseline
Check "a job was started"                      ($null -ne $script:Launched)
Check "it got a real script block"             ($script:Launched.ScriptBlock -is [ScriptBlock])
Check "the script block is not empty"          ($script:Launched.ScriptBlock.ToString().Trim().Length -gt 0)
Check "the server name reaches the job"        ($script:Launched.Arguments[0] -eq 'srv-x')
Check "its own credential reaches the job"     ($script:Launched.Arguments[1] -eq 'cred-for-srv-x')
Check "the boot-time baseline reaches the job" ($script:Launched.Arguments[2] -eq $baseline)
Check "the watch limit reaches the job"        ($script:Launched.Arguments[3] -eq $script:RebootTimeoutDefault)

Case "the callback still knows which server it is watching"
& $script:Launched.OnComplete ([PSCustomObject]@{ Phase = 'Online' })
Check "the server name survived into the callback" ($script:Watched -contains 'srv-x')
Check "nothing was reported for a nameless server" (-not ($script:Watched -contains ''))

Case "a single reboot does not touch the queue"
Check "the queue was not advanced"             ($script:Advanced -eq 0)

Case "a sequential reboot hands the queue on"
$script:Launched = $null; $script:Watched = @(); $script:Advanced = 0
Start-RebootMonitor -ServerName 'srv-y' -BootBefore $baseline -Sequential
& $script:Launched.OnComplete ([PSCustomObject]@{ Phase = 'Online' })
Check "the right server was reported"          ($script:Watched -contains 'srv-y')
Check "the queue moved on exactly once"        ($script:Advanced -eq 1)


# =============================================================================
Section "Active Directory import"
# Same defect: this ran inside a completion closure, where $script:ServerData
# and $window are empty, so every name looked new and the add hit nothing.
# =============================================================================
Invoke-Expression (Get-FunctionText -Name 'Complete-ADImport')

function New-ServerEntry    { param([string]$Name) [PSCustomObject]@{ ServerName = $Name.ToUpper() } }
function Update-ServerCount { }

function Reset-Grid {
    param([string[]]$Existing = @())
    $script:ServerData = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
    foreach ($e in $Existing) { $script:ServerData.Add((New-ServerEntry -Name $e)) }
    $script:Logged = @()
}

Case "servers found in AD are added"
Reset-Grid
Complete-ADImport -Result ([PSCustomObject]@{ Success = $true; Servers = @('srv-1','srv-2'); Error = $null })
Check "both were added"                        ($script:ServerData.Count -eq 2)
Check "names are normalised"                   (@($script:ServerData.ServerName) -contains 'SRV-1')
Check "the count is logged"                    ((Get-LoggedLike '*added 2 new*').Count -eq 1)

Case "servers already in the grid are not duplicated"
Reset-Grid -Existing @('srv-1')
Complete-ADImport -Result ([PSCustomObject]@{ Success = $true; Servers = @('SRV-1','srv-2'); Error = $null })
Check "only the new one was added"             ($script:ServerData.Count -eq 2)
Check "the duplicate was skipped"              ((Get-LoggedLike '*added 1 new*').Count -eq 1)

Case "a failed query is reported, not swallowed"
Reset-Grid
Complete-ADImport -Result ([PSCustomObject]@{ Success = $false; Servers = @(); Error = 'AD server unreachable' })
Check "nothing was added"                      ($script:ServerData.Count -eq 0)
Check "the failure is an error in the log"     ((Get-LoggedLike 'ERROR|*AD server unreachable*').Count -eq 1)


# =============================================================================
Section "Sequential queue tail"
# The completion callbacks are closures, and a closure is bound to a module of
# its own: an assignment to a $script: variable inside one sets a copy and never
# reaches the flag the batch buttons read. Clearing the "a run is in progress"
# flag from there left it stuck for the rest of the session, so no further batch
# could be started. Hence these functions - and hence the closure cases below,
# which fail again the moment the tail is inlined back into a callback.
# =============================================================================
Invoke-Expression (Get-FunctionText -Name 'Step-SequentialInstallQueue')
Invoke-Expression (Get-FunctionText -Name 'Step-RebootQueue')

$script:Started = @()
function Invoke-InstallServerSequential { param($ServerName) $script:Started += $ServerName }
function Invoke-RebootServerSequential  { param($ServerName) $script:Started += $ServerName }

Case "an install queue that still has servers in it"
$script:Started = @(); $script:Logged = @()
$script:SequentialRunning = $true
$script:SequentialQueue.Clear()
$script:SequentialQueue.Enqueue('srv-2'); $script:SequentialQueue.Enqueue('srv-3')
Step-SequentialInstallQueue
Check "the next server was started"            ($script:Started -contains 'srv-2')
Check "only one server was started"            ($script:Started.Count -eq 1)
Check "the rest stays queued"                  ($script:SequentialQueue.Count -eq 1)
Check "the run is still marked as running"     ($script:SequentialRunning)

Case "the last install in the queue has finished"
$script:Started = @(); $script:Logged = @()
$script:SequentialRunning = $true
$script:SequentialQueue.Clear()
Step-SequentialInstallQueue
Check "nothing further was started"            ($script:Started.Count -eq 0)
Check "the run is no longer marked running"    (-not $script:SequentialRunning)
Check "completion was logged"                  ((Get-LoggedLike '*queue completed*').Count -eq 1)

Case "the tail runs inside a closure, as it does in the tool"
$script:Started = @(); $script:Logged = @()
$script:SequentialRunning = $true
$script:SequentialQueue.Clear()
$callback = { param($result) Step-SequentialInstallQueue }.GetNewClosure()
& $callback 'ignored'
Check "the flag was cleared from inside a closure" (-not $script:SequentialRunning)

Case "a reboot queue that still has servers in it"
$script:Started = @(); $script:Logged = @()
$script:RebootQueueRunning = $true
$script:RebootQueue.Clear()
$script:RebootQueue.Enqueue('srv-2')
Step-RebootQueue
Check "the next server was started"            ($script:Started -contains 'srv-2')
Check "the run is still marked as running"     ($script:RebootQueueRunning)

Case "a reboot failed but others are still queued"
$script:Started = @(); $script:Logged = @()
$script:RebootQueueRunning = $true
$script:RebootQueue.Clear()
$script:RebootQueue.Enqueue('srv-3')
Step-RebootQueue -AfterFailure
Check "the queue is not abandoned"             ($script:Started -contains 'srv-3')
Check "the log says why it moved on"           ((Get-LoggedLike '*previous failed*').Count -eq 1)

Case "the last reboot in the queue has finished"
$script:Started = @(); $script:Logged = @()
$script:RebootQueueRunning = $true
$script:RebootQueue.Clear()
Step-RebootQueue
Check "nothing further was started"            ($script:Started.Count -eq 0)
Check "the run is no longer marked running"    (-not $script:RebootQueueRunning)

Case "the reboot tail runs inside a closure too"
$script:Started = @(); $script:Logged = @()
$script:RebootQueueRunning = $true
$script:RebootQueue.Clear()
$callback = { param($result) Step-RebootQueue }.GetNewClosure()
& $callback 'ignored'
Check "the flag was cleared from inside a closure" (-not $script:RebootQueueRunning)


# =============================================================================
Section "Post-reboot monitor"
# Losing the monitor said nothing about the server, yet the tool marked it
# broken and stopped watching - and logged "Monitor error -" with nothing after
# the dash, so the cause could not be worked out afterwards either.
# =============================================================================
Invoke-Expression (Get-FunctionText -Name 'Complete-RebootMonitor')

function Invoke-Monitor {
    param($Monitor)
    $script:Props = @{}; $script:Rescans = @(); $script:Logged = @()
    Complete-RebootMonitor -ServerName 'srv-r' -Monitor $Monitor
}

Case "the server came back"
Invoke-Monitor ([PSCustomObject]@{ Phase = 'Online'; Error = $null; Attempts = 7 })
Check "status says it is back"                 ($script:Props.Status -eq 'Back Online')
Check "the reboot flag is cleared"             ($script:Props.RebootRequired -eq 'No')
Check "a post-reboot scan was started"         ($script:Rescans -contains 'srv-r')

Case "the monitor job returned nothing at all"
Invoke-Monitor $null
Check "the server is not declared broken"      ($script:Props.Status -ne 'Error')
Check "the reason is spelled out"              ($script:Props.Details -match 'returned no result')
Check "the tool keeps looking, by scanning"    ($script:Rescans -contains 'srv-r')
Check "it is logged as a warning, not an error" ((Get-LoggedLike 'WARN|*lost track*').Count -eq 1)
Check "the log line is never left empty"       ((Get-LoggedLike 'WARN|*- ; *').Count -eq 0)

Case "the monitor failed without saying why"
Invoke-Monitor ([PSCustomObject]@{ Phase = 'Error'; Error = ''; Attempts = 1 })
Check "the phase is named instead"             ($script:Props.Details -match "reported 'Error'")
Check "the tool keeps looking, by scanning"    ($script:Rescans -contains 'srv-r')

Case "the monitor failed and said why"
Invoke-Monitor ([PSCustomObject]@{ Phase = 'Error'; Error = 'CimException: RPC server unavailable'; Attempts = 3 })
Check "the reason survives to the grid"        ($script:Props.Details -match 'RPC server unavailable')
Check "the reason survives to the log"         ((Get-LoggedLike '*RPC server unavailable*').Count -eq 1)

Case "a result with no phase at all"
Invoke-Monitor ([PSCustomObject]@{ Error = $null })
Check "it is still explained"                  ($script:Props.Details -match 'carried no phase')
Check "the tool keeps looking, by scanning"    ($script:Rescans -contains 'srv-r')

Case "the server never came back"
Invoke-Monitor ([PSCustomObject]@{ Phase = 'Timeout'; Error = 'Server did not come back within 30 minutes.' })
Check "status says offline"                    ($script:Props.Status -eq 'Offline')
Check "no scan is attempted against a dead host" ($script:Rescans.Count -eq 0)

Case "the server pings but WinRM is not up"
Invoke-Monitor ([PSCustomObject]@{ Phase = 'WinRMTimeout'; Error = 'Server answers ping but no completed reboot was confirmed within 30 minutes.' })
Check "status says partially online"           ($script:Props.Status -eq 'Partially Online')
Check "the detail explains what is missing"    ($script:Props.Details -match 'WinRM is not ready')


# =============================================================================
Section "Deferred re-checks"
# An install the tool stopped watching used to leave the row reading "Still
# installing" until somebody scanned by hand. These re-checks answer it instead.
# =============================================================================
Invoke-Expression (Get-FunctionText   -Name 'Add-PendingRecheck')
Invoke-Expression (Get-FunctionText   -Name 'Remove-PendingRecheck')
Invoke-Expression (Get-FunctionText   -Name 'Step-PendingRechecks')

function Set-Row {
    param([string]$Status)
    $script:ServerData = @([PSCustomObject]@{ ServerName = 'srv-slow'; CredentialLabel = ''; Status = $Status })
    $script:Rescans = @(); $script:Logged = @(); $script:Props = @{}
}
function Get-Recheck { @($script:PendingRechecks | Where-Object { $_.ServerName -eq 'srv-slow' })[0] }
function Set-Due     { (Get-Recheck).DueAt = (Get-Date).AddMinutes(-1) }

Case "an install that ran out of time queues a re-check"
$script:PendingRechecks.Clear()
Set-Row 'Still installing'
Add-PendingRecheck -ServerName 'srv-slow'
Check "one re-check is queued"                 ($script:PendingRechecks.Count -eq 1)
Check "it is not due immediately"              ((Get-Recheck).DueAt -gt (Get-Date))
Check "the operator is told"                   ((Get-LoggedLike '*will re-check in*').Count -eq 1)

Case "queueing the same server twice does not double up"
Add-PendingRecheck -ServerName 'srv-slow'
Check "still only one re-check"                ($script:PendingRechecks.Count -eq 1)

Case "nothing happens before it is due"
Set-Row 'Still installing'
Step-PendingRechecks
Check "no scan was started"                    ($script:Rescans.Count -eq 0)
Check "the re-check is still queued"           ($script:PendingRechecks.Count -eq 1)

Case "the re-check fires once it is due"
Set-Row 'Still installing'
Set-Due
$before = (Get-Recheck).Remaining
Step-PendingRechecks
Check "the server was scanned"                 ($script:Rescans -contains 'srv-slow')
Check "an attempt was spent"                   ((Get-Recheck).Remaining -eq ($before - 1))
Check "the next attempt is scheduled"          ((Get-Recheck).DueAt -gt (Get-Date))

Case "a server that is busy does not burn an attempt"
Set-Row 'Scanning...'
Set-Due
$before = (Get-Recheck).Remaining
Step-PendingRechecks
Check "no scan was piled on top"               ($script:Rescans.Count -eq 0)
Check "the attempt was not spent"              ((Get-Recheck).Remaining -eq $before)
Check "it will look again shortly"             ((Get-Recheck).DueAt -gt (Get-Date))

Case "a confirmed install ends the re-checks"
Set-Row 'Up to date'
Set-Due
Step-PendingRechecks
Check "the re-check is dropped"                ($script:PendingRechecks.Count -eq 0)
Check "no further scan was started"            ($script:Rescans.Count -eq 0)
Check "the outcome is logged"                  ((Get-LoggedLike '*confirmed as finished*').Count -eq 1)

Case "a server that stays silent is eventually given up on"
$script:PendingRechecks.Clear()
Set-Row 'Still installing'
Add-PendingRecheck -ServerName 'srv-slow'
$script:Logged = @()
(Get-Recheck).Remaining = 1
Set-Due
Step-PendingRechecks
Check "the last attempt still scans"           ($script:Rescans -contains 'srv-slow')
Check "no attempts are left"                   ((Get-Recheck).Remaining -eq 0)
Set-Row 'Still installing'
Set-Due
Step-PendingRechecks
Check "the re-check is dropped"                ($script:PendingRechecks.Count -eq 0)
Check "giving up is a warning"                 ((Get-LoggedLike 'WARN|*gave up re-checking*').Count -eq 1)
Check "the row says what to do next"           ($script:Props.Details -match 'Scan manually')

Case "an install that timed out schedules its own re-check"
$script:PendingRechecks.Clear()
Set-Row 'Still installing'
Complete-InstallResult -ServerName 'srv-slow' -Result ([PSCustomObject]@{
    Success = $false; TimedOut = $true; TaskName = 'SPT_Install_0000'
    Error = "Install still going after 90 minutes"; Message = 'Still running'
})
Check "a re-check was queued by the handler"   ($script:PendingRechecks.Count -eq 1)
Check "the row says re-checking is happening"  ($script:Props.Details -match 're-checking every')


# =============================================================================
Section "Install and reboot time limits"
# =============================================================================
Invoke-Expression (Get-AssignmentText -VariablePath '$script:InstallTimeoutDefault')
Invoke-Expression (Get-FunctionText   -Name 'Get-InstallTimeout')

function Set-LimitBox {
    param($Content)
    $item = if ($null -eq $Content) { $null } else { [PSCustomObject]@{ Content = $Content } }
    $script:ui = @{ cboInstallTimeout = [PSCustomObject]@{ SelectedItem = $item } }
}

Case "the toolbar setting is honoured"
Set-LimitBox -Content '90 min'
Check "90 min becomes 5400 seconds"            ((Get-InstallTimeout) -eq 5400)
Set-LimitBox -Content '240 min'
Check "240 min becomes 14400 seconds"          ((Get-InstallTimeout) -eq 14400)

Case "the default is well clear of a cumulative update"
Check "default is at least an hour"            ($script:InstallTimeoutDefault -ge 3600)

Case "an unusable setting falls back instead of returning zero"
Set-LimitBox -Content $null
Check "nothing selected gives the default"     ((Get-InstallTimeout) -eq $script:InstallTimeoutDefault)
Set-LimitBox -Content 'not a number'
Check "unparsable text gives the default"      ((Get-InstallTimeout) -eq $script:InstallTimeoutDefault)

Invoke-Expression (Get-AssignmentText -VariablePath '$script:RebootTimeoutDefault')
Invoke-Expression (Get-FunctionText   -Name 'Get-RebootTimeout')

function Set-RebootBox {
    param($Content)
    $item = if ($null -eq $Content) { $null } else { [PSCustomObject]@{ Content = $Content } }
    $script:ui = @{ cboRebootTimeout = [PSCustomObject]@{ SelectedItem = $item } }
}

Case "how long to watch for a reboot is the operator's call"
Set-RebootBox -Content '45 min'
Check "45 min becomes 2700 seconds"            ((Get-RebootTimeout) -eq 2700)
Set-RebootBox -Content '120 min'
Check "120 min becomes 7200 seconds"           ((Get-RebootTimeout) -eq 7200)

Case "the reboot default matches what the monitor used to hard-code"
Check "default is 30 minutes"                  ($script:RebootTimeoutDefault -eq 1800)
Set-RebootBox -Content $null
Check "nothing selected gives the default"     ((Get-RebootTimeout) -eq $script:RebootTimeoutDefault)
Set-RebootBox -Content 'not a number'
Check "unparsable text gives the default"      ((Get-RebootTimeout) -eq $script:RebootTimeoutDefault)


# =============================================================================
Write-Host ""
if ($script:Failures -gt 0) {
    Write-Host "RESULT: FAILED - $($script:Failures) of $($script:Checks) checks" -ForegroundColor Red
    exit 1
} else {
    Write-Host "RESULT: PASSED - $($script:Checks) checks" -ForegroundColor Green
    exit 0
}
