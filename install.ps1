#Requires -Version 5.1
<#
.SYNOPSIS
  One-line installer for the DeepSeek Harness application window.

.DESCRIPTION
  Downloads the dsh-window launcher into %LOCALAPPDATA%\dsh-shortcut, creates
  Start Menu and desktop shortcuts, and starts the Web UI in a dedicated
  browser application window. A missing or unsupported Node.js runtime is
  installed automatically for this machine's architecture; no administrator
  rights are needed.

.EXAMPLE
  irm https://raw.githubusercontent.com/dieWehmut/dsh-shortcut/main/install.ps1 | iex

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1 -Port 8080 -Browser chrome
#>
[CmdletBinding()]
param(
  [int]$Port = 3080,
  [string]$Browser = 'edge',
  [string]$AppDir = (Join-Path $env:LOCALAPPDATA 'dsh-shortcut'),
  [switch]$NoStart,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRaw = 'https://raw.githubusercontent.com/dieWehmut/dsh-shortcut/main'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Note { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }

if ($Uninstall) {
  $local = Join-Path $AppDir 'dsh-window.ps1'
  if (Test-Path -LiteralPath $local) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $local -Uninstall -AppDir $AppDir
  } else {
    Write-Host 'Nothing to uninstall: launcher not found.' -ForegroundColor Yellow
  }
  exit 0
}

Write-Step 'Installing the DeepSeek Harness launcher'

New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $AppDir 'assets') -Force | Out-Null

$files = @(
  @{ Url = "$repoRaw/dsh-window.ps1"; Path = (Join-Path $AppDir 'dsh-window.ps1') },
  @{ Url = "$repoRaw/assets/dsh.ico"; Path = (Join-Path $AppDir 'assets\dsh.ico') }
)

foreach ($file in $files) {
  Write-Note "download $(Split-Path -Leaf $file.Path)"
  Invoke-WebRequest -Uri $file.Url -OutFile $file.Path -UseBasicParsing
}

$launcher = Join-Path $AppDir 'dsh-window.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { throw 'The launcher download failed.' }

$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher, '-Port', "$Port", '-Browser', $Browser, '-AppDir', $AppDir)
if ($NoStart) { $arguments += '-NoWindow' }

Write-Step 'Launching'
& powershell.exe @arguments
