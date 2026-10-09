@echo off
chcp 65001 >nul
title 星塔旅人（国服）· 退回国服原版
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\uninstall.ps1"
echo.
echo 按任意键退出...
pause >nul
