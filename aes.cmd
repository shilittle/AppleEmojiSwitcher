@echo off
setlocal DisableDelayedExpansion
set "AES_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "AES_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%AES_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AppleEmojiSwitcher.Cli.ps1" %*
set "AES_EXIT=%ERRORLEVEL%"
if "%~1"=="" (
    echo.
    if not "%AES_EXIT%"=="0" echo Exit code: %AES_EXIT%
    pause
)
endlocal & exit /b %AES_EXIT%
