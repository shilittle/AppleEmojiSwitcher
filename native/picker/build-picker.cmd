@echo off
setlocal DisableDelayedExpansion
set "AES_PICKER_ROOT=%~dp0"
for %%I in ("%AES_PICKER_ROOT%..\..") do set "AES_PICKER_REPO=%%~fI"
set "AES_PICKER_CSC=%SystemRoot%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%AES_PICKER_CSC%" set "AES_PICKER_CSC=%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%AES_PICKER_CSC%" (
  echo .NET Framework 4.x csc.exe was not found.>&2
  exit /b 1
)
if not exist "%AES_PICKER_REPO%\bin" mkdir "%AES_PICKER_REPO%\bin"
set "AES_PICKER_OUT=%AES_PICKER_REPO%\bin\PanelController.exe"
if /I "%~1"=="--lifecycle-stub" (
  set "AES_PICKER_OUT=%AES_PICKER_REPO%\bin\PanelController.LifecycleTest.exe"
  "%AES_PICKER_CSC%" /nologo /target:exe /platform:anycpu /langversion:5 /optimize+ /out:"%AES_PICKER_REPO%\bin\PanelController.LifecycleTest.exe" /win32manifest:"%AES_PICKER_ROOT%app.manifest" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll "%AES_PICKER_ROOT%Program.cs" "%AES_PICKER_ROOT%Lifecycle.cs" /define:AES_LIFECYCLE_STUB
) else (
  if not exist "%AES_PICKER_REPO%\picker\data" (
    echo Missing picker\data payload.>&2
    exit /b 1
  )
  xcopy "%AES_PICKER_REPO%\picker\data" "%AES_PICKER_REPO%\bin\picker-data\" /E /I /Y /Q >nul
  if errorlevel 2 (
    echo Could not prepare bin\picker-data.>&2
    exit /b 1
  )
  "%AES_PICKER_CSC%" /nologo /target:exe /platform:anycpu /langversion:5 /optimize+ /out:"%AES_PICKER_OUT%" /win32manifest:"%AES_PICKER_ROOT%app.manifest" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll "%AES_PICKER_ROOT%*.cs"
)
set "AES_PICKER_EXIT=%ERRORLEVEL%"
if not "%AES_PICKER_EXIT%"=="0" exit /b %AES_PICKER_EXIT%
echo Built %AES_PICKER_OUT%
exit /b 0
