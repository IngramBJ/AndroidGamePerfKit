@echo off
chcp 65001 >nul
title AndroidGamePerfKit
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AndroidGamePerfKit-Launcher.ps1"
if errorlevel 1 (
  echo.
  echo Launcher exited with an error. See the message above.
  pause
)

