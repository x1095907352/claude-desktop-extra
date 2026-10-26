<#
.SYNOPSIS
  Installs Claude Desktop Extra (the patched portable Windows build) for the
  current user, and manages its profile shortcuts.

.DESCRIPTION
  Copies the app\ folder next to this script to the install folder and adds
  Start Menu shortcuts. No administrator rights are needed and nothing outside
  the current user's profile is changed.

  Run it from the unzipped folder:
    .\Install.cmd                       install or update
    .\Install.cmd -Profile work         add a "Claude (work)" shortcut
    .\Install.cmd -RemoveProfile work   remove that shortcut (its data stays)
    .\Install.cmd -Desktop              also put the shortcut on the desktop
    .\Install.cmd -Uninstall            remove the app and its shortcuts

  Each profile is a separate Claude with its own sign-in, settings and Claude
  Code configuration (%APPDATA%\Claude-<name>, %USERPROFILE%\.claude-<name>).
  The default profile uses the same folders as the official Claude app.

.LINK
  https://github.com/patrickjaja/claude-desktop-extra/blob/master/docs/windows.md
#>
[CmdletBinding()]
param(
  # Not $Profile: that name is PowerShell's own automatic variable.
  [Alias('Profile')][string]$ProfileName,
  [string]$RemoveProfile,
  [switch]$Desktop,
  [switch]$Uninstall,
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\Claude Desktop Extra')
)

$ErrorActionPreference = 'Stop'
$AppName = 'Claude Desktop Extra'
$StartMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) $AppName
$DesktopDir = [Environment]::GetFolderPath('Desktop')
$Exe = Join-Path $InstallDir 'app\claude.exe'
$NameRe = '^[A-Za-z0-9_-]{1,64}$'

function Test-ProfileName([string]$Name) {
  if ($Name -notmatch $NameRe -or $Name -eq 'default') {
    throw "Invalid profile name '$Name': use letters, digits, '-' and '_' ('default' is reserved)."
  }
}

function New-Shortcut([string]$Path, [string]$Arguments, [string]$Description) {
  $shell = New-Object -ComObject WScript.Shell
  $lnk = $shell.CreateShortcut($Path)
  $lnk.TargetPath = $Exe
  $lnk.Arguments = $Arguments
  $lnk.WorkingDirectory = Split-Path $Exe
  $lnk.IconLocation = "$Exe,0"
  $lnk.Description = $Description
  $lnk.Save()
}

function Get-ShortcutNames([string]$ProfileName) {
  if ($ProfileName) { "Claude ($ProfileName).lnk" } else { 'Claude (Extra).lnk' }
}

function Add-Shortcuts([string]$ProfileName) {
  New-Item -ItemType Directory -Force -Path $StartMenuDir | Out-Null
  $name = Get-ShortcutNames $ProfileName
  $arguments = if ($ProfileName) { "--profile=$ProfileName" } else { '' }
  $desc = if ($ProfileName) { "Claude, profile $ProfileName" } else { 'Claude (claude-desktop-extra build)' }
  New-Shortcut (Join-Path $StartMenuDir $name) $arguments $desc
  if ($Desktop) { New-Shortcut (Join-Path $DesktopDir $name) $arguments $desc }
  Write-Host "  Shortcut: Start Menu > $AppName > $($name -replace '\.lnk$','')"
}

function Stop-IfRunning {
  $running = Get-Process -Name claude -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path -ieq $Exe }
  if ($running) {
    throw "Claude Desktop Extra is running from $InstallDir. Quit it (tray icon > Quit) and run this again."
  }
}

if ($Uninstall) {
  Stop-IfRunning
  if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
  if (Test-Path $StartMenuDir) { Remove-Item -Recurse -Force $StartMenuDir }
  Get-ChildItem -Path $DesktopDir -Filter 'Claude (*).lnk' -ErrorAction SilentlyContinue | ForEach-Object {
    $t = (New-Object -ComObject WScript.Shell).CreateShortcut($_.FullName).TargetPath
    if ($t -ieq $Exe) { Remove-Item -Force $_.FullName }
  }
  Write-Host "$AppName removed. Your data (%APPDATA%\Claude*, %USERPROFILE%\.claude*) was left in place."
  return
}

if ($RemoveProfile) {
  Test-ProfileName $RemoveProfile
  $name = Get-ShortcutNames $RemoveProfile
  foreach ($dir in @($StartMenuDir, $DesktopDir)) {
    $p = Join-Path $dir $name
    if (Test-Path $p) { Remove-Item -Force $p }
  }
  Write-Host "Removed the shortcut for profile '$RemoveProfile'."
  Write-Host "Its data is kept: $env:APPDATA\Claude-$RemoveProfile and $env:USERPROFILE\.claude-$RemoveProfile"
  return
}

if ($ProfileName) { Test-ProfileName $ProfileName }

# Install or update the app when this script sits next to an app\ folder.
$Source = Join-Path $PSScriptRoot 'app'
if (Test-Path (Join-Path $Source 'claude.exe')) {
  Stop-IfRunning
  Write-Host "Installing $AppName to $InstallDir"
  # A zip downloaded from the internet marks every file; clear the mark so
  # Windows does not ask about each DLL.
  Get-ChildItem -Recurse -File $PSScriptRoot | Unblock-File
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $dest = Join-Path $InstallDir 'app'
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  Copy-Item -Recurse -Force $Source $dest
  foreach ($f in @('VERSION.txt', 'README-Windows.txt', 'Install-ClaudeExtra.ps1', 'Install.cmd')) {
    $p = Join-Path $PSScriptRoot $f
    if (Test-Path $p) { Copy-Item -Force $p $InstallDir }
  }
  Add-Shortcuts ''
} elseif (-not (Test-Path $Exe)) {
  throw "No app\ folder next to this script and nothing installed in $InstallDir. Run this from the unzipped download."
}

if ($ProfileName) { Add-Shortcuts $ProfileName }

Write-Host ''
Write-Host 'Done. Start Claude from the Start Menu.'
Write-Host 'Custom models: Settings > Extra > Models. More: README-Windows.txt'
