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

  A missing or unsupported Node.js runtime is installed for this machine under
  the installation directory, using the official Windows archive that matches
  the operating system architecture. The download is verified against the
  published SHA256 sums and needs no administrator rights.

  The official Web build ships install metadata (manifest.webmanifest, display
  fullscreen), so the window can also be installed as a PWA from the browser's
  own menu. This script does not modify the dsh installation.

  Each launch compares the installed launcher and icon with the repository and
  replaces them when they differ, so a published fix reaches this machine
  without reinstalling. An unavailable network leaves the installed copy in
  place and the launch continues.

.PARAMETER Port
  Loopback port for the Web UI. Default 3080. When that port already serves a
  harness instance the script reuses it with the launch token recorded on this
  machine, so the window opens authenticated instead of landing on the 401
  page.

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

<#
.SYNOPSIS
  Interpret a node.exe version banner.
.DESCRIPTION
  The supported range matches what dsh boots on: 22.19 or newer in the 22 line,
  or 24 and newer. Anything unreadable is reported as unusable so the caller
  installs a known-good runtime instead of guessing.
.PARAMETER NodeExe
  Path to the node executable to interrogate.
#>
function Get-NodeRuntimeInfo {
  param([string]$NodeExe)
  if ([string]::IsNullOrWhiteSpace($NodeExe) -or -not (Test-Path -LiteralPath $NodeExe)) { return $null }
  try {
    $versionText = (& $NodeExe --version) -replace '^v', ''
  } catch {
    return $null
  }
  if ($versionText -notmatch '^(\d+)\.(\d+)\.(\d+)') { return $null }
  $major = [int]$Matches[1]
  $minor = [int]$Matches[2]
  return @{
    Version = $versionText
    Major = $major
    Minor = $minor
    Supported = (($major -eq 22 -and $minor -ge 19) -or ($major -ge 24))
  }
}

<#
.SYNOPSIS
  Node.exe previously installed under the application directory.
.DESCRIPTION
  A runtime this script installed lives directly under the installation
  directory, so it needs no PATH entry and survives a PATH that points at an
  unsupported Node.js. The newest supported copy wins when more than one
  remains from earlier launches.
.PARAMETER InstallDir
  Installation directory that may hold a managed node tree.
#>
function Get-ManagedNodeExe {
  param([string]$InstallDir)
  $root = Join-Path $InstallDir 'node'
  if (-not (Test-Path -LiteralPath $root)) { return $null }
  $supported = @()
  foreach ($exe in @(Get-ChildItem -LiteralPath $root -Filter 'node.exe' -Recurse -Depth 2 -File -ErrorAction SilentlyContinue)) {
    $info = Get-NodeRuntimeInfo -NodeExe $exe.FullName
    if ($null -ne $info -and $info.Supported) {
      $supported += @{ Path = $exe.FullName; Version = [version]$info.Version }
    }
  }
  if ($supported.Count -eq 0) { return $null }
  return ($supported | Sort-Object { $_.Version } -Descending | Select-Object -First 1).Path
}

<#
.SYNOPSIS
  Architecture name used in the official Node.js Windows archives.
.DESCRIPTION
  The runtime must match the operating system, not the calling process: a
  32-bit host process on 64-bit Windows still needs the 64-bit build. The
  environment variable is the fallback for hosts where the runtime API is
  unavailable.
#>
function Get-NodeArchitectureName {
  $architecture = $null
  try { $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { $architecture = $null }
  switch ($architecture) {
    'X64' { return 'x64' }
    'Arm64' { return 'arm64' }
    'X86' { return 'x86' }
  }
  switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { return 'x64' }
    'ARM64' { return 'arm64' }
    'x86' { return 'x86' }
  }
  if ([Environment]::Is64BitOperatingSystem) { return 'x64' }
  return 'x86'
}

<#
.SYNOPSIS
  Download a file without loading it into memory.
.DESCRIPTION
  Node.js archives are about 30 MB, which the small in-memory helper should not
  carry. The response streams to disk with a request timeout sized for a slow
  connection.
.PARAMETER Uri
  Absolute URL to download.
.PARAMETER Path
  Destination file path, overwritten when it exists.
.PARAMETER TimeoutSeconds
  Total time the transfer may take. Default 600.
#>
function Save-RemoteFile {
  param([string]$Uri, [string]$Path, [int]$TimeoutSeconds = 600)
  Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
  try {
    $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    try {
      if (-not $response.IsSuccessStatusCode) { throw "the download server answered $([int]$response.StatusCode)" }
      $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      try {
        $file = [IO.File]::Create($Path)
        try { $stream.CopyTo($file) } finally { $file.Dispose() }
      } finally {
        $stream.Dispose()
      }
    } finally {
      $response.Dispose()
    }
  } finally {
    $client.Dispose()
  }
}

<#
.SYNOPSIS
  Install a Node.js runtime matched to this machine.
.DESCRIPTION
  Downloads the official Windows archive for the operating system architecture
  from nodejs.org and falls back to the npmmirror binary mirror when the
  primary source is unreachable. Each archive is accepted only after its
  SHA256 matches the published sums file from the same source. The runtime is
  unpacked under the installation directory, so no administrator rights and no
  system PATH change are needed.
.PARAMETER InstallDir
  Installation directory that receives the node tree.
  Returns the installed node.exe path, or null when every source failed.
#>
function Install-NodeRuntime {
  param([string]$InstallDir)
  $arch = Get-NodeArchitectureName
  $lines = if ($arch -eq 'x86') { @('latest-v22.x') } else { @('latest-v24.x', 'latest-v22.x') }
  $sources = @(
    'https://nodejs.org/dist',
    'https://registry.npmmirror.com/-/binary/node'
  )
  foreach ($line in $lines) {
    foreach ($source in $sources) {
      $sumsUri = "$source/$line/SHASUMS256.txt"
      try {
        $sums = [Text.Encoding]::UTF8.GetString((Get-RemoteBytes -Uri $sumsUri))
      } catch {
        Write-Note "node download list unavailable ($source/$line): $($_.Exception.Message)"
        continue
      }
      $match = [regex]::Match($sums, "^([0-9a-fA-F]{64})\s+node-(v[0-9][0-9.]*)-win-$arch\.zip", 'Multiline')
      if (-not $match.Success) {
        Write-Note "no $arch archive is listed for $line on $source"
        continue
      }
      $expected = $match.Groups[1].Value.ToUpperInvariant()
      $version = $match.Groups[2].Value
      $zipName = "node-$version-win-$arch.zip"
      $zipPath = Join-Path $env:TEMP "dsh-$zipName"
      Write-Note "downloading $zipName from $source"
      try {
        Save-RemoteFile -Uri "$source/$line/$zipName" -Path $zipPath
      } catch {
        Write-Note "download failed: $($_.Exception.Message)"
        continue
      }
      $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
      if ($actual -ne $expected) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Write-Note "checksum mismatch for $zipName; discarding the download"
        continue
      }
      $root = Join-Path $InstallDir 'node'
      New-Item -ItemType Directory -Path $root -Force | Out-Null
      try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $root -Force
      } finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
      }
      $exe = Join-Path $root "node-$version-win-$arch\node.exe"
      if (Test-Path -LiteralPath $exe) { return $exe }
      $found = Get-ChildItem -LiteralPath $root -Filter 'node.exe' -Recurse -Depth 2 -File -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($null -ne $found) { return $found.FullName }
    }
  }
  return $null
}

<#
.SYNOPSIS
  Pick the node.exe this launch should use, installing one when needed.
.DESCRIPTION
  An installed Node.js in the supported range is used as-is. Otherwise the
  managed runtime is preferred, and when neither exists one is installed for
  this machine. Reports the version alongside the path so the caller can print
  what actually runs.
.PARAMETER InstallDir
  Installation directory that receives a managed runtime and holds earlier ones.
#>
function Resolve-SupportedNode {
  param([string]$InstallDir)
  foreach ($candidate in @(Get-NodeExe) + @(Get-ManagedNodeExe -InstallDir $InstallDir)) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $info = Get-NodeRuntimeInfo -NodeExe $candidate
    if ($null -ne $info -and $info.Supported) {
      return @{ Exe = $candidate; Version = $info.Version }
    }
  }
  Write-Step 'Installing Node.js for this machine (once; about 30 MB)'
  try {
    $installed = Install-NodeRuntime -InstallDir $InstallDir
  } catch {
    Write-Note "automatic Node.js install failed: $($_.Exception.Message)"
    return $null
  }
  if ([string]::IsNullOrWhiteSpace($installed)) { return $null }
  $info = Get-NodeRuntimeInfo -NodeExe $installed
  if ($null -eq $info -or -not $info.Supported) { return $null }
  return @{ Exe = $installed; Version = $info.Version }
}

function Get-NpmCmd {
  param([string]$NodeExe)
  if (-not [string]::IsNullOrWhiteSpace($NodeExe)) {
    $npm = Join-Path (Split-Path -Parent $NodeExe) 'npm.cmd'
    if (Test-Path -LiteralPath $npm) { return $npm }
  }
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

<#
.SYNOPSIS
  Process that listens on a loopback port.
.DESCRIPTION
  Reuse and restart decisions must name the process that owns the port. The
  cmdlet is unavailable on older Windows builds, so an unknown owner is
  reported as null and the caller keeps its conservative path.
.PARAMETER Candidate
  Loopback port to inspect.
#>
function Get-PortOwnerProcessId {
  param([int]$Candidate)
  try {
    $connection = Get-NetTCPConnection -LocalPort $Candidate -State Listen -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $connection) { return $null }
    return [int]$connection.OwningProcess
  } catch {
    return $null
  }
}

<#
.SYNOPSIS
  Check whether one URL authenticates against the harness it points at.
.DESCRIPTION
  dsh web answers 401 to every unauthenticated request, even one that carries a
  stale launch token, and answers a redirect when the token or the signed
  cookie is valid. Reading the status without following the redirect tells the
  two apart.
.PARAMETER Candidate
  URL to request, usually rebuilt from a recorded launch token.
#>
function Test-AuthenticatedUrl {
  param([string]$Candidate)
  try {
    $request = [System.Net.HttpWebRequest]::Create($Candidate)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $false
    $request.Timeout = 5000
    $request.Proxy = $null
    try {
      $response = $request.GetResponse()
      try { $status = [int]$response.StatusCode } finally { $response.Close() }
    } catch [System.Net.WebException] {
      if ($null -eq $_.Exception.Response) { return $false }
      $status = [int]$_.Exception.Response.StatusCode
    }
    return $status -ge 200 -and $status -lt 400
  } catch {
    return $false
  }
}

<#
.SYNOPSIS
  Recover an authenticated URL for a harness server that is already running.
.DESCRIPTION
  The launch token is minted per process and printed once, so it survives only
  in the files a previous launch wrote: server-<port>.url (with the matching
  server-<port>.pid proving the process still owns the port) and the server
  logs. Every candidate is verified against the running server before it is
  trusted, and a token that no longer authenticates falls through to the next
  record.
.PARAMETER Port
  Loopback port the running server listens on.
.PARAMETER InstallDir
  Installation directory that holds the recorded launch records.
#>
function Get-AuthenticatedServerUrl {
  param([int]$Port, [string]$InstallDir)
  $candidates = New-Object System.Collections.Generic.List[string]
  $owner = Get-PortOwnerProcessId -Candidate $Port
  $urlFile = Join-Path $InstallDir "server-$Port.url"
  $pidFile = Join-Path $InstallDir "server-$Port.pid"
  if ($null -ne $owner -and (Test-Path -LiteralPath $urlFile) -and (Test-Path -LiteralPath $pidFile)) {
    $recorded = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    $recordedPid = $null
    try { $recordedPid = [int]([string]$recorded).Trim() } catch { $recordedPid = $null }
    if ($null -ne $recordedPid -and $recordedPid -eq $owner) {
      $recordedUrl = (Get-Content -LiteralPath $urlFile -Raw -ErrorAction SilentlyContinue)
      if (-not [string]::IsNullOrWhiteSpace($recordedUrl)) { $candidates.Add($recordedUrl.Trim()) }
    }
  }
  foreach ($logPath in @((Join-Path $InstallDir "server-$Port.log"), (Join-Path $InstallDir 'server.log'))) {
    if (-not (Test-Path -LiteralPath $logPath)) { continue }
    $text = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $tokens = [regex]::Matches($text, "http://127\.0\.0\.1:$Port/\?token=([A-Za-z0-9_-]{16,})")
    for ($index = $tokens.Count - 1; $index -ge 0; $index--) {
      $candidates.Add("http://127.0.0.1:$Port/?token=$($tokens[$index].Groups[1].Value)")
    }
  }
  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (Test-AuthenticatedUrl -Candidate $candidate) { return $candidate }
  }
  return $null
}

<#
.SYNOPSIS
  Stop the harness server this installation started on a loopback port.
.DESCRIPTION
  When the recorded launch token no longer authenticates, the only way back to
  an authenticated window is a fresh server, because the token is minted per
  process. A process is treated as managed when its id matches the recorded
  server-pid record, or when it runs the dsh entry point from this installation;
  anything else is left alone and the caller reports instead.
.PARAMETER Port
  Loopback port the server listens on.
.PARAMETER InstallDir
  Installation directory that holds the recorded server pid and the dsh package.
#>
function Stop-ManagedPortOwner {
  param([int]$Port, [string]$InstallDir)
  $owner = Get-PortOwnerProcessId -Candidate $Port
  if ($null -eq $owner) { return $false }
  $pidFile = Join-Path $InstallDir "server-$Port.pid"
  $recorded = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  $recordedPid = $null
  try { $recordedPid = [int]([string]$recorded).Trim() } catch { $recordedPid = $null }
  if ($null -eq $recordedPid) {
    # A server started before the launcher recorded pids can still be identified
    # by its command line: it runs the dsh entry point from this installation.
    $entry = Join-Path $InstallDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$owner" -ErrorAction SilentlyContinue
    if ($null -eq $processInfo -or [string]::IsNullOrWhiteSpace($processInfo.CommandLine) -or -not $processInfo.CommandLine.Contains($entry)) {
      return $false
    }
  } elseif ($recordedPid -ne $owner) {
    return $false
  }
  try {
    $process = Get-Process -Id $owner -ErrorAction Stop
  } catch {
    return $false
  }
  Write-Note "stopping the previous server (pid $owner) to mint a fresh launch token"
  $closed = $false
  try { $closed = $process.CloseMainWindow() } catch { $closed = $false }
  if ($closed) { $process.WaitForExit(3000) | Out-Null }
  try {
    if (-not $process.HasExited) { Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue }
  } catch {
    Write-Note 'the previous server already exited'
  }
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline) {
    if (-not (Test-PortServing -Candidate $Port)) { break }
    Start-Sleep -Milliseconds 250
  }
  return -not (Test-PortServing -Candidate $Port)
}

function Invoke-DshInstall {
  param([string]$InstallDir, [string]$NodeExe)
  $npm = Get-NpmCmd -NodeExe $NodeExe
  if ($null -eq $npm) {
    throw 'npm was not found next to the selected Node.js runtime.'
  }
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  $manifest = Join-Path $InstallDir 'package.json'
  if (-not (Test-Path -LiteralPath $manifest)) {
    [IO.File]::WriteAllText($manifest, "{`n  `"name`": `"dsh-shortcut`",`n  `"private`": true`n}`n", [Text.UTF8Encoding]::new($false))
  }
  Write-Step "Installing $DshPackage (first run; 1-3 minutes)"
  Push-Location $InstallDir
  try {
    # npm.cmd runs its own node.exe from PATH; put the selected runtime first so
    # the managed install works on a machine whose PATH has no usable node.
    $env:PATH = "$(Split-Path -Parent $NodeExe);$env:PATH"
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

  $runtime = Resolve-SupportedNode -InstallDir $AppDir
  if ($null -eq $runtime) {
    throw 'No supported Node.js runtime is available and the automatic install failed. Install Node.js 22.19+ or 24+ from https://nodejs.org/ and run this script again.'
  }
  $node = $runtime.Exe
  Write-Note "node $($runtime.Version) ($node)"

  $bin = Get-DshBin -InstallDir $AppDir
  if ($null -eq $bin) {
    Invoke-DshInstall -InstallDir $AppDir -NodeExe $node
    $bin = Get-DshBin -InstallDir $AppDir
  }
  if ($null -eq $bin) { throw 'The dsh package did not install correctly.' }

  $iconPath = Join-Path (Split-Path -Parent $scriptPath) 'assets\dsh.ico'
  New-Shortcuts -ScriptPath $scriptPath -IconPath $iconPath

  if ([string]::IsNullOrWhiteSpace($Url)) {
    if (Test-PortServing -Candidate $Port) {
      Write-Step "Port $Port already serves a harness instance; reusing it"
      $Url = Get-AuthenticatedServerUrl -Port $Port -InstallDir $AppDir
      if ($null -eq $Url) {
        if (-not (Stop-ManagedPortOwner -Port $Port -InstallDir $AppDir)) {
          throw "Port $Port is serving but its launch token could not be recovered. Close that process, choose another -Port, or open its own dsh web URL."
        }
      } else {
        Write-Note 'reused the launch token recorded on this machine'
      }
    }
    if ([string]::IsNullOrWhiteSpace($Url)) {
      $log = Join-Path $AppDir "server-$Port.log"
      $logErr = Join-Path $AppDir "server-$Port.err.log"
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
      Set-Content -LiteralPath (Join-Path $AppDir "server-$Port.url") -Value $Url -Encoding ASCII -NoNewline
      Set-Content -LiteralPath (Join-Path $AppDir "server-$Port.pid") -Value "$($process.Id)" -Encoding ASCII -NoNewline
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
