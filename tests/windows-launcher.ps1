#Requires -Version 5.1
# Function-level launcher regressions. No browser, server, or tray is started.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$launcherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'dsh-window.ps1'
$tokens = $null
$parseErrors = $null
$launcherAst = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw ($parseErrors | Out-String) }
foreach ($definition in $launcherAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  Set-Item -Path "Function:\$($definition.Name)" -Value $definition.Body.GetScriptBlock()
}

# Windows parses the captured Start-Process command line independently of the
# quoting implementation, so this checks the arguments a native child receives.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshTestArguments {
    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int argc);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    public static string[] Parse(string commandLine) {
        int argc;
        IntPtr memory = CommandLineToArgvW("test.exe " + commandLine, out argc);
        if (memory == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        try {
            string[] result = new string[argc - 1];
            for (int i = 1; i < argc; i++)
                result[i - 1] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size));
            return result;
        } finally { LocalFree(memory); }
    }
}
'@

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -cne $Expected) { throw "$Message`: expected <$Expected>, got <$Actual>" }
}

function Assert-Arguments {
  param([string]$CommandLine, [string[]]$Expected)
  $actual = [DshTestArguments]::Parse($CommandLine)
  Assert-Equal $actual.Count $Expected.Count 'argument count'
  for ($index = 0; $index -lt $Expected.Count; $index++) {
    Assert-Equal $actual[$index] $Expected[$index] "argument $index"
  }
}

$script:Passed = 0
function Test-Case {
  param([string]$Name, [scriptblock]$Body)
  & $Body
  $script:Passed++
  Write-Host "PASS $Name"
}

# Unexpected effects are errors even if a fixture forgets to stub one.
function Start-Process { throw 'A test attempted to start an unstubbed process.' }
function Stop-Process { throw 'A test attempted to stop an unstubbed process.' }
function Get-Process { throw 'A test attempted to inspect an unstubbed process.' }
function Write-Step { param([string]$Message) }
function Write-Note { param([string]$Message) }

Test-Case 'native argument quoting preserves spaces, empty values, quotes, and backslashes' {
  $values = @('C:\App Folder\bin.js', '', 'ordinary', 'say "hello"', 'C:\Folder With Space\', 'slash\"quote', "tab`tvalue")
  Assert-Arguments (ConvertTo-NativeArgumentString -Arguments $values) $values
}

Test-Case 'server launch passes the full entry path and records its own pid and URL' {
  $script:Launch = $null
  $script:Records = @{}
  function Start-Process {
    param($FilePath, $ArgumentList, $RedirectStandardOutput, $RedirectStandardError, [switch]$PassThru, $WindowStyle)
    $script:Launch = $PSBoundParameters
    [pscustomobject]@{ Id = 4567 }
  }
  function Read-ServerUrl { param($LogPath) 'http://127.0.0.1:4080/?token=test-token' }
  function Set-Content { param($LiteralPath, $Value, $Encoding, [switch]$NoNewline) $script:Records[$LiteralPath] = $Value }
  $installDir = 'C:\Users\Test User\Harness App'
  $nodeExe = 'C:\Node Runtime\node.exe'
  $bin = Join-Path $installDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
  $result = Start-DshServer -NodeExe $nodeExe -BinPath $bin -Port 4080 -InstallDir $installDir
  Assert-Equal $script:Launch.FilePath $nodeExe 'runtime path'
  Assert-Arguments $script:Launch.ArgumentList @($bin, 'web', '--no-open', '--port', '4080')
  Assert-Equal $script:Launch.WindowStyle 'Hidden' 'server window style'
  Assert-Equal $script:Launch.RedirectStandardOutput (Join-Path $installDir 'server-4080.log') 'stdout path'
  Assert-Equal $script:Launch.RedirectStandardError (Join-Path $installDir 'server-4080.err.log') 'stderr path'
  Assert-Equal $script:Records[(Join-Path $installDir 'server-4080.pid')] '4567' 'recorded pid'
  Assert-Equal $script:Records[(Join-Path $installDir 'server-4080.url')] $result 'recorded URL'
}

Test-Case 'application launch preserves its URL and profile and scopes window placement' {
  $script:TrayState = @{
    BrowserExe = 'C:\Program Files\Browser\chrome.exe'
    Url = 'http://127.0.0.1:4080/?token=a&example=value'
    ProfileDir = 'C:\Users\Test User\Harness App\browser-profile'
    Width = 1000; Height = 800; Left = 50; Top = 60; Area = $null
  }
  $script:Launch = $null
  $script:PlacementProfile = $null
  function Start-Process { param($FilePath, $ArgumentList) $script:Launch = $PSBoundParameters }
  function Confirm-WindowVisible { param($Area, $ProfileDir) $script:PlacementProfile = $ProfileDir }
  Start-DshAppWindow
  Assert-Equal $script:Launch.FilePath $script:TrayState.BrowserExe 'browser path'
  Assert-Arguments $script:Launch.ArgumentList @(
    "--app=$($script:TrayState.Url)", '--window-size=1000,800', '--window-position=50,60', '--no-first-run',
    "--user-data-dir=$($script:TrayState.ProfileDir)"
  )
  Assert-Equal $script:PlacementProfile $script:TrayState.ProfileDir 'placement ownership'
}

Test-Case 'window lookup requires an exact profile argument and refuses unrelated windows' {
  $profile = 'C:\Users\Test User\Harness\browser-profile'
  $script:Commands = @{}
  $script:Candidates = @(
    [pscustomobject]@{ Id = 10; MainWindowHandle = 1; MainWindowTitle = 'DeepSeek Harness' },
    [pscustomobject]@{ Id = 20; MainWindowHandle = 2; MainWindowTitle = '127.0.0.1:4080' }
  )
  function Get-Process { param($Name, $ErrorAction) $script:Candidates }
  function Get-CimInstance {
    param($ClassName, $Filter, $ErrorAction)
    $processId = [int]($Filter -replace '^ProcessId=', '')
    if ($script:Commands.ContainsKey($processId)) { [pscustomobject]@{ CommandLine = $script:Commands[$processId] } }
  }
  $script:Commands[10] = 'chrome.exe "--user-data-dir=' + $profile + '-other"'
  $script:Commands[20] = 'chrome.exe "--app=http://example.test/?path=' + $profile + '"'
  Assert-Equal (Get-DshAppWindow -ProfileDir $profile) $null 'unrelated title and path substring'
  foreach ($command in @(
    ('chrome.exe "--user-data-dir=' + $profile + '" --app=http://127.0.0.1:4080/'),
    ('chrome.exe --user-data-dir="' + $profile + '"'),
    ('chrome.exe --user-data-dir "' + $profile.ToUpperInvariant() + '"')
  )) {
    $script:Commands[20] = $command
    Assert-Equal (Get-DshAppWindow -ProfileDir $profile).Id 20 'matching profile'
  }
  $script:Commands.Remove(20)
  Assert-Equal (Get-DshAppWindow -ProfileDir $profile) $null 'unavailable process command line'
}

Test-Case 'closing without launch state does not select an unrelated window' {
  $script:TrayState = $null
  function Get-DshAppWindow { throw 'Window lookup must require launch ownership.' }
  Close-DshAppWindow
}

Test-Case 'server ownership rejects reused pids and path substrings before stopping anything' {
  $installDir = 'C:\Harness App'
  $entry = Join-Path $installDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
  $script:RecordedServerPid = '4567'
  $script:ServerCommand = 'node.exe C:\OtherApp\server.js'
  $script:StoppedIds = @()
  function Get-PortOwnerProcessId { param($Candidate) 4567 }
  function Get-Content { param($LiteralPath, $ErrorAction) $script:RecordedServerPid }
  function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) [pscustomobject]@{ CommandLine = $script:ServerCommand } }
  function Get-Process {
    param($Id, $ErrorAction)
    $process = [pscustomobject]@{ HasExited = $false }
    $process | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $false }
    $process
  }
  function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $script:StoppedIds += $Id }
  function Test-PortServing { param($Candidate) $false }
  Assert-Equal (Stop-ManagedPortOwner -Port 4080 -InstallDir $installDir) $false 'reused pid belongs to another process'
  $script:ServerCommand = 'node.exe "' + $entry + '.other"'
  Assert-Equal (Stop-ManagedPortOwner -Port 4080 -InstallDir $installDir) $false 'entry path must be a whole argument'
  $script:ServerCommand = 'node.exe "' + $entry + '" web'
  $script:RecordedServerPid = '9999'
  Assert-Equal (Stop-ManagedPortOwner -Port 4080 -InstallDir $installDir) $false 'different recorded pid'
  Assert-Equal $script:StoppedIds.Count 0 'unowned processes were left running'
  $script:RecordedServerPid = '4567'
  Assert-Equal (Stop-ManagedPortOwner -Port 4080 -InstallDir $installDir) $true 'matching pid and entry point'
  Assert-Equal $script:StoppedIds.Count 1 'one managed process stopped'
  Assert-Equal $script:StoppedIds[0] 4567 'only the managed pid stopped'
}

Test-Case 'restart recovers an exited server without trying to stop another process' {
  $script:TrayState = @{ Port = 4080; AppDir = 'C:\Harness App'; Node = 'node.exe'; Bin = 'bin.js'; Url = 'old' }
  $script:RestartEvents = @()
  function Get-PortOwnerProcessId { param($Candidate) $null }
  function Test-PortServing { param($Candidate) $false }
  function Stop-ManagedPortOwner { throw 'There is no process to stop.' }
  function Start-DshServer { param($NodeExe, $BinPath, $Port, $InstallDir) $script:RestartEvents += 'start'; 'new-token-url' }
  function Close-DshAppWindow { $script:RestartEvents += 'close' }
  function Start-DshAppWindow { $script:RestartEvents += 'open' }
  Restart-DshTrayServer
  Assert-Equal $script:TrayState.Url 'new-token-url' 'fresh URL'
  Assert-Equal ($script:RestartEvents -join ',') 'start,close,open' 'restart sequence'
}

Test-Case 'restart refuses an unmanaged listener and preserves its existing window' {
  $script:TrayState = @{ Port = 4080; AppDir = 'C:\Harness App'; Node = 'node.exe'; Bin = 'bin.js'; Url = 'old' }
  $script:StopChecked = $false
  function Get-PortOwnerProcessId { param($Candidate) 9876 }
  function Stop-ManagedPortOwner { param($Port, $InstallDir) $script:StopChecked = $true; $false }
  function Start-DshServer { throw 'An unmanaged server must not be replaced.' }
  function Close-DshAppWindow { throw 'An unmanaged server must keep its window.' }
  function Start-DshAppWindow { throw 'An unmanaged server must keep its window.' }
  Restart-DshTrayServer
  Assert-Equal $script:StopChecked $true 'ownership check'
  Assert-Equal $script:TrayState.Url 'old' 'existing URL'
}

Test-Case 'restart stops a managed listener before starting its replacement' {
  $script:TrayState = @{ Port = 4080; AppDir = 'C:\Harness App'; Node = 'node.exe'; Bin = 'bin.js'; Url = 'old' }
  $script:RestartEvents = @()
  function Get-PortOwnerProcessId { param($Candidate) 4567 }
  function Stop-ManagedPortOwner { param($Port, $InstallDir) $script:RestartEvents += 'stop'; $true }
  function Start-DshServer { param($NodeExe, $BinPath, $Port, $InstallDir) $script:RestartEvents += 'start'; 'new-token-url' }
  function Close-DshAppWindow { $script:RestartEvents += 'close' }
  function Start-DshAppWindow { $script:RestartEvents += 'open' }
  Restart-DshTrayServer
  Assert-Equal ($script:RestartEvents -join ',') 'stop,start,close,open' 'managed restart sequence'
}

Test-Case 'default browser launch keeps the tray, supports NoTray, and permits tray self-test' {
  $Uninstall = $false; $NoSync = $true; $SilentNodeInstall = $true; $NoWindow = $false
  $AppDir = 'C:\Harness App'; $Port = 4080; $Browser = 'edge'; $Url = 'http://127.0.0.1:4080/?token=existing'
  $NoTray = $false; $TraySelfTest = $false
  $script:BrowserUrls = @(); $script:TrayStarts = 0; $script:TrayTests = 0
  function Resolve-SupportedNode { param($InstallDir, [switch]$SkipSetup) @{ Exe = 'C:\Node Runtime\node.exe'; Version = '24.0.0' } }
  function Get-DshBin { param($InstallDir) 'C:\Harness App\node_modules\@deepseek-ai\dsh\lib\bin.js' }
  function New-Shortcuts { param($ScriptPath, $IconPath) }
  function Get-BrowserExe { param($Preference) $null }
  function Start-Process { param($FilePath) $script:BrowserUrls += $FilePath }
  function Start-DshTray { param($State) $script:TrayStarts++; Assert-Equal $State.BrowserExe $null 'fallback browser state' }
  function Test-DshTray { param($State) $script:TrayTests++ }
  function Enter-DshTraySlot {
    param($InstallDir)
    $slot = [pscustomobject]@{}
    $slot | Add-Member -MemberType ScriptMethod -Name WaitOne -Value { param($Timeout) $true }
    $slot | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
    $slot
  }
  Invoke-Launcher
  Assert-Equal $script:BrowserUrls.Count 1 'default browser opened once'
  Assert-Equal $script:BrowserUrls[0] $Url 'default browser URL'
  Assert-Equal $script:TrayStarts 1 'fallback tray started'
  $NoTray = $true
  Invoke-Launcher
  Assert-Equal $script:BrowserUrls.Count 2 'NoTray opens the browser'
  Assert-Equal $script:TrayStarts 1 'NoTray skips the tray'
  $NoTray = $false; $TraySelfTest = $true
  Invoke-Launcher
  Assert-Equal $script:TrayTests 1 'tray self-test executes without Chromium'
  Assert-Equal $script:BrowserUrls.Count 2 'self-test leaves browser closed'
}

Write-Host "$script:Passed Windows launcher tests passed."
