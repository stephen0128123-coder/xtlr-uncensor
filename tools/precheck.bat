@echo off
chcp 65001 >nul
title StellaSora CN - Precheck
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0precheck.ps1"
echo.
pause
