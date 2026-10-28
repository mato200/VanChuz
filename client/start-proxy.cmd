@echo off
REM ===========================================================================
REM  VanChuz proxy - START
REM  Shadowsocks-2022 over TCP/443 to your VanChuz server, exposed as a
REM  SOCKS5 / HTTP proxy on 127.0.0.1:1080.
REM
REM  Double-click this file to start the proxy.
REM  It stays running in the background when this window closes.
REM  Per-app only - nothing system-wide is modified.
REM ===========================================================================
title VanChuz Proxy - Start
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-proxy.ps1"
echo.
echo Press any key to close this window...
pause >nul
