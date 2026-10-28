@echo off
REM Elevated launcher for vps-route.ps1 - triggers a UAC prompt.
REM Usage:  vps-route.cmd            (pin VPS to tether)
REM         vps-route.cmd -Remove    (unpin)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process PowerShell -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0vps-route.ps1','%*'"
