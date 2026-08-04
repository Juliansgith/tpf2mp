@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tools\multiplayer_launcher.ps1" -BundleRoot "%~dp0"
if errorlevel 1 pause
