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
      5. Credential password   - a rotated password must reach disk, and must
                                 not move the label the servers point at.
      6. Password guard        - repeated rejected logons must stop the run
                                 before the domain lockout policy does, and a
                                 server that is merely down must not count.
      7. Credential test       - the probe must say which of the two things
                                 went wrong, and must not arm the guard.
      8. Post-reboot monitor   - losing the monitor must not be reported as a
                                 broken server, and never without a reason.
      9. Monitor launch        - the watch must be handed a real script block
                                 and a server name, neither of which survives
                                 being started from inside a closure.
     10. AD import             - found servers must reach the grid, once each.
     11. Sequential queues     - the "run in progress" flags must be cleared
                                 when the queue drains, closures included.
     12. Deferred re-checks    - a server the tool stopped watching must be
                                 asked again, and eventually given up on.
     13. Time limits           - the install and reboot settings are read,
                                 with sane fallbacks.
     14. Held-back updates    - the list must survive a restart intact, and
                                 reach the server as a prelude.
     15. Install pre-flight   - a full disk or a disabled update agent must
                                 stop the install, a pending reboot must not,
                                 and a failed check must never read as a pass.
     16. Patch window         - the right servers are rebooted, in the
                                 operator's order, one at a time with a scan
                                 in between, at the chosen time; the plan
                                 survives a restart and Stop disarms it.

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
# The tick reports every job's outcome to the stale-password guard and gives it
# a chance to tear the run down. The guard has a section of its own further
# down; here it only has to exist, so the tick can be tested on its own terms.
function Register-JobAuthOutcome { param($Result) }
function Step-AuthLockdown { }
# Likewise the patch window and the run report, which the tick drives; both are
# tested in sections of their own.
function Step-PatchWindow { }
function Step-BatchWatch { }
# Email is opt-in and off in these tests, so the hooks that call it are exercised
# without a relay. The real one has a section of its own.
$script:Sent = @()
function Send-Notification {
    param([string]$Event, [string]$Summary, [string[]]$Lines = @())
    $script:Sent += [PSCustomObject]@{ Event = $Event; Summary = $Summary; Lines = $Lines }
    return $false
}

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
    FailedTitles    = @('Update X (0x800F0922 - installer failed - often space on the system partition)',
                        'Update Y (0x80070070 - not enough disk space)')
    Message = 'Installed 3 of 5 update(s), 2 failed'; Error = '2 update(s) failed to install'
}
Check "status is not a clean one"              ($script:Props.Status -eq 'Completed with errors')
Check "the two failures count as available"    ($script:Props.Available -eq '2')
Check "installed count is reported"            ($script:Props.Installed -eq '3')
Check "details name the failed updates"        ($script:Props.Details -match 'Update X' -and $script:Props.Details -match 'Update Y')
Check "the failure code reaches the grid"      ($script:Props.Details -match '0x800F0922')
Check "the failure code reaches the log"       ((Get-LoggedLike '*0x80070070*').Count -eq 1)
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


Case "starting an install clears the count from last time"
# The count is only written back on success, so a run that fails outright would
# otherwise leave the previous number on screen as if it had just been achieved.
# The clearing now happens at the pre-flight, which is the first thing an
# install does, and again when the install proper starts.
Invoke-Expression (Get-FunctionText -Name 'Invoke-InstallServer')
Invoke-Expression (Get-FunctionText -Name 'Invoke-InstallServerSequential')
Invoke-Expression (Get-FunctionText -Name 'Start-InstallPreflight')
Invoke-Expression (Get-FunctionText -Name 'Start-InstallJob')

function Ensure-Credential   { $true }
function Get-ServerCredential { param([string]$ServerName) "cred" }
function Get-InstallTimeout  { 5400 }
function Get-InstallPayload  { "payload" }
function Start-AsyncJob      { param($ScriptBlock, $Arguments, $OnComplete) }
$script:RunAsSystemScript = { }
$script:PreflightScript   = { }
$script:InstallPayload    = "payload"
$script:ExcludedKB        = @()

$script:Props = @{}
Invoke-InstallServer -ServerName 'srv-again'
Check "the previous count is cleared"          ($script:Props.Installed -eq '-')
Check "the row says it is being checked"       ($script:Props.Status -eq 'Checking...')

$script:Props = @{}
Invoke-InstallServerSequential -ServerName 'srv-again'
Check "the same holds in sequential mode"      ($script:Props.Installed -eq '-')

$script:Props = @{}
Start-InstallJob -ServerName 'srv-again' -Sequential $false
Check "and again when the install itself starts" ($script:Props.Installed -eq '-')
Check "the row says an install is running"     ($script:Props.Status -eq 'Installing...')

Case "a failed install leaves no stale count behind"
$script:Props = @{}
Complete-InstallResult -ServerName 'srv-again' -Result ([PSCustomObject]@{
    Success = $false; Error = 'WinRM connection failed'
})
Check "the handler does not write a count"     (-not $script:Props.ContainsKey('Installed'))


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

# =============================================================================
Section "Credential password change survives a restart"
# A rotated domain password has to reach credentials.json, or the next launch
# reads the old one back and every logon fails for a reason nothing explains.
# The label must stay put while that happens: it is the key each server entry
# stores, so moving it would strand every server that referred to the account.
# =============================================================================
Invoke-Expression (Get-FunctionText -Name 'Set-CredentialPassword')

function Get-PlainPassword { param($Credential) $Credential.GetNetworkCredential().Password }

Case "a new password is kept for the next launch"
Reset-CredentialFixture
$rotated = ConvertTo-SecureString 'rotated-not-a-secret' -AsPlainText -Force
Check "the change reports success"             ((Set-CredentialPassword -Label 'DOM1\user-a' -Password $rotated) -eq $true)
Check "memory holds the new password"          ((Get-PlainPassword $script:Credentials['DOM1\user-a']) -eq 'rotated-not-a-secret')
Invoke-Restart
Check "and so does disk after a restart"       ((Get-PlainPassword $script:Credentials['DOM1\user-a']) -eq 'rotated-not-a-secret')
Check "the other account was left alone"       ((Get-PlainPassword $script:Credentials['DOM2\user-b']) -eq 'placeholder-not-a-secret')

Case "the label a server points at does not move"
Reset-CredentialFixture
Set-CredentialPassword -Label 'DOM2\user-b' -Password $rotated | Out-Null
Check "the key is unchanged"                   ($script:Credentials.ContainsKey('DOM2\user-b'))
Check "the username is unchanged"              ($script:Credentials['DOM2\user-b'].UserName -eq 'DOM2\user-b')
Check "the server still points at it"          ($script:ServerData[0].CredentialLabel -eq 'DOM2\user-b')
Check "the default was not disturbed"          ($script:DefaultCredentialLabel -eq 'DOM1\user-a')

Case "an account that is not there gains no password"
Reset-CredentialFixture
Check "the call reports it did nothing"        ((Set-CredentialPassword -Label 'DOM9\nobody' -Password $rotated) -eq $false)
Check "no account was invented"                ($script:Credentials.Count -eq 2)

Case "an empty password is refused rather than stored"
Reset-CredentialFixture
$empty = New-Object System.Security.SecureString
Check "the call reports it did nothing"        ((Set-CredentialPassword -Label 'DOM1\user-a' -Password $empty) -eq $false)
Check "the working password survived"          ((Get-PlainPassword $script:Credentials['DOM1\user-a']) -eq 'placeholder-not-a-secret')
Invoke-Restart
Check "and is still there after a restart"     ((Get-PlainPassword $script:Credentials['DOM1\user-a']) -eq 'placeholder-not-a-secret')

if (Test-Path -LiteralPath $script:CredDir) {
    Remove-Item -LiteralPath $script:CredDir -Recurse -Force -ErrorAction SilentlyContinue
}


# =============================================================================
Section "Stale-password guard"
# A password rotated in the domain but not here is fired at every server in the
# batch at once. Each rejection is a bad logon against the same account, so a
# large batch can walk into the domain lockout policy and lock the account the
# maintenance window depends on. The guard has to stop the run before that -
# and just as importantly, must not stop it for a server that is merely down.
# =============================================================================
Invoke-Expression (Get-AssignmentText -VariablePath '$script:AuthFailureLimit')
Invoke-Expression (Get-FunctionText   -Name 'Test-AuthFailure')
Invoke-Expression (Get-FunctionText   -Name 'Test-AccountLockedOut')
Invoke-Expression (Get-FunctionText   -Name 'Register-JobAuthOutcome')
Invoke-Expression (Get-FunctionText   -Name 'Step-AuthLockdown')
Invoke-Expression (Get-FunctionText   -Name 'Complete-CredentialTest')
Invoke-Expression (Get-FunctionText   -Name 'Invoke-CredentialTest')

$script:Stopped = @()
$script:Notices = @()
function Stop-AllOperations { param([string]$Reason = "Stopped by user") $script:Stopped += $Reason }
function Show-AuthHaltNotice { param([string]$Text, [string]$Title = "notice") $script:Notices += "$Title|$Text" }
$script:StartedJobs = @()
function Start-AsyncJob { param($ScriptBlock, $Arguments, $OnComplete) $script:StartedJobs += ,$Arguments }

function Reset-Guard {
    $script:AuthFailures    = 0
    $script:AuthHaltPending = $false
    $script:AuthHaltReason  = ""
    $script:Stopped = @(); $script:Notices = @(); $script:Logged = @()
}
function New-JobResult {
    param([bool]$Success, [string]$ErrorText = "", [switch]$Probe)
    $o = [PSCustomObject]@{ Success = $Success; Error = $ErrorText }
    if ($Probe) { $o | Add-Member NoteProperty Probe $true }
    $o
}

Case "a rejected logon is told apart from a server that is simply not there"
Check "a bad password is a rejection"          (Test-AuthFailure -ErrorText 'Logon failure: unknown user name or bad password.')
Check "access denied is a rejection"           (Test-AuthFailure -ErrorText 'Connecting to remote server failed: Access is denied.')
Check "an expired password is a rejection"     (Test-AuthFailure -ErrorText 'The password has expired.')
Check "a locked account is a rejection"        (Test-AuthFailure -ErrorText 'The referenced account is currently locked out.')
Check "an unresolvable name is not"            (-not (Test-AuthFailure -ErrorText 'the server name cannot be resolved'))
Check "a refused connection is not"            (-not (Test-AuthFailure -ErrorText 'The client cannot connect to the destination specified in the request'))
Check "no error text at all is not"            (-not (Test-AuthFailure -ErrorText ''))
Check "a lock is recognised on its own"        (Test-AccountLockedOut -ErrorText 'The referenced account is currently locked out.')
Check "a bad password alone is not a lock"     (-not (Test-AccountLockedOut -ErrorText 'The user name or password is incorrect.'))

Case "rejections add up until the run is halted"
Reset-Guard
Register-JobAuthOutcome -Result (New-JobResult -Success $false -ErrorText 'Access is denied.')
Check "one rejection is not enough"            (-not $script:AuthHaltPending)
Check "but it was counted"                     ($script:AuthFailures -eq 1)
Register-JobAuthOutcome -Result (New-JobResult -Success $false -ErrorText 'Access is denied.')
Check "reaching the limit arms the halt"       ($script:AuthHaltPending)
Check "the reason quotes the count"            ($script:AuthHaltReason -match "$($script:AuthFailureLimit) logons")

Case "a server that answers proves the password and clears the count"
Reset-Guard
Register-JobAuthOutcome -Result (New-JobResult -Success $false -ErrorText 'Access is denied.')
Register-JobAuthOutcome -Result (New-JobResult -Success $true)
Check "the count went back to zero"            ($script:AuthFailures -eq 0)
Register-JobAuthOutcome -Result (New-JobResult -Success $false -ErrorText 'Access is denied.')
Check "so the next rejection does not halt"    (-not $script:AuthHaltPending)

Case "a server that is merely unreachable costs nothing"
Reset-Guard
Register-JobAuthOutcome -Result (New-JobResult -Success $false -ErrorText 'the server name cannot be resolved')
Register-JobAuthOutcome -Result (New-JobResult -Success $false -ErrorText 'the server name cannot be resolved')
Check "nothing was counted"                    ($script:AuthFailures -eq 0)
Check "the run was not halted"                 (-not $script:AuthHaltPending)

Case "an account already locked stops the run at once"
Reset-Guard
Register-JobAuthOutcome -Result (New-JobResult -Success $false -ErrorText 'The referenced account is currently locked out.')
Check "one report is enough"                   ($script:AuthHaltPending)
Check "the reason says what happened"          ($script:AuthHaltReason -match 'locked out')

Case "a deliberate probe from the Test button never arms the guard"
Reset-Guard
Register-JobAuthOutcome -Result (New-JobResult -Success $false -ErrorText 'Access is denied.' -Probe)
Register-JobAuthOutcome -Result (New-JobResult -Success $false -ErrorText 'Access is denied.' -Probe)
Check "nothing was counted"                    ($script:AuthFailures -eq 0)
Check "the run was not halted"                 (-not $script:AuthHaltPending)

Case "the halt tears the run down once, then re-arms"
Reset-Guard
$script:AuthHaltPending = $true
$script:AuthHaltReason  = "2 logons in a row were rejected"
Check "it reports that it acted"               ((Step-AuthLockdown) -eq $true)
Check "operations were stopped"                ($script:Stopped.Count -eq 1)
Check "the halt is not blamed on the user"     ($script:Stopped[0] -notmatch 'by user')
Check "the operator was told"                  ($script:Notices.Count -eq 1)
Check "the advice names Change Password"       ($script:Notices[0] -match 'Change Password')
Check "and names Test"                         ($script:Notices[0] -match 'Test')
Check "the guard is armed again"               ((-not $script:AuthHaltPending) -and $script:AuthFailures -eq 0)
Check "a second call does nothing"             ((Step-AuthLockdown) -eq $false)
Check "and stopped nothing twice"              ($script:Stopped.Count -eq 1)


# =============================================================================
Section "Credential test"
# Finding out that the stored password is stale by starting a real patch run is
# how a maintenance window gets lost. The check has to say which of the two
# things went wrong, because a rejected account and an unreachable server read
# almost alike in the log but need opposite responses.
# =============================================================================
Case "a credential that authenticates says so"
Reset-Guard
$ok = Complete-CredentialTest -Label 'DOM1\user-a' -ServerName 'srv-1' -Result ([PSCustomObject]@{ Success = $true; Error = ''; RemoteName = 'SRV-1'; Probe = $true })
Check "it reports success"                     ($ok -eq $true)
Check "the answer names the server"            ($script:Notices[0] -match 'SRV-1')
Check "nothing was logged as an error"         ((Get-LoggedLike 'ERROR|*').Count -eq 0)

Case "a rejected credential points at the password"
Reset-Guard
$ok = Complete-CredentialTest -Label 'DOM1\user-a' -ServerName 'srv-1' -Result ([PSCustomObject]@{ Success = $false; Error = 'The user name or password is incorrect.'; RemoteName = ''; Probe = $true })
Check "it reports failure"                     ($ok -eq $false)
Check "the advice is Change Password"          ($script:Notices[0] -match 'Change Password')
Check "the cause is kept verbatim"             ($script:Notices[0] -match 'password is incorrect')
Check "it is logged as an error"               ((Get-LoggedLike 'ERROR|*').Count -eq 1)

Case "an unreachable server is not blamed on the password"
Reset-Guard
$ok = Complete-CredentialTest -Label 'DOM1\user-a' -ServerName 'srv-1' -Result ([PSCustomObject]@{ Success = $false; Error = 'The client cannot connect to the destination specified in the request'; RemoteName = ''; Probe = $true })
Check "it reports failure"                     ($ok -eq $false)
Check "no one is sent to change a password"    ($script:Notices[0] -notmatch 'Change Password')
Check "it says the server was unreachable"     ($script:Notices[0] -match 'could not be reached')

Case "a test with nothing to test starts no logon"
$script:Credentials = @{ 'DOM1\user-a' = (New-TestCredential 'DOM1\user-a') }
$script:StartedJobs = @()
Check "an unknown account starts nothing"      ((Invoke-CredentialTest -Label 'DOM9\nobody' -ServerName 'srv-1') -eq $false)
Check "an empty server starts nothing"         ((Invoke-CredentialTest -Label 'DOM1\user-a' -ServerName '') -eq $false)
Check "no logon was spent"                     ($script:StartedJobs.Count -eq 0)

Case "the test sends the chosen account to the chosen server"
$script:StartedJobs = @()
Check "it reports that it started"             ((Invoke-CredentialTest -Label 'DOM1\user-a' -ServerName 'srv-1') -eq $true)
Check "exactly one logon was started"          ($script:StartedJobs.Count -eq 1)
Check "against the server it was given"        ($script:StartedJobs[0][0] -eq 'srv-1')
Check "with the credential that was picked"    ($script:StartedJobs[0][1].UserName -eq 'DOM1\user-a')


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
Check "the queue waits while the watch runs"   ($script:Advanced -eq 0)
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
Section "Held-back updates"
# One bad cumulative can fail on every server in the estate. Until the vendor
# fixes it, the only way through a window is to leave it out - so the list has
# to survive a restart, and it has to reach the server intact.
# =============================================================================
Invoke-Expression (Get-FunctionText -Name 'ConvertTo-KBNumbers')
Invoke-Expression (Get-FunctionText -Name 'Save-ExcludedKB')
Invoke-Expression (Get-FunctionText -Name 'Load-ExcludedKB')
Invoke-Expression (Get-FunctionText -Name 'Set-ExcludedKB')
Invoke-Expression (Get-FunctionText -Name 'Get-InstallPayload')

$script:CredDir        = Join-Path $env:TEMP "spt-kb-$PID"
$script:ExcludedKBFile = Join-Path $script:CredDir 'excluded-kb.json'
$script:InstallPayload = "# the real payload goes here"
$script:ExcludedKB     = @()

Case "whatever the operator types becomes bare KB numbers"
$got = ConvertTo-KBNumbers -Text 'KB5120238, 5034441 kb5000802'
Check "the prefix is dropped"                  ($got -contains '5120238')
Check "a bare number is kept"                  ($got -contains '5034441')
Check "lower case kb is handled"               ($got -contains '5000802')
Check "all three survived"                     ($got.Count -eq 3)
Check "nothing typed gives nothing"            ((ConvertTo-KBNumbers -Text '').Count -eq 0)

Case "anything that is not a KB number is dropped"
# A stray word would travel to every server and match nothing, which looks
# exactly like a working exclusion until the update installs anyway.
$got = ConvertTo-KBNumbers -Text 'KB5120238 rollup latest KB'
Check "the real number is kept"                ($got -contains '5120238')
Check "the words are not"                      ($got.Count -eq 1)

Case "a KB is listed once however often it is typed"
Check "one entry, not three"                   ((ConvertTo-KBNumbers -Text 'KB5120238 5120238 kb5120238').Count -eq 1)

Case "the list survives a restart"
Set-ExcludedKB -Text 'KB5120238, 5034441' | Out-Null
$script:ExcludedKB = @()
$back = Load-ExcludedKB
Check "both came back"                         ($back.Count -eq 2)
Check "as bare numbers"                        ($back -contains '5120238')

Case "a single held-back KB is not split into digits"
# ConvertTo-Json turns a one-element array into a bare string. Reading that back
# character by character would hold back nothing and claim to hold back seven.
Set-ExcludedKB -Text 'KB5120238' | Out-Null
$script:ExcludedKB = @()
$back = Load-ExcludedKB
Check "exactly one entry came back"            ($back.Count -eq 1)
Check "and it is the whole number"             ($back[0] -eq '5120238')

Case "clearing the list removes the file"
Set-ExcludedKB -Text '' | Out-Null
Check "nothing is held back"                   ($script:ExcludedKB.Count -eq 0)
Check "the file is gone"                       (-not (Test-Path -LiteralPath $script:ExcludedKBFile))
$script:ExcludedKB = @()
Check "and nothing comes back"                 ((Load-ExcludedKB).Count -eq 0)

Case "the list reaches the server as a prelude"
$script:ExcludedKB = @('5120238','5034441')
$payload   = Get-InstallPayload
$firstLine = ($payload -split '\r\n')[0]
Check "the assignment comes first"             ($firstLine -eq ('$' + "ExcludedKB = @('5120238','5034441')"))
Check "the real payload follows"               ($payload -match 'the real payload goes here')
$script:ExcludedKB = @()
$firstLine = ((Get-InstallPayload) -split '\r\n')[0]
Check "an empty list still assigns"            ($firstLine -eq ('$' + "ExcludedKB = @()"))

if (Test-Path -LiteralPath $script:CredDir) {
    Remove-Item -LiteralPath $script:CredDir -Recurse -Force -ErrorAction SilentlyContinue
}


# =============================================================================
Section "Install pre-flight"
# An install that runs the system drive dry fails with 0x80070070 about an hour
# in, having spent the window and changed nothing. The same fact costs one WinRM
# round trip to learn beforehand - provided a failed check is never mistaken for
# a clean bill of health.
# =============================================================================
Invoke-Expression (Get-AssignmentText -VariablePath '$script:MinFreeSpaceGB')
Invoke-Expression (Get-FunctionText   -Name 'Test-InstallPreflight')
Invoke-Expression (Get-FunctionText   -Name 'Complete-InstallPreflight')

function New-Facts {
    param([double]$FreeGB = 50, [bool]$ServiceExists = $true,
          [string]$StartMode = 'Manual', [bool]$RebootPending = $false)
    [PSCustomObject]@{
        Success = $true
        Error   = ''
        Facts   = [PSCustomObject]@{
            FreeSpaceGB   = $FreeGB
            ServiceExists = $ServiceExists
            StartMode     = $StartMode
            RebootPending = $RebootPending
        }
    }
}
function New-FailedCheck {
    param([string]$ErrorText)
    [PSCustomObject]@{ Success = $false; Error = $ErrorText; Facts = $null }
}

Case "a healthy server is cleared to install"
$v = Test-InstallPreflight -Result (New-Facts)
Check "it passes"                              ($v.Ok)
Check "with nothing to say"                    (($v.Blockers.Count -eq 0) -and ($v.Warnings.Count -eq 0))

Case "a full system drive stops the install before it starts"
$v = Test-InstallPreflight -Result (New-Facts -FreeGB ($script:MinFreeSpaceGB - 1))
Check "it does not pass"                       (-not $v.Ok)
Check "the reason names the space"             ($v.Blockers[0] -match 'free on the system drive')
Check "and how much was wanted"                ($v.Blockers[0] -match "$($script:MinFreeSpaceGB) GB wanted")

Case "exactly the wanted amount is enough"
Check "the boundary is not a blocker"          ((Test-InstallPreflight -Result (New-Facts -FreeGB $script:MinFreeSpaceGB)).Ok)

Case "an update agent that cannot run stops the install"
$v = Test-InstallPreflight -Result (New-Facts -StartMode 'Disabled')
Check "a disabled service blocks"              (-not $v.Ok)
Check "the reason says which service"          ($v.Blockers[0] -match 'Windows Update service is disabled')
$v = Test-InstallPreflight -Result (New-Facts -ServiceExists $false)
Check "a missing service blocks"               (-not $v.Ok)
Check "the reason says it is not there"        ($v.Blockers[0] -match 'not present')

Case "a pending reboot is said out loud, not treated as fatal"
$v = Test-InstallPreflight -Result (New-Facts -RebootPending $true)
Check "the install still goes ahead"           ($v.Ok)
Check "but the risk is named"                  ($v.Warnings[0] -match 'reboot is already pending')

Case "a check that never came back is not read as a pass"
$v = Test-InstallPreflight -Result (New-FailedCheck -ErrorText 'WinRM connection failed')
Check "an outright failure blocks"             (-not $v.Ok)
Check "the cause is kept"                      ($v.Blockers[0] -match 'WinRM connection failed')
Check "nothing at all blocks"                  (-not (Test-InstallPreflight -Result $null).Ok)
Check "success with no facts blocks"           (-not (Test-InstallPreflight -Result ([PSCustomObject]@{ Success = $true; Error = ''; Facts = $null })).Ok)

$script:Props   = @{}
$script:Started = @()
$script:Steps   = 0
$script:Handed  = 0
function Update-ServerEntry { param([string]$ServerName, [hashtable]$Properties) $script:Props = $Properties }
function Step-Progress { $script:Steps++ }
function Step-SequentialInstallQueue { $script:Handed++ }
function Start-InstallJob { param([string]$ServerName, [bool]$Sequential) $script:Started += $ServerName }
function Reset-Preflight {
    $script:Props = @{}; $script:Started = @(); $script:Steps = 0; $script:Handed = 0; $script:Logged = @()
}

Case "a blocked server is reported and the sequential queue moves on"
# A queue that is not handed on here does not fail, it simply stops - and the
# rest of the maintenance window quietly never happens.
Reset-Preflight
$ok = Complete-InstallPreflight -ServerName 'srv-full' -Sequential $true -Result (New-Facts -FreeGB 1)
Check "it reports that it blocked"             ($ok -eq $false)
Check "no install was started"                 ($script:Started.Count -eq 0)
Check "the row is marked blocked"              ($script:Props.Status -eq 'Blocked')
Check "the row says why"                       ($script:Props.Details -match 'free on the system drive')
Check "it is logged as an error"               ((Get-LoggedLike 'ERROR|*').Count -eq 1)
Check "the server still counted"               ($script:Steps -eq 1)
Check "the queue moved on"                     ($script:Handed -eq 1)

Case "a blocked server outside a sequential run leaves the queue alone"
Reset-Preflight
Complete-InstallPreflight -ServerName 'srv-full' -Sequential $false -Result (New-Facts -FreeGB 1) | Out-Null
Check "the queue was not touched"              ($script:Handed -eq 0)
Check "the server still counted"               ($script:Steps -eq 1)

Case "a server that passes goes straight to the install"
Reset-Preflight
$ok = Complete-InstallPreflight -ServerName 'srv-ok' -Sequential $false -Result (New-Facts)
Check "it reports that it started"             ($ok -eq $true)
Check "the install was started"                ($script:Started -contains 'srv-ok')
Check "the queue was not handed on"            ($script:Handed -eq 0)
Check "progress was not counted twice"         ($script:Steps -eq 0)

Case "a warning is logged even when the install goes ahead"
Reset-Preflight
$ok = Complete-InstallPreflight -ServerName 'srv-pending' -Sequential $false -Result (New-Facts -RebootPending $true)
Check "the install still started"              ($ok -eq $true)
Check "the pending reboot is in the log"       ((Get-LoggedLike 'WARN|*reboot is already pending*').Count -eq 1)


# =============================================================================
Section "Patch window"
# The night reboot used to need someone at the keyboard at the right minute. A
# plan holds it until then, which is only worth having if it reboots the right
# servers, in the operator's order, one at a time with a scan in between, and
# says in the morning what happened.
# =============================================================================
Invoke-Expression (Get-AssignmentText -VariablePath '$script:PatchWindowBusy')
foreach ($fn in 'New-PatchWindowPlan', 'Get-PatchWindowRebootList', 'Test-PatchWindowBusy',
                'Format-PatchWindowCountdown', 'Get-PatchWindowBannerText', 'Get-PatchWindowSummary',
                'Save-PatchWindow', 'Read-PatchWindow', 'Clear-PatchWindow', 'Start-PatchWindowInstall',
                'Start-PatchWindowReboot', 'Complete-PatchWindow', 'Step-PatchWindow') {
    Invoke-Expression (Get-FunctionText -Name $fn)
}

$pwDir = Join-Path $env:TEMP ("spt-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $pwDir -Force | Out-Null
$script:CredDir         = $pwDir
$script:PatchWindowFile = Join-Path $pwDir 'patch-window.json'

$script:Installed     = @()
$script:RebootStarted = @()
function Update-PatchWindowBanner { param([datetime]$Now) }
function Save-ServerList { }
function Sync-RunspacePool { }
function Start-ProgressBatch { param([int]$Total) }
function Invoke-InstallServer { param([string]$ServerName) $script:Installed += $ServerName }
function Invoke-RebootServerSequential { param([string]$ServerName) $script:RebootStarted += $ServerName }

# Rows are name, status, reboot flag[, details].
function Set-PwGrid {
    param([object[]]$Rows)
    $script:ServerData = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
    foreach ($r in $Rows) {
        $script:ServerData.Add([PSCustomObject]@{
            ServerName = $r[0]; Status = $r[1]; RebootRequired = $r[2]
            Details    = if ($r.Count -gt 3) { $r[3] } else { "" }
        })
    }
}
function Set-PwRow {
    param([string]$Name, [string]$Status, [string]$Reboot)
    $row = $script:ServerData | Where-Object { $_.ServerName -eq $Name }
    $row.Status = $Status
    if ($Reboot) { $row.RebootRequired = $Reboot }
}
function Reset-Pw {
    $script:Logged = @(); $script:Installed = @(); $script:RebootStarted = @()
    $script:RebootQueue.Clear()
    $script:RebootQueueRunning = $false
    $script:SequentialRunning  = $false
    $script:RebootVerifyScan   = $false
    $script:PatchWindow        = $null
    Remove-Item -LiteralPath $script:PatchWindowFile -Force -ErrorAction SilentlyContinue
}

$pwNow = [datetime]'2030-01-01 12:00'
$pwDay = [datetime]'2030-01-02'
function New-TestPlan {
    param([string[]]$Servers, [string]$Mode = 'None')
    (New-PatchWindowPlan -Day $pwDay -TimeText '02:00' -Servers $Servers -Mode $Mode -Now $pwNow).Plan
}
$pwAt = $pwDay.AddHours(2)

Case "a plan keeps the operator's order, and a name given twice once"
$r = New-PatchWindowPlan -Day $pwDay -TimeText '02:00' -Servers @('SRV-C','SRV-A','SRV-B','SRV-A') -Mode 'ScanInstall' -Now $pwNow
Check "it is accepted"                         ($r.Ok)
Check "the reboot time is the day plus the time" ($r.Plan.RebootAt -eq $pwAt)
Check "the order is kept exactly"              (($r.Plan.Servers -join ',') -eq 'SRV-C,SRV-A,SRV-B')
Check "with the install step it starts by scanning" ($r.Plan.Phase -eq 'Scanning')

Case "servers patched by hand elsewhere are scanned but not installed to"
$p = New-TestPlan -Servers @('SRV-A') -Mode 'ScanOnly'
Check "it still starts by scanning"            ($p.Phase -eq 'Scanning')
Check "the mode is kept"                       ($p.Mode -eq 'ScanOnly')

Case "with nothing to run now it only waits"
Check "the phase is Waiting"                   ((New-TestPlan -Servers @('SRV-A')).Phase -eq 'Waiting')

Case "a mode that does not exist is refused outright"
$threw = $false
try { New-PatchWindowPlan -Day $pwDay -TimeText '02:00' -Servers @('SRV-A') -Mode 'Whatever' -Now $pwNow | Out-Null }
catch { $threw = $true }
Check "it does not quietly become a scan"      ($threw)

Case "one server is still a list of one"
$p = New-TestPlan -Servers @('SRV-A')
Check "one server, not its letters"            ((@($p.Servers).Count -eq 1) -and ($p.Servers[0] -eq 'SRV-A'))

Case "a time with a dot is read too"
$r = New-PatchWindowPlan -Day $pwDay -TimeText ' 2.30 ' -Servers @('SRV-A') -Mode 'None' -Now $pwNow
Check "02:30 was understood"                   ($r.Ok -and $r.Plan.RebootAt -eq $pwDay.AddMinutes(150))

Case "input that cannot be right is refused, with a reason"
$r = New-PatchWindowPlan -Day $pwDay -TimeText '25:00' -Servers @('SRV-A') -Mode 'None' -Now $pwNow
Check "an impossible time is refused"          ((-not $r.Ok) -and ($r.Error -match 'not a time'))
$r = New-PatchWindowPlan -Day $pwDay -TimeText '2am' -Servers @('SRV-A') -Mode 'None' -Now $pwNow
Check "a time that is not HH:mm is refused"    (-not $r.Ok)
$r = New-PatchWindowPlan -Day $pwNow.Date -TimeText '11:00' -Servers @('SRV-A') -Mode 'None' -Now $pwNow
Check "a time already gone is refused"         ((-not $r.Ok) -and ($r.Error -match 'already passed'))
$r = New-PatchWindowPlan -Day $pwDay -TimeText '02:00' -Servers @() -Mode 'None' -Now $pwNow
Check "a plan with no servers is refused"      ((-not $r.Ok) -and ($r.Error -match 'No servers'))

Case "who is rebooted is decided by what the install left behind"
Set-PwGrid @(
    @('SRV-E', 'Error',            'Yes'),
    @('SRV-A', 'Reboot Required',  'Yes'),
    @('SRV-B', 'Up to date',       'No'),
    @('SRV-C', 'Still installing', 'Yes'),
    @('SRV-D', 'Installing...',    'Yes'))
$pick = Get-PatchWindowRebootList -Servers @('SRV-E','SRV-A','SRV-B','SRV-C','SRV-D','SRV-X')
Check "only those needing it, in plan order"   (($pick.Reboot -join ',') -eq 'SRV-E,SRV-A')
$why = @{}; foreach ($s in $pick.Skipped) { $why[$s.ServerName] = $s.Reason }
Check "a clean server is skipped as not needed" ($why['SRV-B'] -eq 'no reboot needed')
Check "an install still running is not rebooted" ($why['SRV-C'] -match 'still busy')
Check "nor one that is installing right now"   ($why['SRV-D'] -match 'still busy')
Check "a removed server is named, not lost"    ($why['SRV-X'] -match 'no longer')

Case "one server needing a reboot is still a list of one"
Set-PwGrid @(,@('SRV-A', 'Reboot Required', 'Yes'))
$pick = Get-PatchWindowRebootList -Servers @('SRV-A')
Check "the name comes back whole"              ((@($pick.Reboot).Count -eq 1) -and ($pick.Reboot[0] -eq 'SRV-A'))

Case "nothing happens before the reboot time"
Reset-Pw
Set-PwGrid @(,@('SRV-A', 'Reboot Required', 'Yes'))
$script:PatchWindow = New-TestPlan -Servers @('SRV-A')
Step-PatchWindow -Now $pwAt.AddMinutes(-1)
Check "no reboot was started"                  ($script:RebootStarted.Count -eq 0)
Check "the plan is still waiting"              ($script:PatchWindow.Phase -eq 'Waiting')

Case "at the reboot time the first server goes down and the rest queue in order"
Reset-Pw
Set-PwGrid @(
    @('SRV-A', 'Reboot Required', 'Yes'),
    @('SRV-B', 'Up to date',      'No'),
    @('SRV-C', 'Reboot Required', 'Yes'),
    @('SRV-D', 'Reboot Required', 'Yes'))
$script:PatchWindow = New-TestPlan -Servers @('SRV-C','SRV-B','SRV-A','SRV-D')
Step-PatchWindow -Now $pwAt
Check "exactly one server was rebooted"        ($script:RebootStarted.Count -eq 1)
Check "it is the first in the plan"            ($script:RebootStarted[0] -eq 'SRV-C')
Check "the rest wait in the plan's order"      ((@($script:RebootQueue) -join ',') -eq 'SRV-A,SRV-D')
Check "the run is marked as running"           ($script:RebootQueueRunning)
Check "each server will be scanned before the next" ($script:RebootVerifyScan)
Check "the plan is now rebooting"              ($script:PatchWindow.Phase -eq 'Rebooting')
Check "the skipped server is in the log"       ((Get-LoggedLike '*not rebooting SRV-B*no reboot needed*').Count -eq 1)
Step-PatchWindow -Now $pwAt.AddMinutes(1)
Check "a later tick does not start another"    ($script:RebootStarted.Count -eq 1)

Case "a run started by hand is waited for, and that is said once"
Reset-Pw
Set-PwGrid @(,@('SRV-A', 'Reboot Required', 'Yes'))
$script:PatchWindow = New-TestPlan -Servers @('SRV-A')
$script:RebootQueueRunning = $true
Step-PatchWindow -Now $pwAt
Step-PatchWindow -Now $pwAt.AddSeconds(30)
Check "nothing was rebooted underneath it"     ($script:RebootStarted.Count -eq 0)
Check "the wait was logged exactly once"       ((Get-LoggedLike 'WARN|*waiting for it to finish*').Count -eq 1)
$script:RebootQueueRunning = $false
Step-PatchWindow -Now $pwAt.AddMinutes(5)
Check "once it is over, the window goes ahead" ($script:RebootStarted -contains 'SRV-A')

Case "the install starts once every scan is back"
Reset-Pw
Set-PwGrid @(
    @('SRV-A', 'Scanning...',   '-'),
    @('SRV-B', 'Available (2)', 'No'),
    @('SRV-C', 'Up to date',    'No'))
$script:PatchWindow = New-TestPlan -Servers @('SRV-A','SRV-B','SRV-C') -Mode 'ScanInstall'
Step-PatchWindow -Now $pwNow
Check "no install while a scan is still out"   ($script:Installed.Count -eq 0)
Set-PwRow 'SRV-A' 'Available (1)' 'No'
Step-PatchWindow -Now $pwNow
Check "servers with updates are installed"     (($script:Installed -join ',') -eq 'SRV-A,SRV-B')
Check "an up-to-date server is left alone"     (-not ($script:Installed -contains 'SRV-C'))
Check "the plan is now installing"             ($script:PatchWindow.Phase -eq 'Installing')

Case "the install phase ends only when nothing is busy"
Set-PwRow 'SRV-A' 'Installing...'
Set-PwRow 'SRV-B' 'Checking...'
Step-PatchWindow -Now $pwNow
Check "still installing while installs run"    ($script:PatchWindow.Phase -eq 'Installing')
Set-PwRow 'SRV-A' 'Reboot Required' 'Yes'
Set-PwRow 'SRV-B' 'Scanning...'
Step-PatchWindow -Now $pwNow
Check "a confirming rescan is waited for too"  ($script:PatchWindow.Phase -eq 'Installing')
Set-PwRow 'SRV-B' 'Up to date' 'No'
Step-PatchWindow -Now $pwNow
Check "then it waits for the reboot time"      ($script:PatchWindow.Phase -eq 'Waiting')
Check "the log says how many need a reboot"    ((Get-LoggedLike '*install finished - 1 server(s) need a reboot*').Count -eq 1)
Check "no reboot yet"                          ($script:RebootStarted.Count -eq 0)

Case "servers patched by hand: the scan decides, and nothing is installed"
# The updates went on outside this tool, so there is nothing to install - but
# the scan still has to run, because it is what finds the pending reboot.
Reset-Pw
Set-PwGrid @(
    @('SRV-A', 'Scanning...', '-'),
    @('SRV-B', 'Up to date',  'No'))
$script:PatchWindow = New-TestPlan -Servers @('SRV-A','SRV-B') -Mode 'ScanOnly'
Step-PatchWindow -Now $pwNow
Check "it waits for the scans"                 ($script:PatchWindow.Phase -eq 'Scanning')
Set-PwRow 'SRV-A' 'Reboot Required' 'Yes'
Step-PatchWindow -Now $pwNow
Check "nothing was installed"                  ($script:Installed.Count -eq 0)
Check "it goes straight to waiting"            ($script:PatchWindow.Phase -eq 'Waiting')
Check "the log says how many need a reboot"    ((Get-LoggedLike '*scan finished - 1 server(s) need a reboot*').Count -eq 1)
Step-PatchWindow -Now $pwAt
Check "at the time, the one Windows waits for goes down" ($script:RebootStarted -contains 'SRV-A')
Check "and the clean one does not"             (-not ($script:RebootStarted -contains 'SRV-B'))

Case "the reboot time cuts a slow install short, around the busy server"
Reset-Pw
Set-PwGrid @(
    @('SRV-A', 'Installing...',   '-'),
    @('SRV-B', 'Reboot Required', 'Yes'))
$script:PatchWindow = New-TestPlan -Servers @('SRV-A','SRV-B') -Mode 'ScanInstall'
$script:PatchWindow.Phase = 'Installing'
Step-PatchWindow -Now $pwAt
Check "the ready server is rebooted"           ($script:RebootStarted -contains 'SRV-B')
Check "the one still installing is not"        (-not ($script:RebootStarted -contains 'SRV-A'))

Case "nobody needs a reboot"
Reset-Pw
Set-PwGrid @(,@('SRV-A', 'Up to date', 'No'))
$script:PatchWindow = New-TestPlan -Servers @('SRV-A')
Step-PatchWindow -Now $pwAt
Check "nothing was rebooted"                   ($script:RebootStarted.Count -eq 0)
Check "the window is closed"                   ($null -eq $script:PatchWindow)
Check "and the log says why"                   ((Get-LoggedLike '*no server needs a reboot*').Count -eq 1)

Case "the morning report names every server that is not clean"
Reset-Pw
Set-PwGrid @(
    @('SRV-A', 'Up to date',    'No'),
    @('SRV-B', 'Available (1)', 'No',  'KB5000001: Cumulative Update'),
    @('SRV-C', 'Offline',       'Pending', 'Server did not respond after reboot.'))
$script:PatchWindow = New-TestPlan -Servers @('SRV-A','SRV-B','SRV-C','SRV-D')
$script:PatchWindow.Phase   = 'Rebooting'
$script:PatchWindow.Queued  = @('SRV-A','SRV-B','SRV-C')
$script:PatchWindow.Skipped = @([PSCustomObject]@{ ServerName = 'SRV-D'; Reason = 'no reboot needed' })
Save-PatchWindow
Complete-PatchWindow
Check "the totals add up"                      ((Get-LoggedLike 'WARN|Patch window finished: 3 rebooted, 1 clean, 2 need attention, 1 skipped').Count -eq 1)
Check "updates still pending are flagged"      ((Get-LoggedLike 'WARN|*needs attention - SRV-B : Available (1)*KB5000001*').Count -eq 1)
Check "a server that did not come back is flagged" ((Get-LoggedLike 'WARN|*needs attention - SRV-C : Offline*').Count -eq 1)
Check "the clean one is not"                   ((Get-LoggedLike '*needs attention - SRV-A*').Count -eq 0)
Check "the skipped one is listed"              ((Get-LoggedLike '*skipped - SRV-D : no reboot needed*').Count -eq 1)
Check "the window is closed"                   ($null -eq $script:PatchWindow)
Check "and forgotten on disk"                  (-not (Test-Path -LiteralPath $script:PatchWindowFile))

Case "a clean night is reported as such"
Reset-Pw
Set-PwGrid @(,@('SRV-A', 'Up to date', 'No'))
$script:PatchWindow = New-TestPlan -Servers @('SRV-A')
$script:PatchWindow.Phase  = 'Rebooting'
$script:PatchWindow.Queued = @('SRV-A')
Complete-PatchWindow
Check "the summary is not a warning"           ((Get-LoggedLike 'INFO|Patch window finished: 1 rebooted, 1 clean, 0 need attention*').Count -eq 1)

Case "a plan survives a restart, one server included"
Reset-Pw
$script:PatchWindow = New-TestPlan -Servers @('SRV-A') -Mode 'ScanInstall'
$script:PatchWindow.Phase = 'Installing'
Save-PatchWindow
$script:PatchWindow = $null
$back = Read-PatchWindow
Check "it was read back"                       ($null -ne $back)
Check "the reboot time is exact"               ($back.RebootAt -eq $pwAt)
Check "the single server is whole"             ((@($back.Servers).Count -eq 1) -and ($back.Servers[0] -eq 'SRV-A'))
Check "it comes back ready to scan, not to install" (($back.Phase -eq 'Scanning') -and ($back.Mode -eq 'ScanOnly'))

Case "a restored plan never installs, whatever it was doing"
foreach ($m in 'ScanInstall', 'ScanOnly') {
    Reset-Pw
    $script:PatchWindow = New-TestPlan -Servers @('SRV-A') -Mode $m
    Save-PatchWindow
    Check "a $m plan comes back as a scan"     ((Read-PatchWindow).Mode -eq 'ScanOnly')
}
Reset-Pw
$script:PatchWindow = New-TestPlan -Servers @('SRV-A') -Mode 'None'
Save-PatchWindow
$back = Read-PatchWindow
Check "a plan that ran nothing still runs nothing" ($back.Mode -eq 'None')
Check "and waits for its reboot time"          ($back.Phase -eq 'Waiting')

Case "a file written before modes existed is still read"
Reset-Pw
Set-Content -LiteralPath $script:PatchWindowFile -Encoding UTF8 -Value (@{
    RebootAt  = $pwAt.ToString('o')
    CreatedAt = $pwNow.ToString('o')
    Phase     = 'Waiting'
    Servers   = @('SRV-A')
} | ConvertTo-Json)
$back = Read-PatchWindow
Check "it loads"                               ($null -ne $back)
Check "with no mode, nothing is run"           ($back.Mode -eq 'None')

Case "a restored scan plan scans again before the reboot time"
Reset-Pw
Set-PwGrid @(
    @('SRV-A', 'Interrupted', '-'),
    @('SRV-B', 'Interrupted', '-'))
$restored = New-TestPlan -Servers @('SRV-A','SRV-B') -Mode 'ScanOnly'
$restored.Phase = 'Scanning'
$script:PatchWindow = $restored
Set-PwRow 'SRV-A' 'Scanning...' '-'
Step-PatchWindow -Now $pwNow
Check "it waits for the scan"                  ($script:PatchWindow.Phase -eq 'Scanning')
Check "and installs nothing"                   ($script:Installed.Count -eq 0)
Set-PwRow 'SRV-A' 'Up to date' 'Yes'
Set-PwRow 'SRV-B' 'Up to date' 'No'
Step-PatchWindow -Now $pwNow
Check "then waits for the reboot time"         ($script:PatchWindow.Phase -eq 'Waiting')
Step-PatchWindow -Now $pwAt
Check "the server patched since is rebooted"   ($script:RebootStarted -contains 'SRV-A')

Case "a time taken from this computer's clock is not shifted by its zone"
# The dialog's dates come from Get-Date and carry the local zone; they are
# written with their offset and must come back as the same wall-clock time.
$localAt = (Get-Date).Date.AddDays(3).AddHours(2)
$script:PatchWindow = (New-PatchWindowPlan -Day $localAt.Date -TimeText '02:00' -Servers @('SRV-A') -Mode 'None').Plan
Save-PatchWindow
$back = Read-PatchWindow
Check "still 02:00 on the same day"            ($back.RebootAt -eq $localAt)
Check "the file records the offset"            ((Get-Content -LiteralPath $script:PatchWindowFile -Raw) -match 'T02:00:00\.0000000[+-]\d\d:\d\d')

Case "the order survives a restart"
$script:PatchWindow = New-TestPlan -Servers @('SRV-C','SRV-A','SRV-B')
Save-PatchWindow
$back = Read-PatchWindow
Check "same servers, same order"               (($back.Servers -join ',') -eq 'SRV-C,SRV-A,SRV-B')

Case "a damaged file is reported, not trusted"
Reset-Pw
Set-Content -LiteralPath $script:PatchWindowFile -Value '{ not json' -Encoding UTF8
Check "nothing is restored"                    ($null -eq (Read-PatchWindow))
Check "the problem is logged"                  ((Get-LoggedLike 'WARN|*could not be read*').Count -eq 1)

Case "cancelling forgets the plan"
Reset-Pw
$script:PatchWindow = New-TestPlan -Servers @('SRV-A')
Save-PatchWindow
Clear-PatchWindow -Reason 'Cancelled by user'
Check "the plan is gone"                       ($null -eq $script:PatchWindow)
Check "so is its file"                         (-not (Test-Path -LiteralPath $script:PatchWindowFile))
Check "the log says who cancelled it"          ((Get-LoggedLike 'WARN|*cancelled: Cancelled by user*').Count -eq 1)

Case "the countdown reads like a person wrote it"
Check "hours and minutes"                      ((Format-PatchWindowCountdown -Left (New-TimeSpan -Hours 3 -Minutes 12)) -eq 'in 3 h 12 min')
Check "days for the far future"                ((Format-PatchWindowCountdown -Left (New-TimeSpan -Hours 25)) -eq 'in 1 d 1 h')
Check "minutes when close"                     ((Format-PatchWindowCountdown -Left (New-TimeSpan -Minutes 45)) -eq 'in 45 min')
Check "the last minute"                        ((Format-PatchWindowCountdown -Left (New-TimeSpan -Seconds 30)) -eq 'in under a minute')
Set-PwGrid @(
    @('SRV-A', 'Reboot Required', 'Yes'),
    @('SRV-B', 'Up to date',      'No'))
$banner = Get-PatchWindowBannerText -Window (New-TestPlan -Servers @('SRV-A','SRV-B')) -Now $pwNow
Check "the banner gives the time"              ($banner -match '02:00')
Check "and how long is left"                   ($banner -match '\(in 14 h 0 min\)')
Check "while waiting, how many will go down"   ($banner -match '1 of 2 need a reboot')
$preparing = New-TestPlan -Servers @('SRV-A','SRV-B') -Mode 'ScanInstall'
$banner = Get-PatchWindowBannerText -Window $preparing -Now $pwNow
Check "before the install, just how many servers" ($banner -match 'scanning.*2 server\(s\)$')
Check "no plan, no banner"                     ((Get-PatchWindowBannerText -Window $null -Now $pwNow) -eq '')

Case "the confirmation spells out the order"
$text = Get-PatchWindowSummary -Plan (New-TestPlan -Servers @('SRV-C','SRV-A') -Mode 'ScanInstall')
Check "the first server is numbered first"     ($text -match '1\. SRV-C')
Check "the second second"                      ($text -match '2\. SRV-A')
Check "the install step is mentioned"          ($text -match 'install updates on them in parallel')
Check "and that the window must stay open"     ($text -match 'Locking the screen is fine')

# -- The reboot chain waits for the verifying scan ----------------------------
Invoke-Expression (Get-FunctionText -Name 'Start-RebootMonitor')
$script:Launched   = $null
$script:Advanced   = 0
$script:HandOnSeen = $null
$script:StubHandOn = $true
function Start-AsyncJob {
    param([ScriptBlock]$ScriptBlock, [object[]]$Arguments, [ScriptBlock]$OnComplete)
    $script:Launched = [PSCustomObject]@{ ScriptBlock = $ScriptBlock; Arguments = $Arguments; OnComplete = $OnComplete }
}
function Get-ServerCredential { param([string]$ServerName) "cred-for-$ServerName" }
function Step-RebootQueue { param([switch]$AfterFailure) $script:Advanced++ }
function Complete-RebootMonitor {
    param([string]$ServerName, $Monitor, [switch]$HandOnAfterScan)
    $script:HandOnSeen = [bool]$HandOnAfterScan
    return ([bool]$HandOnAfterScan -and $script:StubHandOn)
}
function Invoke-MonitorCallback {
    param([bool]$Verify, [switch]$Sequential)
    $script:Advanced = 0; $script:HandOnSeen = $null
    $script:RebootVerifyScan = $Verify
    Start-RebootMonitor -ServerName 'srv-v' -BootBefore (Get-Date) -Sequential:$Sequential
    & $script:Launched.OnComplete ([PSCustomObject]@{ Phase = 'Online' })
}

Case "in a patch window the scan, not the monitor, hands the queue on"
$script:StubHandOn = $true
Invoke-MonitorCallback -Verify $true -Sequential
Check "the monitor was told to hand on via the scan" ($script:HandOnSeen)
Check "the next server is not rebooted yet"    ($script:Advanced -eq 0)

Case "no scan was started (server never came back), so the monitor hands on"
$script:StubHandOn = $false
Invoke-MonitorCallback -Verify $true -Sequential
Check "the queue still moves on"               ($script:Advanced -eq 1)

Case "a sequential reboot started by hand is unchanged"
$script:StubHandOn = $true
Invoke-MonitorCallback -Verify $false -Sequential
Check "no scan hand-over was asked for"        (-not $script:HandOnSeen)
Check "the queue moves on as before"           ($script:Advanced -eq 1)

Case "a single reboot never hands on, flag or not"
Invoke-MonitorCallback -Verify $true
Check "no scan hand-over was asked for"        (-not $script:HandOnSeen)
Check "the queue was not touched"              ($script:Advanced -eq 0)

Invoke-Expression (Get-FunctionText -Name 'Complete-RebootMonitor')
$script:ScanHandsOn = $null
function Invoke-ScanServer {
    param([string]$ServerName, [switch]$NoProgress, [switch]$ThenStepRebootQueue)
    $script:Rescans += $ServerName
    $script:ScanHandsOn = [bool]$ThenStepRebootQueue
}
function Invoke-RealMonitor {
    param($Monitor, [switch]$HandOn)
    $script:Rescans = @(); $script:ScanHandsOn = $null; $script:Logged = @()
    ,@(Complete-RebootMonitor -ServerName 'srv-m' -Monitor $Monitor -HandOnAfterScan:$HandOn)
}

Case "a server back online is scanned, and the scan carries the queue"
$out = Invoke-RealMonitor ([PSCustomObject]@{ Phase = 'Online' }) -HandOn
Check "the scan was started"                   ($script:Rescans -contains 'srv-m')
Check "the scan was asked to hand on"          ($script:ScanHandsOn)
Check "it reports that it handed on, and nothing else" (($out.Count -eq 1) -and ($out[0] -eq $true))

Case "a server that never came back is not scanned, so it does not hand on"
$out = Invoke-RealMonitor ([PSCustomObject]@{ Phase = 'Timeout'; Error = 'gone' }) -HandOn
Check "no scan"                                ($script:Rescans.Count -eq 0)
Check "it reports that it did not hand on"     (($out.Count -eq 1) -and ($out[0] -eq $false))

Case "a lost monitor falls back to a scan, which carries the queue"
$out = Invoke-RealMonitor $null -HandOn
Check "the fallback scan was asked to hand on" ($script:ScanHandsOn)
Check "it reports that it handed on"           ($out[0] -eq $true)

Case "outside a patch window the scan does not touch the queue"
$out = Invoke-RealMonitor ([PSCustomObject]@{ Phase = 'Online' })
Check "the scan was not asked to hand on"      ($script:ScanHandsOn -eq $false)
Check "it reports that it did not hand on"     ($out[0] -eq $false)

Invoke-Expression (Get-FunctionText -Name 'Invoke-ScanServer')
$script:CredOk = $true
function Ensure-Credential { $script:CredOk }
function Invoke-ScanWith {
    param($Result, [switch]$HandOn)
    $script:Advanced = 0; $script:Launched = $null; $script:Logged = @()
    Invoke-ScanServer -ServerName 'srv-s' -NoProgress -ThenStepRebootQueue:$HandOn
    if ($script:Launched) { & $script:Launched.OnComplete $Result }
}

Case "the verifying scan hands the queue on once it is done"
$script:CredOk = $true
$script:Advanced = 0; $script:Launched = $null
Invoke-ScanServer -ServerName 'srv-s' -NoProgress -ThenStepRebootQueue
Check "not while the scan is still running"    ($script:Advanced -eq 0)
& $script:Launched.OnComplete ([PSCustomObject]@{ Success = $true; Count = 0; RebootRequired = $false; Updates = @() })
Check "exactly once when it finishes"          ($script:Advanced -eq 1)

Case "a failed verifying scan does not strand the queue"
Invoke-ScanWith ([PSCustomObject]@{ Success = $false; Error = 'WinRM cannot complete the operation' }) -HandOn
Check "the queue still moves on"               ($script:Advanced -eq 1)

Case "a scan that cannot even start does not strand the queue"
$script:CredOk = $false
Invoke-ScanWith $null -HandOn
Check "the queue still moves on"               ($script:Advanced -eq 1)
$script:CredOk = $true

Case "an ordinary scan leaves the queue alone"
Invoke-ScanWith ([PSCustomObject]@{ Success = $true; Count = 0; RebootRequired = $false; Updates = @() })
Check "the queue was not touched"              ($script:Advanced -eq 0)

# -- The queue draining is what ends the window -------------------------------
Invoke-Expression (Get-FunctionText -Name 'Step-RebootQueue')

Case "the last reboot of a patch window ends it with the report"
Reset-Pw
Set-PwGrid @(,@('SRV-A', 'Up to date', 'No'))
$script:PatchWindow = New-TestPlan -Servers @('SRV-A')
$script:PatchWindow.Phase  = 'Rebooting'
$script:PatchWindow.Queued = @('SRV-A')
$script:RebootQueueRunning = $true
$script:RebootVerifyScan   = $true
Step-RebootQueue
Check "the run is over"                        (-not $script:RebootQueueRunning)
Check "scans stop gating later manual reboots" (-not $script:RebootVerifyScan)
Check "the report was written"                 ((Get-LoggedLike '*Patch window finished*').Count -eq 1)
Check "the window is closed"                   ($null -eq $script:PatchWindow)

Case "a manual reboot run ending does not end a window still waiting"
Reset-Pw
$script:PatchWindow = New-TestPlan -Servers @('SRV-A')
$script:RebootQueueRunning = $true
Step-RebootQueue
Check "the window is still armed"              ($null -ne $script:PatchWindow)
Check "no report was written"                  ((Get-LoggedLike '*Patch window finished*').Count -eq 0)

# -- Stop means stop ----------------------------------------------------------
Invoke-Expression (Get-FunctionText -Name 'Stop-AllOperations')

Case "Stop also disarms the patch window"
Reset-Pw
$script:ActiveJobs.Clear()
Set-PwGrid @(,@('SRV-A', 'Up to date', 'No'))
$script:PatchWindow = New-TestPlan -Servers @('SRV-A')
$script:RebootVerifyScan = $true
Save-PatchWindow
Stop-AllOperations -Reason 'Stopped by user'
Check "the plan is gone"                       ($null -eq $script:PatchWindow)
Check "so is its file"                         (-not (Test-Path -LiteralPath $script:PatchWindowFile))
Check "the scan gate is lifted"                (-not $script:RebootVerifyScan)
Check "the log says why"                       ((Get-LoggedLike 'WARN|*cancelled: Stopped by user*').Count -eq 1)

Remove-Item -LiteralPath $pwDir -Recurse -Force -ErrorAction SilentlyContinue


# =============================================================================
Section "Email notifications"
# A night window nobody reads is a night window nobody trusts. What matters
# here: settings that would not work are refused before the night rather than
# during it, only the chosen events are sent, and a relay that will not take
# the mail never breaks the run it was reporting on.
# =============================================================================
Invoke-Expression (Get-AssignmentText -VariablePath '$script:NotifyEvents')
foreach ($fn in 'New-SmtpConfig', 'Test-SmtpConfig', 'ConvertTo-Recipients', 'Save-SmtpConfig',
                'Load-SmtpConfig', 'Test-NotificationEvent', 'New-NotificationMessage',
                'Get-SmtpCredential', 'Send-Notification', 'Complete-Notification',
                'Get-BatchReport', 'Start-BatchWatch', 'Step-BatchWatch') {
    Invoke-Expression (Get-FunctionText -Name $fn)
}
Invoke-Expression (Get-AssignmentText -VariablePath '$script:AttentionStatuses')

$mailDir = Join-Path $env:TEMP ("spt-mail-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $mailDir -Force | Out-Null
$script:CredDir  = $mailDir
$script:SmtpFile = Join-Path $mailDir 'smtp.json'
$script:SmtpSendScript = { param($a) }

function New-TestSmtp {
    param([bool]$Enabled = $true, [string]$Server = 'relay.test.local', $Port = 25,
          [string]$From = 'spt@test.local', [string[]]$To = @('ops@test.local'),
          [string]$AuthUser = '', $Password = $null, [hashtable]$Events = $null)
    $c = New-SmtpConfig
    $c.Enabled = $Enabled; $c.Server = $Server; $c.Port = $Port
    $c.From = $From; $c.To = $To; $c.AuthUser = $AuthUser; $c.Password = $Password
    if ($Events) { foreach ($k in $Events.Keys) { $c.Events[$k] = $Events[$k] } }
    return $c
}
function New-TestSecret {
    param([string]$Text = 'p@ssw0rd')
    ConvertTo-SecureString $Text -AsPlainText -Force
}

Case "settings that would work are accepted"
$v = Test-SmtpConfig -Config (New-TestSmtp)
Check "an anonymous relay is fine"             ($v.Ok)
Check "with nothing to complain about"         ($v.Problems.Count -eq 0)
Check "so is one with a user and password"     ((Test-SmtpConfig -Config (New-TestSmtp -AuthUser 'svc-mail' -Password (New-TestSecret))).Ok)

Case "settings that would fail at 2 a.m. are refused now"
$v = Test-SmtpConfig -Config (New-TestSmtp -Server '')
Check "no server is refused"                   ((-not $v.Ok) -and ($v.Problems -join ' ') -match 'SMTP server is empty')
$v = Test-SmtpConfig -Config (New-TestSmtp -Port 'twenty-five')
Check "a port that is not a number is refused" ((-not $v.Ok) -and ($v.Problems -join ' ') -match 'not a port number')
Check "so is one out of range"                 (-not (Test-SmtpConfig -Config (New-TestSmtp -Port 70000)).Ok)
$v = Test-SmtpConfig -Config (New-TestSmtp -From 'patchtool')
Check "a From that is not an address"          ((-not $v.Ok) -and ($v.Problems -join ' ') -match 'not an email address')
$v = Test-SmtpConfig -Config (New-TestSmtp -To @())
Check "no recipient is refused"                ((-not $v.Ok) -and ($v.Problems -join ' ') -match 'no recipient')
$v = Test-SmtpConfig -Config (New-TestSmtp -To @('ops@test.local', 'bad address'))
Check "one bad recipient among good ones"      (-not $v.Ok)
$v = Test-SmtpConfig -Config (New-TestSmtp -AuthUser 'svc-mail')
Check "a user with no password is refused"     ((-not $v.Ok) -and ($v.Problems -join ' ') -match 'no password')
Check "nothing at all is refused"              (-not (Test-SmtpConfig -Config $null).Ok)

Case "recipients are taken however they are typed"
$r = ConvertTo-Recipients -Text ' a@x.local, b@x.local;c@x.local , a@x.local '
Check "split, trimmed and de-duplicated"       (($r -join ',') -eq 'a@x.local,b@x.local,c@x.local')
Check "one address is still a list"            ((@(ConvertTo-Recipients -Text 'only@x.local').Count -eq 1))
$none = ConvertTo-Recipients -Text '  '
Check "an empty box is no recipients"          (@($none).Count -eq 0)

Case "only the chosen events are sent"
$script:Smtp = New-TestSmtp -Events @{ PatchWindow = $true; Halt = $true; Install = $false; Reboot = $false }
Check "the patch window report is on"          (Test-NotificationEvent -Event 'PatchWindow')
Check "so is a halted run"                     (Test-NotificationEvent -Event 'Halt')
Check "a hand-started install is off"          (-not (Test-NotificationEvent -Event 'Install'))
Check "a hand-started reboot is off"           (-not (Test-NotificationEvent -Event 'Reboot'))

Case "nothing is sent while email is switched off"
$script:Smtp = New-TestSmtp -Enabled $false
Check "not even a chosen event"                (-not (Test-NotificationEvent -Event 'PatchWindow'))

Case "broken settings send nothing rather than failing every night"
$script:Smtp = New-TestSmtp -Server ''
Check "an unusable relay sends nothing"        (-not (Test-NotificationEvent -Event 'PatchWindow'))

Case "the message reads like something an operator wants at 03:41"
$m = New-NotificationMessage -Event 'PatchWindow' `
    -Summary 'Patch window finished: 4 rebooted, 2 clean, 2 need attention, 1 skipped' `
    -Lines @('needs attention - SRV-SQL01 : Available (1)', 'skipped - SRV-APP01 : no reboot needed') `
    -Computer 'ADMIN-PC' -Now ([datetime]'2026-09-24 03:41:17')
Check "the subject says what happened"         ($m.Subject -eq '[SPT] Patch window finished: 4 rebooted, 2 clean, 2 need attention, 1 skipped')
Check "the body opens with the summary"        ($m.Body -match '^Patch window finished')
Check "every line is in the body"              (($m.Body -match 'SRV-SQL01') -and ($m.Body -match 'SRV-APP01'))
Check "it says which computer sent it"         ($m.Body -match 'ADMIN-PC')
Check "and where the full log is"              ($m.Body -match 'ServerPatchTool_20260924\.log')

Case "a subject too long for a phone is cut, not wrapped"
$m = New-NotificationMessage -Event 'Install' -Summary ('x' * 400)
Check "it is trimmed"                          ($m.Subject.Length -le 150)
Check "and says it was trimmed"                ($m.Subject.EndsWith('...'))

Case "the credential is only built when there is one"
Check "anonymous means no credential"          ($null -eq (Get-SmtpCredential -Config (New-TestSmtp)))
$cred = Get-SmtpCredential -Config (New-TestSmtp -AuthUser 'DOM\svc-mail' -Password (New-TestSecret))
Check "a user and password make one"           ($cred -and $cred.UserName -eq 'DOM\svc-mail')
Check "with the password intact"               ($cred.GetNetworkCredential().Password -eq 'p@ssw0rd')

Case "settings survive a restart, password included"
$script:Smtp = New-TestSmtp -AuthUser 'svc-mail' -Password (New-TestSecret -Text 'secret-123') `
    -To @('a@x.local','b@x.local') -Events @{ Install = $true }
$script:Smtp.UseSsl = $true
$script:Smtp.Port = 587
Save-SmtpConfig
$back = Load-SmtpConfig
Check "the relay is remembered"                (($back.Server -eq 'relay.test.local') -and ($back.Port -eq 587))
Check "so is TLS"                              ($back.UseSsl)
Check "both recipients come back"              ((@($back.To) -join ',') -eq 'a@x.local,b@x.local')
Check "the chosen events come back"            ($back.Events.Install -and $back.Events.PatchWindow -and -not $back.Events.Reboot)
Check "the password is usable again"           ((Get-SmtpCredential -Config $back).GetNetworkCredential().Password -eq 'secret-123')
Check "and is not on disk in the clear"        (-not ((Get-Content -LiteralPath $script:SmtpFile -Raw) -match 'secret-123'))

Case "one recipient is still a list after a restart"
$script:Smtp = New-TestSmtp -To @('only@x.local')
Save-SmtpConfig
$back = Load-SmtpConfig
Check "not its letters"                        ((@($back.To).Count -eq 1) -and ($back.To[0] -eq 'only@x.local'))

Case "a damaged settings file is reported, not trusted"
$script:Logged = @()
Set-Content -LiteralPath $script:SmtpFile -Value '{ not json' -Encoding UTF8
$back = Load-SmtpConfig
Check "email ends up off"                      (-not $back.Enabled)
Check "and it is logged"                       ((Get-LoggedLike 'WARN|*email settings could not be read*').Count -eq 1)

Case "a relay that refuses the mail is a warning, not a failed run"
$script:Logged = @()
$script:Smtp = New-TestSmtp
Check "it reports the send failed"             (-not (Complete-Notification -Result ([PSCustomObject]@{ Success = $false; Error = '5.7.1 Client was not authenticated' })))
Check "the reason is in the log"               ((Get-LoggedLike 'WARN|*5.7.1 Client was not authenticated*').Count -eq 1)
Check "never as an error"                      ((Get-LoggedLike 'ERROR|*').Count -eq 0)
$script:Logged = @()
Check "a job that returned nothing is handled" (-not (Complete-Notification -Result $null))
Check "and says so"                            ((Get-LoggedLike 'WARN|*returned nothing*').Count -eq 1)
$script:Logged = @()
Check "a sent message is logged"               (Complete-Notification -Result ([PSCustomObject]@{ Success = $true }))
Check "with the recipients"                    ((Get-LoggedLike 'INFO|*ops@test.local*').Count -eq 1)

# -- What a finished run says -------------------------------------------------
Case "an install report counts what still needs doing"
Set-PwGrid @(
    @('SRV-A', 'Reboot Required',       'Yes'),
    @('SRV-B', 'Up to date',            'No'),
    @('SRV-C', 'Completed with errors', 'Yes', 'KB5000001 (0x800F0922 - installer failed)'),
    @('SRV-D', 'Blocked',               '-',   'only 3 GB free on the system drive'))
$rep = Get-BatchReport -Kind 'Install' -Label 'Install all (parallel)' -Servers @('SRV-A','SRV-B','SRV-C','SRV-D')
Check "the summary names the run"              ($rep.Summary -match '^Install all \(parallel\) finished')
Check "it counts the servers"                  ($rep.Summary -match '4 server\(s\)')
Check "and those needing attention"            ($rep.Summary -match '2 need attention')
Check "and those awaiting a reboot"            ($rep.Summary -match '1 awaiting a reboot')
Check "a blocked server is listed with why"    (($rep.Lines -join "`n") -match 'SRV-D : Blocked - only 3 GB free')
Check "a partly failed install too"            (($rep.Lines -join "`n") -match 'SRV-C : Completed with errors')
Check "the one awaiting a reboot is named"     (($rep.Lines -join "`n") -match 'awaiting a reboot: SRV-A')
Check "a clean server is not in the mail"      (-not (($rep.Lines -join "`n") -match 'SRV-B'))

Case "a reboot report does not talk about pending reboots"
Set-PwGrid @(
    @('SRV-A', 'Up to date', 'No'),
    @('SRV-B', 'Offline',    'Pending', 'Server did not come back within 30 minutes.'))
$rep = Get-BatchReport -Kind 'Reboot' -Label 'Reboot all (sequential)' -Servers @('SRV-A','SRV-B')
Check "the summary names the run"              ($rep.Summary -match '^Reboot all \(sequential\) finished')
Check "it counts what needs attention"         ($rep.Summary -match '1 need attention')
Check "and says nothing about awaiting"        (-not ($rep.Summary -match 'awaiting'))
Check "the server that did not come back"      (($rep.Lines -join "`n") -match 'SRV-B : Offline')

Case "a server removed from the grid mid-run is still reported"
$rep = Get-BatchReport -Kind 'Install' -Label 'Install selected' -Servers @('SRV-GONE')
Check "it is not silently dropped"             (($rep.Lines -join "`n") -match 'SRV-GONE : no longer in the server list')

# -- When the run counts as finished ------------------------------------------
$script:ActiveJobs.Clear()
$script:SequentialQueue.Clear()
$script:RebootQueue.Clear()
function Reset-Watch {
    $script:Logged = @(); $script:Sent = @()
    $script:ActiveJobs.Clear(); $script:SequentialQueue.Clear(); $script:RebootQueue.Clear()
    $script:BatchWatch = $null
}
# The real Send-Notification is under test above; here the hook is watched.
function Send-Notification {
    param([string]$Event, [string]$Summary, [string[]]$Lines = @())
    $script:Sent += [PSCustomObject]@{ Event = $Event; Summary = $Summary; Lines = $Lines }
    return $true
}

Case "a run is only reported once everything has finished"
Reset-Watch
$script:Smtp = New-TestSmtp -Events @{ Install = $true }
Set-PwGrid @(
    @('SRV-A', 'Installing...', '-'),
    @('SRV-B', 'Up to date',    'No'))
Check "the watch was armed"                    (Start-BatchWatch -Kind 'Install' -Label 'Install all (parallel)' -Servers @('SRV-A','SRV-B'))
Check "nothing is sent while one installs"     (-not (Step-BatchWatch))
Set-PwRow 'SRV-A' 'Scanning...' '-'
Check "nor while the confirming scan runs"     (-not (Step-BatchWatch))
Set-PwRow 'SRV-A' 'Reboot Required' 'Yes'
Check "then it is sent"                        (Step-BatchWatch)
Check "as the install event"                   ($script:Sent[0].Event -eq 'Install')
Check "with the summary"                       ($script:Sent[0].Summary -match 'Install all \(parallel\) finished')
Check "the summary is in the log too"          ((Get-LoggedLike '*Install all (parallel) finished*').Count -eq 1)
Check "and the watch is done"                  (-not (Step-BatchWatch))

Case "a sequential run is not reported between servers"
Reset-Watch
Set-PwGrid @(,@('SRV-A', 'Up to date', 'No'))
$script:Smtp = New-TestSmtp -Events @{ Reboot = $true }
Start-BatchWatch -Kind 'Reboot' -Label 'Reboot all (sequential)' -Servers @('SRV-A') | Out-Null
$script:RebootQueue.Enqueue('SRV-B')
Check "not while the queue still has servers"  (-not (Step-BatchWatch))
$script:RebootQueue.Clear()
$script:ActiveJobs.Add([PSCustomObject]@{ Name = 'monitor' }) | Out-Null
Check "nor while a monitor is still out"       (-not (Step-BatchWatch))
$script:ActiveJobs.Clear()
Check "only when both are done"                (Step-BatchWatch)

Case "a run nobody wants mailed is not watched at all"
Reset-Watch
$script:Smtp = New-TestSmtp -Events @{ Install = $false }
Check "the watch is not armed"                 (-not (Start-BatchWatch -Kind 'Install' -Label 'Install all' -Servers @('SRV-A')))
Check "and nothing is carried"                 ($null -eq $script:BatchWatch)

Remove-Item -LiteralPath $mailDir -Recurse -Force -ErrorAction SilentlyContinue


# =============================================================================
Write-Host ""
if ($script:Failures -gt 0) {
    Write-Host "RESULT: FAILED - $($script:Failures) of $($script:Checks) checks" -ForegroundColor Red
    exit 1
} else {
    Write-Host "RESULT: PASSED - $($script:Checks) checks" -ForegroundColor Green
    exit 0
}
