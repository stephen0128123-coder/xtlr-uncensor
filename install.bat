@echo off
chcp 65001 >nul
title 星塔旅人（国服）· 反和谐包 v2.0
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install.ps1"
echo.
echo 按任意键退出...
pause >nul
