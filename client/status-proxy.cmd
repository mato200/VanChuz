@echo off
REM ===========================================================================
REM  VanChuz proxy - STATUS
REM  Reports whether the proxy is running and which egress IP it uses.
REM ===========================================================================
title VanChuz Proxy - Status
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-proxy.ps1" -Status
echo.
echo Press any key to close this window...
pause >nul
