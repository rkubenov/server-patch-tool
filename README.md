# Server Patch Tool

A PowerShell + WPF desktop tool for driving Windows Updates across domain-joined servers: scan for missing updates, install them, reboot, and confirm the result — all from one grid.

> [!NOTE]
> **Field status.** In use against test and production servers: scan, install, reboot, and the confirming scan afterwards. That includes a cumulative update that failed on one server while the rest of the batch installed cleanly, and sequential batches where each reboot waited for the previous server to come back before the next one was touched.

## What it does

- Scan many servers for pending Windows Updates at once
- Install updates in parallel, or one server at a time
- Reboot with confirmation that the server actually came back
- Import the server list from a file or from Active Directory
- Several credential sets, for different domains, bound to individual servers, with in-place password changes
- A stale stored password is caught before a run, and stops one before it locks the account
- Named updates held back across every install, and a pre-flight that refuses an install that cannot succeed
- Export results to CSV

## Requirements

- Windows PowerShell 5.1
- WinRM (port 5985) enabled on the target servers
- An account with local administrator rights on the targets
- The `ActiveDirectory` module — only for importing a list from AD

## Running

```bash
powershell.exe -ExecutionPolicy Bypass -NoProfile -File ServerPatchTool.ps1
```

Or through `Launch.bat`.

## How installing works

Windows Updates cannot be installed over an ordinary remote session: the update agent's COM objects refuse a delegated network token with "Access denied".

So the tool connects to the server over WinRM, creates a temporary scheduled task running as `SYSTEM`, and lets that do the work. Results are written to a JSON file which is read back, after which the task and its temporary files are removed — except when the time limit expired (see below).

The working directory is `%ProgramData%\ServerPatchTool`, permitted to `SYSTEM` and `Administrators` only. This matters: in a world-writable directory such as `%SystemRoot%\Temp`, an unprivileged local user could swap the script between the moment it is written and the moment `SYSTEM` executes it — a straightforward path to code execution as `SYSTEM`. The ACL is re-asserted on every run, in case the directory was pre-created with looser permissions.

Every run gets its own GUID in the task and file names, so two operations against the same server cannot read or delete each other's results.

### Long installs

The install time limit is set in the toolbar ("Limit", 30–240 minutes, default 90): cumulative updates routinely run for more than an hour. Running out of time cancels nothing — the install continues on the server, and the tool merely stops waiting and marks the row `Still installing`. In that case the task and its log are **deliberately left behind** in `%ProgramData%\ServerPatchTool`: deleting the task would not stop a running install, only destroy the one record of what happened. Leftovers older than a week are cleaned up during the next operation against that server.

`Still installing` no longer sits there until somebody scans by hand. The tool comes back to such a server every 10 minutes, up to six times, and scans as soon as the server is free to answer. The first successful scan replaces the status with a real one. If the server has still not answered after an hour, the tool stops trying and says plainly in the log that a manual scan is needed. Re-checks do not survive closing the window.

### Watching the reboot

The watch limit is set in the toolbar too ("Reboot", 15–120 minutes, default 30). The tool does not ping. It connects over WinRM and compares the OS boot time against a snapshot taken before the restart — so "back online" means the machine really rebooted, not merely that the host started answering again. A server applying a cumulative update while booting can exceed 30 minutes; raise the limit for those, or the watch ends with `Offline` or `Partially Online`.

If the watch itself falls over (the monitor job returned nothing, or threw), the server is **not** declared broken: neither outcome says anything about the server's state. A scan is started instead, which does establish the truth, and the reason the watch failed is written to the log.

In sequential mode the queue waits on this: the next server is not rebooted until the previous one's watch has finished, whether it ended by the server coming back, by the limit expiring, or by the watch failing. A server that never returns delays the queue by the watch limit; it does not stall it.

### Reading the status after an install

Results are reported per KB. If some updates did not install, the server gets the status `Completed with errors`, and the updates that failed stay in the `Available` count and are listed in `Details` and in the log. After an install the tool runs a confirming scan and replaces the installer's own account of events with the server's verified state; when a reboot is required, that scan happens after it.

Updates that failed carry the update agent's failure code:

```
KB5120238 (0x800F0922 - installer failed - often space on the system partition)
```

That is the `HRESULT`, not the `ResultCode` — the latter only ever says "Failed" and explains nothing. Six of the most common codes get a short hint alongside them; the rest show the code itself, which is enough to search on. If the agent returned no code at all (an aborted install, for instance), the row shows `result code N` rather than a misleading `0x00000000`.

The `Installed` column refers only to the most recent install run: it is cleared when one starts and filled in only when one succeeds, so a failed install leaves no stale number behind. Scanning does not change it — it is a record that an install happened, not the server's current state, and it survives a restart of the tool.

## Where data lives

| What | Where | Note |
|---|---|---|
| Server list and results | `servers.json` next to the script | Gitignored — contains host names |
| Tool log | `logs/ServerPatchTool_YYYYMMDD.log` | One file per day |
| Credentials | `%LOCALAPPDATA%\ServerPatchTool\credentials.json` | Only with "Remember" ticked |
| Held-back KBs | `%LOCALAPPDATA%\ServerPatchTool\excluded-kb.json` | Removed when the list is cleared |

`servers.json` format:

```json
[
  {
    "Name": "SRV-EXAMPLE-01",
    "Credential": "EXAMPLE\svc-patch",
    "Selected": true,
    "Status": "Available (3)",
    "Available": "3",
    "Installed": "0",
    "RebootRequired": "No",
    "LastScan": "2026-08-11 02:15",
    "Details": "KB0000000: example",
    "UpdateList": []
  }
]
```

## About stored credentials

Saving the password is **optional**, via the "Remember" checkbox. It is encrypted with Windows DPAPI under the current user account: the file is worthless to any other Windows account and on any other machine.

**What that does not give you:** protection from anyone already running as this account on this machine — any code running as you can decrypt it. For an account with domain administrator rights, that means its security is only as good as the security of the workstation.

Unticking the box deletes the file immediately, not on exit. Removing a credential rewrites the file, so a deleted account does not reappear on the next launch — including when it was the last one, in which case the file is removed rather than written empty.

The "Test" button proves a stored credential still authenticates before a maintenance window finds out the hard way. It opens one WinRM session against a single server, deliberately over the same path the real work uses, and says which of the two things went wrong: a rejected account sends you to Change Password, an unreachable server does not.

That matters because of what the tool does with a password that has been rotated in the domain but not here. It fires the account at every server in the batch at once, and each rejection is a bad logon against the same account, so a fifty-server scan walks straight into the domain lockout policy and locks the account the maintenance window depends on. The guard counts rejected logons across the whole run, stops it once two in a row come back rejected, and stops it immediately if a server reports the account already locked. A server that is merely unreachable does not count, and a single success anywhere clears the count - so a run only halts when the account itself looks like the problem.

A rotated domain password is changed in place with the "Change Password" button: the stored username stays exactly as it was, so every server already bound to that account keeps working, and the new password is written to the file straight away rather than only living until the tool is closed.

## Before an install

Two things happen before any update is downloaded.

**Held-back KBs.** One bad cumulative fails on every server in the estate, and until the vendor fixes it the only way through a window was to let it fail again each time. The "Held-back KBs" button takes a list of KB numbers - typed however you like, KB5120238 or 5120238 - and every install skips them until the list is cleared. The list travels to each server as a prelude line prepended to the install payload, so the update agent never selects those updates at all, rather than being told to undo them afterwards. Anything typed that is not a KB number is dropped rather than sent: a stray word would match nothing on the server and look exactly like a working exclusion, right up to the moment the update installs anyway.

**Pre-flight.** An install that runs the system drive dry fails with 0x80070070 about an hour in, having spent the window and changed nothing, and a disabled update agent fails on the first call into it. Both facts cost one WinRM round trip to learn beforehand, so they are learned beforehand. A server with less than 8 GB free on its system drive, or with the Windows Update service disabled or missing, is marked "Blocked" with the reason and no install is started - and in a sequential run the queue moves straight on to the next server rather than stopping. A reboot that is already pending is reported as a warning instead: plenty of estates patch on top of one, and it is worth having in the log when a failure follows.

## Checks before changing anything


```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File _validate.ps1
```

Parses the main file, loads the XAML markup, checks that every named control resolves, and separately parses the code that is shipped out to the servers. That last part matters: the payloads live inside here-strings, so parsing the file does not look into them, and a syntax error there would surface only on a live server, halfway through a maintenance window.

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File _tests.ps1
```

Behavioural tests — 257 checks, no live server and no window required. The tool is a single file that builds a window as it loads, so it cannot simply be dot-sourced; instead each unit under test is located in the real file with the PowerShell parser and evaluated on its own against stubs. That way the shipped code is exercised rather than a copy of it, and a test fails loudly if the code it targets is renamed or moved.

Covered: the job completion timer, install reporting, credential selection, removal and password changes, the stale-password guard and the credential test, held-back updates and the install pre-flight, the post-reboot monitor and how it is launched, the sequential queues, deferred re-checks, and both time limits.

> [!IMPORTANT]
> `.ps1` files are stored **without a BOM**, so PowerShell 5.1 reads them in the system's single-byte code page. Code and strings must stay ASCII. The validator checks this.

## A note on PowerShell closures

This cost the project two production failures, so it is worth writing down.

Every completion callback here is a closure created with `.GetNewClosure()`, and a closure is bound to a module of its own. It can see only the local variables that were copied into it at the moment it was created. Three consequences:

- A `$script:` variable **read** inside a closure comes out empty.
- An assignment to a `$script:` variable inside a closure sets a copy, and never reaches the variable everyone else reads.
- A closure created **inside another closure** captures nothing at all.

Method calls still work — `$queue.Dequeue()` mutates the real object — which is exactly why this hides so well: half of the code appears to behave.

Anything a callback needs to do therefore belongs in a named function. Function bodies run in the script's own session state, so their reads and writes land where they are expected. `Step-SequentialInstallQueue`, `Step-RebootQueue`, `Start-RebootMonitor` and `Complete-ADImport` all exist for this reason, and `_tests.ps1` guards each of them.

## Known limitations

- **No per-server locking.** Nothing stops a scan from being started against a server that is currently installing. Task and file names are unique per run, so nothing is corrupted; the update agent serialises the work and the second operation fails with a confusing error.
- **Nothing survives closing the window.** In-flight monitoring, sequential queues and deferred re-checks are all lost. Work already handed to a server carries on there regardless.
- **One file, including the XAML.** Splitting it up would make more of it testable.
- The grid rebuilds rows through `RemoveAt`/`Insert` rather than `INotifyPropertyChanged`, so it flickers on update.
- `Get-StatusColor` is dead code: defined, never called.
- **Two paths have not come up in practice yet:** importing from Active Directory, and the deferred re-checks that follow an install time-out. Both are covered by the tests; neither has been exercised against a live server.

## License

MIT — see [LICENSE](LICENSE).
