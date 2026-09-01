@echo off

:: serviceman.cmd - launcher for serviceman.ps1
:: Uses the built-in Windows PowerShell (5.1)

set "SCRIPT_DIR=%~dp0"

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%serviceman.ps1" %*
exit /b %ERRORLEVEL%
