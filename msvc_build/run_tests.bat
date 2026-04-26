@echo off
:: Wrapper to run the PowerShell test script from Command Prompt
:: Usage: run_tests.bat [platform] [config] [filter]
::   platform: x64 (default), Win32, ARM64
::   config:   MT (default), MTd, MD, MDd
::   filter:   optional test name substring

setlocal

set PLATFORM=%~1
set CONFIG=%~2
set FILTER=%~3

if "%PLATFORM%"=="" set PLATFORM=x64
if "%CONFIG%"=="" set CONFIG=MT

set PS_ARGS=-NoProfile -ExecutionPolicy Bypass -File "%~dp0run_tests.ps1"
set PS_ARGS=%PS_ARGS% -Platform %PLATFORM%
set PS_ARGS=%PS_ARGS% -Config %CONFIG%
if not "%FILTER%"=="" set PS_ARGS=%PS_ARGS% -Filter %FILTER%

powershell.exe %PS_ARGS%
exit /b %ERRORLEVEL%
