@echo off
setlocal DisableDelayedExpansion
set "AES_PANEL_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "AES_PANEL_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%AES_PANEL_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AppleEmojiSwitcher.Panel.ps1" %*
set "AES_PANEL_EXIT=%ERRORLEVEL%"
if "%~1"=="" (
    echo.
    if not "%AES_PANEL_EXIT%"=="0" echo Exit code: %AES_PANEL_EXIT%
    pause
)
endlocal & exit /b %AES_PANEL_EXIT%
