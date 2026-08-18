@echo off
setlocal
set "TPF2MP_ACTION="
if /I "%~n0"=="LAUNCH_TPF2MP" set "TPF2MP_ACTION=Launch"
if /I "%~n0"=="UPDATE_TPF2MP" set "TPF2MP_ACTION=Update"
if /I "%~n0"=="VERIFY_TPF2MP" set "TPF2MP_ACTION=Verify"
if /I "%~n0"=="UNINSTALL_TPF2MP" set "TPF2MP_ACTION=Uninstall"
if not defined TPF2MP_ACTION (
  echo Unknown TPF2MP installed command name: %~n0
  pause
  exit /b 2
)
if /I "%TPF2MP_ACTION%"=="Launch" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0installed_entrypoint.ps1" -Action Launch -InstallRoot "%~dp0."
  exit /b %ERRORLEVEL%
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installed_entrypoint.ps1" -Action "%TPF2MP_ACTION%" -InstallRoot "%~dp0."
set "TPF2MP_EXIT=%ERRORLEVEL%"
echo.
if not "%TPF2MP_EXIT%"=="0" echo TPF2MP %TPF2MP_ACTION% failed with exit code %TPF2MP_EXIT%.
if not defined TPF2MP_NO_PAUSE pause
exit /b %TPF2MP_EXIT%
