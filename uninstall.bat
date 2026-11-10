@echo off
chcp 65001 >nul
title StellaSora CN - Restore
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\uninstall.ps1" %*
set "result=%errorlevel%"
echo.
pause
exit /b %result%
