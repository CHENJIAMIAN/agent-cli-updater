@echo off
setlocal
cd /d "%~dp0"
title Agent CLI Auto Update
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-agent-clis.ps1"
echo.
echo Press any key to close...
pause >nul
endlocal
