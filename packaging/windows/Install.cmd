@echo off
rem Installs Claude Desktop Extra for the current user (no admin rights needed).
rem Examples:  Install.cmd    Install.cmd -Profile work    Install.cmd -Uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ClaudeExtra.ps1" %*
if errorlevel 1 pause
