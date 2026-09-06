@echo off
setlocal
pushd "%~dp0" || exit /b 1
set "VS_ROOT="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS_ROOT=%%I"
set "VS_ENV=%VS_ROOT%\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VS_ENV%" (
  echo MSVC vcvars64.bat was not found: %VS_ENV%
  exit /b 1
)
call "%VS_ENV%" >nul || exit /b 1
set "OBJ_DIR=.build"
if not exist "%OBJ_DIR%" mkdir "%OBJ_DIR%" || exit /b 1
cl /nologo /std:c++17 /EHsc /O2 /MT /W4 /utf-8 /DUNICODE /D_UNICODE /Fo"%OBJ_DIR%\EmojiRender.obj" EmojiRender.cpp /link /OUT:..\bin\EmojiRender.exe dwrite.lib d2d1.lib d3d11.lib dxgi.lib windowscodecs.lib ole32.lib
exit /b %ERRORLEVEL%
