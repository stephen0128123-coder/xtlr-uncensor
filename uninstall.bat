@echo off
chcp 65001 >nul
title StellaSora CN - Restore
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\uninstall.ps1"
echo.
pause
