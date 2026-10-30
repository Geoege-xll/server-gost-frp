@echo off
:: ==============================================================
:: TikTok 住宅机环境一键极速配置系统 (FRP + GOST 双进程版)
:: ==============================================================
chcp 65001 >nul
title TikTok 住宅机环境一键极速部署 (FRP + GOST)

:: 检查是否具备管理员权限
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo [提示] 正在请求系统管理员权限，请在弹出的系统提示中点击【是】...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

:: 切换到当前脚本所在目录
cd /d "%~dp0"

echo =======================================================
echo  正在启动 TikTok 住宅机部署引擎 (FRP + GOST 组合架构)...
echo =======================================================
echo.

:: 绕过 PowerShell 执行策略限制并执行核心部署脚本
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_frp_gost.ps1"

echo.
echo =======================================================
echo 请按任意键关闭此窗口...
pause >nul
