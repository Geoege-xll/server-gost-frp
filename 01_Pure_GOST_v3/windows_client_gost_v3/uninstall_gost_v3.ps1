# ==============================================================
# TikTok 住宅机环境一键卸载脚本 (纯 GOST v3 版)
# ==============================================================

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "正在请求管理员权限，请在弹窗中选择【是】..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

$ToolsDir = "C:\Tools"
$ServyCli = "$ToolsDir\servy-cli.exe"

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "🗑️  正在停止并清理 TikTok 住宅机 GOST 后台服务..." -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# 1. 注销系统服务
if (Test-Path $ServyCli) {
    & $ServyCli stop --quiet --name="TikTok_Gost" 2>$null
    & $ServyCli uninstall --quiet --name="TikTok_Gost" 2>$null
}

# 兜底清理 Windows sc 服务
try {
    & sc.exe stop TikTok_Gost 2>$null | Out-Null
    & sc.exe delete TikTok_Gost 2>$null | Out-Null
} catch {}

# 2. 终止 gost 进程
Get-Process -Name "gost", "servy", "Servy.Manager" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# 3. 移除桌面快捷方式
$DesktopPath = [Environment]::GetFolderPath('Desktop')
$ShortcutPath = "$DesktopPath\TikTok服务监控.lnk"
if (Test-Path $ShortcutPath) {
    Remove-Item -Path $ShortcutPath -Force -ErrorAction SilentlyContinue
    Write-Host "🧹 已移除桌面监控快捷方式。" -ForegroundColor Green
}

# 4. 询问是否删除 C:\Tools
Write-Host ""
$Confirm = Read-Host "❓ 是否同时彻底删除 C:\Tools 运行目录与证书配置？(y/N)"
if ($Confirm -eq 'y' -or $Confirm -eq 'Y') {
    try {
        Remove-Item -Path $ToolsDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✅ C:\Tools 目录已彻底删除。" -ForegroundColor Green
    } catch {
        Write-Host "⚠️ 部分文件被占用未能删除，请在重启后清理 C:\Tools。" -ForegroundColor Yellow
    }
} else {
    Write-Host "ℹ️  已保留 C:\Tools 配置文件目录。" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host "🎉 纯 GOST v3 客户端卸载与清理完成！" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
