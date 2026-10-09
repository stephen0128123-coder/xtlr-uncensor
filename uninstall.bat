@echo off
chcp 65001 >nul
title StellaSora CN - Restore Original
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\uninstall.ps1"
echo.
pause
