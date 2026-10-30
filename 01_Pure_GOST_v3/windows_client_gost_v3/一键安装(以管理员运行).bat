@echo off
setlocal
chcp 65001 >nul
title TikTok 住宅机离线部署 (纯 GOST v3)
rem PowerShell 在只读预检后请求管理员权限，并等待提升后的脚本结束。
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_gost_v3.ps1"
set "ExitCode=%ERRORLEVEL%"
echo.
echo 脚本退出码：%ExitCode% （0=完成，非0=失败，请查看上方信息）
echo 请按任意键关闭此窗口...
pause >nul
exit /b %ExitCode%
