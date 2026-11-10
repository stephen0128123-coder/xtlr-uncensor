@echo off
chcp 65001 >nul
title StellaSora CN - Install
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install.ps1" %*
set "result=%errorlevel%"
echo.
pause
exit /b %result%
