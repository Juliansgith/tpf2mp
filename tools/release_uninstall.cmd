@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\uninstall.ps1" %*
set "TPF2MP_EXIT=%ERRORLEVEL%"
echo.
if not "%TPF2MP_EXIT%"=="0" echo Uninstall failed with exit code %TPF2MP_EXIT%.
if not defined TPF2MP_NO_PAUSE pause
exit /b %TPF2MP_EXIT%
