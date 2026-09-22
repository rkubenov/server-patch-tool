#Requires -Version 5.1
<#
.SYNOPSIS
    Static validation of ServerPatchTool.ps1 without launching the GUI.
.DESCRIPTION
    1. Parses the script with the PowerShell parser and reports syntax errors.
    2. Extracts the XAML markup from its here-string and loads it, so markup
       errors surface here instead of at application start.
    3. Verifies every x:Name in the markup resolves to a control.
    4. Warns about non-ASCII characters: these files carry no BOM, so
       Windows PowerShell 5.1 would decode them using the ANSI codepage.

    Exits with code 1 if any check fails.
.NOTES
    Run: powershell -NoProfile -ExecutionPolicy Bypass -File _validate.ps1
#>

$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot 'ServerPatchTool.ps1'
$failed = $false

Write-Host "=== PowerShell syntax ===" -ForegroundColor Cyan
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors) | Out-Null

if ($errors -and $errors.Count -gt 0) {
    $failed = $true
    foreach ($e in $errors) {
        Write-Host ("  line {0,-5} {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
    }
} else {
    Write-Host "  OK - no syntax errors" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== XAML markup ===" -ForegroundColor Cyan
try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $text = Get-Content -Path $target -Raw

    # The markup sits in the here-string assigned to [xml]$xaml
    $pattern = '(?s)\[xml\]\$xaml\s*=\s*@' + [char]34 + '\r?\n(.*?)\r?\n' + [char]34 + '@'
    $match = [regex]::Match($text, $pattern)

    if (-not $match.Success) {
        Write-Host "  ERROR - could not locate the XAML here-string block" -ForegroundColor Red
        $failed = $true
    } else {
        [xml]$xamlDoc = $match.Groups[1].Value
        $reader = [System.Xml.XmlNodeReader]::new($xamlDoc)
        $window = [Windows.Markup.XamlReader]::Load($reader)

        # Names declared inside a ControlTemplate or DataTemplate belong to the template's own
        # namescope and are deliberately not reachable via Window.FindName.
        $named = $xamlDoc.SelectNodes(
            "//*[@*[local-name()='Name']][not(ancestor::*[local-name()='ControlTemplate' or local-name()='DataTemplate'])]")
        $names = @($named | ForEach-Object {
            $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        } | Where-Object { $_ })
        $missing = @($names | Where-Object { -not $window.FindName($_) })

        if ($missing.Count -gt 0) {
            Write-Host "  ERROR - unresolved controls: $($missing -join ', ')" -ForegroundColor Red
            $failed = $true
        } else {
            Write-Host "  OK - XAML loads, all $($names.Count) named controls resolve" -ForegroundColor Green
        }

        # The patch-window dialog is loaded the way the tool loads it: with the
        # main window's styles copied in, which its StaticResources depend on.
        $dlgPattern = '(?s)\$script:PatchWindowXaml\s*=\s*@' + [char]39 + '\r?\n(.*?)\r?\n' + [char]39 + '@'
        $dlgMatch = [regex]::Match($text, $dlgPattern)
        if (-not $dlgMatch.Success) {
            Write-Host "  ERROR - could not locate the patch-window dialog markup" -ForegroundColor Red
            $failed = $true
        } else {
            $res = $xamlDoc.DocumentElement.ChildNodes |
                Where-Object { $_.LocalName -eq 'Window.Resources' } | Select-Object -First 1
            [xml]$dlgDoc = $dlgMatch.Groups[1].Value.Replace('__RESOURCES__', $res.InnerXml)
            $dlg = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($dlgDoc))
            $dlgNames = @($dlgDoc.SelectNodes(
                "//*[@*[local-name()='Name']][not(ancestor::*[local-name()='ControlTemplate' or local-name()='DataTemplate'])]") |
                ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') } |
                Where-Object { $_ })
            $dlgMissing = @($dlgNames | Where-Object { -not $dlg.FindName($_) })
            if ($dlgMissing.Count -gt 0) {
                Write-Host "  ERROR - patch-window dialog, unresolved controls: $($dlgMissing -join ', ')" -ForegroundColor Red
                $failed = $true
            } else {
                Write-Host "  OK - patch-window dialog loads, all $($dlgNames.Count) named controls resolve" -ForegroundColor Green
            }
        }
    }
} catch {
    Write-Host "  ERROR - XAML: $($_.Exception.Message)" -ForegroundColor Red
    $failed = $true
}

Write-Host ""
Write-Host "=== Remote payloads ===" -ForegroundColor Cyan
# The payloads run on the servers and live inside here-strings, so the parse
# above cannot see into them: a syntax error in one would surface only on a
# live server, halfway through a maintenance window.
$fileAst = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$null)
$payloads = @($fileAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -like '$script:*Payload' }, $true))

if ($payloads.Count -eq 0) {
    Write-Host "  ERROR - no payloads found to check" -ForegroundColor Red
    $failed = $true
} else {
    foreach ($p in $payloads) {
        $name = $p.Left.Extent.Text
        $str  = $p.Right.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $false) |
            Select-Object -First 1
        if (-not $str) {
            Write-Host "  ERROR - $name is not a plain here-string" -ForegroundColor Red
            $failed = $true
            continue
        }
        $pErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($str.Value, [ref]$null, [ref]$pErrors) | Out-Null
        if ($pErrors -and $pErrors.Count -gt 0) {
            $failed = $true
            foreach ($e in $pErrors) {
                Write-Host ("  {0} line {1,-4} {2}" -f $name, $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
            }
        } else {
            Write-Host "  OK - $name parses" -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "=== Encoding ===" -ForegroundColor Cyan
# These scripts are stored without a BOM, so anything outside ASCII is decoded
# with the ANSI codepage by Windows PowerShell 5.1 and will be corrupted.
$bytes = [System.IO.File]::ReadAllBytes($target)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$lines  = [System.IO.File]::ReadAllLines($target)
$bad    = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -cmatch '[^\x00-\x7F]') { $bad += ($i + 1) }
}

if ($hasBom) {
    Write-Host "  OK - file has a UTF-8 BOM, non-ASCII is safe" -ForegroundColor Green
} elseif ($bad.Count -eq 0) {
    Write-Host "  OK - pure ASCII, no BOM needed" -ForegroundColor Green
} else {
    $shown = ($bad | Select-Object -First 10) -join ', '
    Write-Host "  WARN - no BOM but non-ASCII on $($bad.Count) line(s): $shown" -ForegroundColor Yellow
    Write-Host "         Safe only while these stay inside comments." -ForegroundColor Yellow
}

Write-Host ""
if ($failed) {
    Write-Host "RESULT: FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "RESULT: PASSED" -ForegroundColor Green
    exit 0
}
