#Requires -Version 5.1
<#
.SYNOPSIS
  Start DeepSeek Harness in a standalone application window.

.DESCRIPTION
  Installs (first run) and launches @deepseek-ai/dsh, then opens the Web UI as
  a dedicated browser application window: no tab strip, no address bar, its own
  taskbar entry. Edge or Chrome is used when one is installed, because those
  browsers expose the --app= window mode; otherwise the default browser opens a
  normal tab as a fallback.

  The official Web build ships install metadata (manifest.webmanifest, display
  fullscreen), so the window can also be installed as a PWA from the browser's
  own menu. This script does not modify the dsh installation.

  Each launch compares the installed launcher and icon with the repository and
  replaces them when they differ, so a published fix reaches this machine
  without reinstalling. An unavailable network leaves the installed copy in
  place and the launch continues.

.PARAMETER Port
  Loopback port for the Web UI. Default 3080. When that port already serves a
  harness instance the script reuses it instead of starting a second server.

.PARAMETER AppDir
  Installation directory. Default %LOCALAPPDATA%\dsh-shortcut.

.PARAMETER Url
  Open this URL instead of starting or reusing a server. Useful for an instance
  you already started yourself.

.PARAMETER NoWindow
  Start the server only, then print the authenticated URL without opening a
  browser window.

.PARAMETER Browser
  Browser executable to drive in application mode: edge (default), chrome, or
  an absolute path to a Chromium-based executable.

.PARAMETER Uninstall
  Remove the installation directory and the Start Menu and desktop shortcuts.

.PARAMETER NoSync
  Start the installed copy without comparing it with the repository.
#>
[CmdletBinding()]
param(
  [int]$Port = 3080,
  [string]$AppDir = (Join-Path $env:LOCALAPPDATA 'dsh-shortcut'),
  [string]$Url,
  [switch]$NoWindow,
  [string]$Browser = 'edge',
  [switch]$Uninstall,
  [switch]$NoSync
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$DshPackage = '@deepseek-ai/dsh'
$ShortcutName = 'DeepSeek Harness'
$RepoRaw = 'https://raw.githubusercontent.com/dieWehmut/dsh-shortcut/main'

# Bound parameters are not visible inside a function, so keep a script-scope
# copy for the restart that follows a launcher update.
$CallerParameters = @{}
foreach ($key in $PSBoundParameters.Keys) { $CallerParameters[$key] = $PSBoundParameters[$key] }

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Note { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Fail { param([string]$Message) Write-Host "ERROR: $Message" -ForegroundColor Red }

<#
.SYNOPSIS
  Report a failure where the user can see it.
.DESCRIPTION
  A shortcut launch runs with a hidden console, so console text alone leaves a
  click looking like nothing happened. Show a message box as well; without an
  interactive desktop the console text is the whole report.
.PARAMETER Message
  Failure text shown in the console and the message box.
#>
function Show-Failure {
  param([string]$Message)
  Write-Fail $Message
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    [void][System.Windows.Forms.MessageBox]::Show($Message, $ShortcutName, 'OK', 'Error')
  } catch {
    Write-Note 'no interactive desktop; the console text is the whole report'
  }
}

<#
.SYNOPSIS
  Read a repository file into memory.
.DESCRIPTION
  A launch must not stall on an unavailable network, so the request fails fast
  and the caller keeps the installed copy.
.PARAMETER Uri
  Raw repository URL to read.
#>
function Get-RemoteBytes {
  param([string]$Uri)
  Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds(8)
  try {
    $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
    try {
      if (-not $response.IsSuccessStatusCode) { throw "the repository answered $([int]$response.StatusCode)" }
      return ,($response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
    } finally {
      $response.Dispose()
    }
  } finally {
    $client.Dispose()
  }
}

function Get-BytesHash {
  param([byte[]]$Bytes)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

function Get-FileHashText {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

<#
.SYNOPSIS
  Replace the installed copy when the repository holds different files.
.DESCRIPTION
  The installed launcher and icon are compared with the repository by content,
  so any published fix reaches this machine on the next launch. A launcher that
  does not parse is not installed, so a bad push leaves the installed copy
  working. Without a network the installed copy stays in place and the launch
  continues.
.PARAMETER InstallDir
  Installation directory that holds the launcher, its icon, and the dsh package.
.PARAMETER ScriptPath
  Launcher file that the current process runs.
#>
function Update-FromRepo {
  param([string]$InstallDir, [string]$ScriptPath)
  $targets = @(
    @{ Name = 'dsh-window.ps1'; Uri = "$RepoRaw/dsh-window.ps1"; Path = (Join-Path $InstallDir 'dsh-window.ps1') },
    @{ Name = 'dsh.ico'; Uri = "$RepoRaw/assets/dsh.ico"; Path = (Join-Path $InstallDir 'assets\dsh.ico') }
  )
  $changed = @()
  foreach ($target in $targets) {
    try {
      $remote = Get-RemoteBytes -Uri $target.Uri
    } catch {
      Write-Note "sync skipped ($($_.Exception.Message)); keeping the installed copy"
      return $false
    }
    if ($null -eq $remote -or $remote.Length -eq 0) {
      Write-Note 'sync skipped (the repository returned an empty file); keeping the installed copy'
      return $false
    }
    if ((Get-BytesHash -Bytes $remote) -eq (Get-FileHashText -Path $target.Path)) { continue }
    if ($target.Name -like '*.ps1') {
      $tokens = $null
      $errors = $null
      [void][System.Management.Automation.Language.Parser]::ParseInput([Text.Encoding]::UTF8.GetString($remote).TrimStart([char]0xFEFF), [ref]$tokens, [ref]$errors)
      if (@($errors).Count -gt 0) {
        Write-Note "sync skipped (the repository $($target.Name) does not parse); keeping the installed copy"
        return $false
      }
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $target.Path) -Force | Out-Null
    $staged = "$($target.Path).new"
    [IO.File]::WriteAllBytes($staged, $remote)
    Move-Item -LiteralPath $staged -Destination $target.Path -Force
    Write-Note "updated $($target.Name)"
    $changed += $target.Path
  }
  if ($changed.Count -eq 0) {
    Write-Note 'launcher is current'
    return $false
  }
  $running = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction SilentlyContinue).Path
  foreach ($path in $changed) {
    $installed = (Resolve-Path -LiteralPath $path -ErrorAction SilentlyContinue).Path
    if ($null -ne $running -and $null -ne $installed -and $installed -eq $running) { return $true }
  }
  return $false
}

function Get-NodeExe {
  $candidates = @(
    (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  $command = Get-Command node -ErrorAction SilentlyContinue
  if ($null -ne $command) { return $command.Source }
  return $null
}

function Get-NpmCmd {
  $command = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if ($null -ne $command) { return $command.Source }
  $node = Get-NodeExe
  if ($null -ne $node) {
    $npm = Join-Path (Split-Path -Parent $node) 'npm.cmd'
    if (Test-Path -LiteralPath $npm) { return $npm }
  }
  return $null
}

function Get-BrowserExe {
  param([string]$Preference)
  if ($Preference -match '[\\/]') {
    if (Test-Path -LiteralPath $Preference) { return $Preference }
    return $null
  }
  $catalog = @{
    edge = @(
      (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
      (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
      (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )
    chrome = @(
      (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
      (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
  }
  $order = if ($Preference -eq 'edge') { @('edge', 'chrome') } else { @('chrome', 'edge') }
  foreach ($name in $order) {
    foreach ($candidate in $catalog[$name]) {
      if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
  }
  return $null
}

function Get-DshBin {
  param([string]$InstallDir)
  $bin = Join-Path $InstallDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
  if (Test-Path -LiteralPath $bin) { return $bin }
  return $null
}

function Test-PortServing {
  param([int]$Candidate)
  try {
    $client = [System.Net.Sockets.TcpClient]::new()
    $client.Connect('127.0.0.1', $Candidate)
    $client.Close()
    return $true
  } catch {
    return $false
  }
}

function Invoke-DshInstall {
  param([string]$InstallDir)
  $npm = Get-NpmCmd
  if ($null -eq $npm) {
    throw 'npm was not found. Install Node.js 22.19 or newer from https://nodejs.org/ and run this script again.'
  }
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  $manifest = Join-Path $InstallDir 'package.json'
  if (-not (Test-Path -LiteralPath $manifest)) {
    [IO.File]::WriteAllText($manifest, "{`n  `"name`": `"dsh-shortcut`",`n  `"private`": true`n}`n", [Text.UTF8Encoding]::new($false))
  }
  Write-Step "Installing $DshPackage (first run; 1-3 minutes)"
  Push-Location $InstallDir
  try {
    & $npm install $DshPackage --no-audit --no-fund --loglevel=error
    if ($LASTEXITCODE -ne 0) { throw "npm install exited with code $LASTEXITCODE" }
  } finally {
    Pop-Location
  }
}

function Read-ServerUrl {
  param([string]$LogPath)
  for ($attempt = 0; $attempt -lt 150; $attempt++) {
    Start-Sleep -Milliseconds 800
    if (Test-Path -LiteralPath $LogPath) {
      $text = Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue
      if ($null -ne $text -and $text.Length -gt 0) {
        $match = [regex]::Match($text, 'https?://127\.0\.0\.1:\d+/\?token=\S+')
        if ($match.Success) { return $match.Value }
      }
    }
  }
  return $null
}

function New-Shortcuts {
  param([string]$ScriptPath, [string]$IconPath)
  $shell = New-Object -ComObject WScript.Shell
  $targets = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "$ShortcutName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('StartMenu')) "Programs\$ShortcutName.lnk")
  )
  foreach ($target in $targets) {
    try {
      $shortcut = $shell.CreateShortcut($target)
      $shortcut.TargetPath = 'powershell.exe'
      $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
      $shortcut.WorkingDirectory = Split-Path -Parent $ScriptPath
      if (Test-Path -LiteralPath $IconPath) { $shortcut.IconLocation = $IconPath }
      $shortcut.Description = 'DeepSeek Harness in an application window'
      $shortcut.WindowStyle = 7
      $shortcut.Save()
      Write-Note "shortcut: $target"
    } catch {
      Write-Note "could not write shortcut $target"
    }
  }
}

function Initialize-WindowApi {
  if ('Dsh.Win32' -as [type]) { return }
  Add-Type -Namespace Dsh -Name Win32 -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
"@
}

<#
.SYNOPSIS
  Raise the application window and keep it inside the screen work area.
.DESCRIPTION
  A Chromium app window can restore at a position remembered from another
  display, or at a size larger than this display, leaving it off-screen where a
  click looks like no response. This waits for the window, moves it back into
  view when any edge falls outside the work area, and raises it.
.PARAMETER Area
  Primary screen work area the window must stay inside.
#>
function Confirm-WindowVisible {
  param([System.Drawing.Rectangle]$Area)
  Initialize-WindowApi
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 700
    $candidates = @(Get-Process msedge, chrome -ErrorAction SilentlyContinue |
      Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -match 'DeepSeek Harness|DSH' })
    foreach ($window in $candidates) {
      $rect = New-Object Dsh.Win32+RECT
      if (-not [Dsh.Win32]::GetWindowRect($window.MainWindowHandle, [ref]$rect)) { continue }
      $width = $rect.Right - $rect.Left
      $height = $rect.Bottom - $rect.Top
      if ($width -le 0 -or $height -le 0) { continue }
      $outside = $rect.Left -lt $Area.X -or $rect.Top -lt $Area.Y -or $rect.Right -gt ($Area.X + $Area.Width) -or $rect.Bottom -gt ($Area.Y + $Area.Height)
      if ($outside) {
        $width = [Math]::Min($width, [int]($Area.Width * 0.94))
        $height = [Math]::Min($height, [int]($Area.Height * 0.94))
        $left = [int]($Area.X + ($Area.Width - $width) / 2)
        $top = [int]($Area.Y + ($Area.Height - $height) / 2)
        [void][Dsh.Win32]::MoveWindow($window.MainWindowHandle, $left, $top, $width, $height, $true)
        Write-Note "moved the window into view at ($left,$top) ${width}x${height}"
      }
      [void][Dsh.Win32]::SetForegroundWindow($window.MainWindowHandle)
      return
    }
  }
}

function Invoke-Uninstall {
  param([string]$InstallDir)
  foreach ($name in @($ShortcutName)) {
    $paths = @(
      (Join-Path ([Environment]::GetFolderPath('Desktop')) "$name.lnk"),
      (Join-Path ([Environment]::GetFolderPath('StartMenu')) "Programs\$name.lnk")
    )
    foreach ($path in $paths) {
      if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-Note "removed $path" }
    }
  }
  if (Test-Path -LiteralPath $InstallDir) {
    $resolved = (Resolve-Path -LiteralPath $InstallDir).Path
    if ($resolved -like "$env:LOCALAPPDATA*") {
      Remove-Item -LiteralPath $resolved -Recurse -Force
      Write-Note "removed $resolved"
    } else {
      Write-Fail "refusing to remove $resolved outside LOCALAPPDATA"
    }
  }
  Write-Step 'Uninstalled. Your Harness data under ~/.dsh was left in place.'
}

# ---- main ------------------------------------------------------------------

function Invoke-Launcher {
  if ($Uninstall) {
    Invoke-Uninstall -InstallDir $AppDir
    return
  }

  $scriptPath = $PSCommandPath
  if (-not $NoSync) {
    if (Update-FromRepo -InstallDir $AppDir -ScriptPath $scriptPath) {
      Write-Step 'The launcher was updated from the repository; restarting'
      # No -WindowStyle: the child inherits this console, so a shortcut launch stays hidden and a terminal launch keeps printing.
      $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
      foreach ($key in $CallerParameters.Keys) {
        if ($key -eq 'NoSync') { continue }
        $value = $CallerParameters[$key]
        if ($value -is [switch]) { if ($value.IsPresent) { $forward += "-$key" } }
        else { $forward += @("-$key", [string]$value) }
      }
      & powershell.exe @forward
      exit $LASTEXITCODE
    }
  }

  $node = Get-NodeExe
  if ($null -eq $node) {
    throw 'Node.js was not found. Install Node.js 22.19 or newer from https://nodejs.org/ and run this script again.'
  }

  $versionText = (& $node --version) -replace '^v', ''
  $versionParts = $versionText -split '\.'
  $major = [int]$versionParts[0]
  $minor = [int]$versionParts[1]
  $supported = ($major -eq 22 -and $minor -ge 19) -or ($major -ge 24)
  if (-not $supported) {
    throw "Node $versionText is below the supported range (22.19+, or 24+). Update Node.js and run this script again."
  }
  Write-Note "node $versionText"

  $bin = Get-DshBin -InstallDir $AppDir
  if ($null -eq $bin) {
    Invoke-DshInstall -InstallDir $AppDir
    $bin = Get-DshBin -InstallDir $AppDir
  }
  if ($null -eq $bin) { throw 'The dsh package did not install correctly.' }

  $iconPath = Join-Path (Split-Path -Parent $scriptPath) 'assets\dsh.ico'
  New-Shortcuts -ScriptPath $scriptPath -IconPath $iconPath

  if ([string]::IsNullOrWhiteSpace($Url)) {
    if (Test-PortServing -Candidate $Port) {
      Write-Step "Port $Port already serves a harness instance; reusing it"
      $Url = "http://127.0.0.1:$Port/"
      if (-not $NoWindow) {
        Write-Note 'If the window reports "unauthorized", close that server and start again to mint a fresh token.'
      }
    } else {
      $log = Join-Path $AppDir 'server.log'
      $logErr = Join-Path $AppDir 'server.err.log'
      Write-Step "Starting dsh web on port $Port"
      $arguments = @($bin, 'web', '--no-open', '--port', "$Port")
      $process = Start-Process -FilePath $node -ArgumentList $arguments `
        -RedirectStandardOutput $log -RedirectStandardError $logErr `
        -PassThru -WindowStyle Hidden
      Write-Note "server pid $($process.Id); log $log"
      $Url = Read-ServerUrl -LogPath $log
      if ($null -eq $Url) {
        throw "the server did not report a URL; see $log and $logErr"
      }
    }
  }

  Write-Step "Ready: $Url"

  if ($NoWindow) { return }

  $browserExe = Get-BrowserExe -Preference $Browser
  if ($null -eq $browserExe) {
    Write-Note 'no Edge or Chrome found; opening the default browser instead'
    Start-Process $Url | Out-Null
    return
  }

  # Size and place from the primary screen work area. A fixed size larger than
  # the display, or a position remembered from a larger display, opens the window
  # off-screen where a launch looks like nothing happened.
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
  $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $width = [Math]::Min(1360, [int]($area.Width * 0.94))
  $height = [Math]::Min(900, [int]($area.Height * 0.94))
  $left = [int]($area.X + ($area.Width - $width) / 2)
  $top = [int]($area.Y + ($area.Height - $height) / 2)
  Write-Note "application window via $(Split-Path -Leaf $browserExe): ${width}x${height} at ($left,$top)"
  $profileDir = Join-Path $AppDir 'browser-profile'
  Start-Process -FilePath $browserExe -ArgumentList @(
    "--app=$Url",
    "--window-size=$width,$height",
    "--window-position=$left,$top",
    '--no-first-run',
    "--user-data-dir=$profileDir"
  ) | Out-Null
  Confirm-WindowVisible -Area $area
}

try {
  Invoke-Launcher
} catch {
  Show-Failure $_.Exception.Message
  exit 1
}
