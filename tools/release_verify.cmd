@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\verify_install.ps1" -BundleRoot "%~dp0"
set "TPF2MP_EXIT=%ERRORLEVEL%"
echo.
if not "%TPF2MP_EXIT%"=="0" echo Verification failed with exit code %TPF2MP_EXIT%.
pause
exit /b %TPF2MP_EXIT%
