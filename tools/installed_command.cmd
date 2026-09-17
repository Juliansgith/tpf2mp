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
rem A tpf2mp:// invite link arrives as the first argument, so the same stable
rem command also opens an invite. The link is passed through once, quoted.
set "TPF2MP_URL=%~1"
set "TPF2MP_SCHEME="
if defined TPF2MP_URL set "TPF2MP_SCHEME=%TPF2MP_URL:~0,9%"
if /I "%TPF2MP_SCHEME%"=="tpf2mp://" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0installed_entrypoint.ps1" -Action Join -InstallRoot "%~dp0." -Url "%TPF2MP_URL%"
  exit /b %ERRORLEVEL%
)
if /I "%TPF2MP_ACTION%"=="Launch" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0installed_entrypoint.ps1" -Action Launch -InstallRoot "%~dp0." %*
  exit /b %ERRORLEVEL%
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installed_entrypoint.ps1" -Action "%TPF2MP_ACTION%" -InstallRoot "%~dp0." %*
set "TPF2MP_EXIT=%ERRORLEVEL%"
echo.
if not "%TPF2MP_EXIT%"=="0" echo TPF2MP %TPF2MP_ACTION% failed with exit code %TPF2MP_EXIT%.
if not defined TPF2MP_NO_PAUSE pause
exit /b %TPF2MP_EXIT%
