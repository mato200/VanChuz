@echo off
REM ===========================================================================
REM  VanChuz proxy - STOP
REM  Stops the background sing-box process.
REM ===========================================================================
title VanChuz Proxy - Stop
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-proxy.ps1" -Stop
echo.
echo Press any key to close this window...
pause >nul
