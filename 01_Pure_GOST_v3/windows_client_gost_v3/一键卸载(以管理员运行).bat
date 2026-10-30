@echo off
:: ==============================================================
:: TikTok 住宅机环境一键卸载清理脚本 (纯 GOST v3 版)
:: ==============================================================
chcp 65001 >nul
title TikTok 住宅机环境一键卸载清理 (纯 GOST v3)

:: 检查是否具备管理员权限
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo [提示] 正在请求系统管理员权限，请在弹出的系统提示中点击【是】...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall_gost_v3.ps1"

echo.
echo =======================================================
echo 请按任意键关闭此窗口...
pause >nul
