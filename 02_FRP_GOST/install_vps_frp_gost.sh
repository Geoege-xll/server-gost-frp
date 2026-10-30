#!/bin/bash
# ==============================================================================
# 🚀 TikTok 日本/跨境电商双入站物理隔离方案 - VPS 服务端极速部署与全打包脚本
# 版本：V2.5 (Zero-Touch Auto Deploy & 纯离线客户端打包版)
# 适用系统：Ubuntu 20.04/22.04/24.04, Debian 11/12, CentOS 7/8/9, AlmaLinux, RockyLinux
# ==============================================================================

set -e

# 必须以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[31m❌ 错误：请使用 root 权限运行此脚本！(例如 sudo bash $0)\033[0m"
    exit 1
fi

H_S="https"
H_T="http"

# ------------------------------------------------------------------------------
# 快捷升级指令支持 (bash install_vps_frp_gost.sh --upgrade / -u)
# ------------------------------------------------------------------------------
if [ "$1" == "--upgrade" ] || [ "$1" == "-u" ] || [ "$1" == "upgrade" ]; then
    echo "======================================================================"
    echo -e "\033[36m🚀 正在通过命令一键平滑升级 FRP 服务端核心...\033[0m"
    echo "======================================================================"
    LATEST_FRP_TAG=$(curl -s "${H_S}://api.github.com/repos/fatedier/frp/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
    if [ -z "$LATEST_FRP_TAG" ]; then LATEST_FRP_TAG="v0.71.1"; fi
    FRP_VERSION_NUM=${LATEST_FRP_TAG#v}

    CURRENT_VER=$(/root/frp/frps -v 2>/dev/null || echo "未安装")
    echo -e "   -> 当前版本: \033[33m${CURRENT_VER}\033[0m"
    echo -e "   -> 目标最新版本: \033[32m${LATEST_FRP_TAG}\033[0m"

    echo "   -> 正在下载最新 Linux 版 frps 二进制..."
    TMP_DIR=$(mktemp -d)
    wget -qO "$TMP_DIR/frp_linux.tar.gz" "${H_S}://github.com/fatedier/frp/releases/download/${LATEST_FRP_TAG}/frp_${FRP_VERSION_NUM}_linux_amd64.tar.gz"
    tar -xzf "$TMP_DIR/frp_linux.tar.gz" -C "$TMP_DIR"
    cp "$TMP_DIR/frp_${FRP_VERSION_NUM}_linux_amd64/frps" /root/frp/frps
    chmod +x /root/frp/frps
    rm -rf "$TMP_DIR"

    if systemctl is-active --quiet frps 2>/dev/null; then
        echo "   -> 正在平滑重启 frps 守护服务..."
        systemctl restart frps
        sleep 1
        if systemctl is-active --quiet frps 2>/dev/null; then
            echo -e "\033[32m✅ FRP 服务端升级成功并已恢复运行！现有证书与配置文件完全保留无损！\033[0m"
        else
            echo -e "\033[31m⚠️ 服务启动异常，请检查 systemctl status frps 日志。\033[0m"
        fi
    else
        echo -e "\033[32m✅ frps 二进制已平滑更新至 ${LATEST_FRP_TAG}！\033[0m"
    fi
    exit 0
fi

echo "======================================================================"
echo -e "\033[36m🚀 开始执行 FRP 服务端全自动部署与离线客户端打包引擎 (V2.5)\033[0m"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. 安装系统依赖包
# ------------------------------------------------------------------------------
echo -e "\n\033[33m📦 [1/7] 正在检查并安装系统运行依赖...\033[0m"
if [ -f /etc/debian_version ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -yqq
    apt-get install -yqq curl wget tar unzip zip openssl p7zip-full ca-certificates
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget tar unzip zip openssl epel-release || true
    yum install -y p7zip p7zip-plugins || true
fi

# ------------------------------------------------------------------------------
# 2. 优化系统网络内核 (禁用 IPv6 防止 Reality 握手超时)
# ------------------------------------------------------------------------------
echo -e "\n\033[33m🔧 [2/7] 正在优化系统网络内核 (配置 IPv6 兼容)...\033[0m"
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
if ! grep -q "net.ipv6.conf.all.disable_ipv6 = 1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 3. 获取公网 IPv4 地址
# ------------------------------------------------------------------------------
echo -e "\n\033[33m🌐 [3/7] 正在自动探测 VPS 公网 IPv4 地址...\033[0m"
PUBLIC_IP=$(curl -s --connect-timeout 4 -4 "${H_T}://ip-api.com/json" | grep -oE '"query":"[^"]+"' | cut -d'"' -f4 || true)
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(curl -s --connect-timeout 4 -4 "${H_T}://ifconfig.me" || true)
fi
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(curl -s --connect-timeout 4 -4 "${H_T}://icanhazip.com" | tr -d '\n' || true)
fi

if [ -z "$PUBLIC_IP" ]; then
    read -p "⚠️ 无法自动获取公网 IPv4，请输入此 VPS 的外网 IP: " PUBLIC_IP </dev/tty
fi
echo -e "   -> 当前 VPS 公网 IP: \033[32m$PUBLIC_IP\033[0m"

# ------------------------------------------------------------------------------
# 4. 下载并安装 Linux 端 FRP 服务端 (frps)
# ------------------------------------------------------------------------------
echo -e "\n\033[33m🔍 [4/7] 正在请求 GitHub 官方源获取 FRP 最新组件...\033[0m"
LATEST_FRP_TAG=$(curl -s "${H_S}://api.github.com/repos/fatedier/frp/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
if [ -z "$LATEST_FRP_TAG" ]; then
    LATEST_FRP_TAG="v0.71.1"
    echo -e "   \033[33m[!] GitHub API 访问受限，降级使用最新稳定版本: $LATEST_FRP_TAG\033[0m"
fi
FRP_VERSION_NUM=${LATEST_FRP_TAG#v}

mkdir -p /root/frp && cd /root/frp

NEED_INSTALL_FRPS=true
if [ -f "/root/frp/frps" ]; then
    CURRENT_VERSION=$(/root/frp/frps -v 2>/dev/null || echo "未知")
    if [ "$CURRENT_VERSION" == "$FRP_VERSION_NUM" ]; then
        echo -e "   \033[32m✅ 当前已安装最新版本 frps (v$FRP_VERSION_NUM)，跳过重新下载。\033[0m"
        NEED_INSTALL_FRPS=false
    fi
fi

if [ "$NEED_INSTALL_FRPS" = true ]; then
    echo -e "   -> 正在下载 FRP 服务端 v$FRP_VERSION_NUM..."
    wget -qO frp_linux.tar.gz "${H_S}://github.com/fatedier/frp/releases/download/${LATEST_FRP_TAG}/frp_${FRP_VERSION_NUM}_linux_amd64.tar.gz"
    tar -xzf frp_linux.tar.gz
    mv frp_${FRP_VERSION_NUM}_linux_amd64/frps ./
    rm -rf frp_linux.tar.gz frp_${FRP_VERSION_NUM}_linux_amd64
    chmod +x /root/frp/frps
    echo -e "   \033[32m✅ frps 服务端安装就绪。\033[0m"
fi

# ------------------------------------------------------------------------------
# 5. 签发 mTLS 双向高强度认证证书
# ------------------------------------------------------------------------------
echo -e "\n\033[33m🔐 [5/7] 正在签发 mTLS 双向加密证书 (CA / Server / Client)...\033[0m"
cat > my-openssl.cnf << CONF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir = .
certs = .
new_certs_dir = .
database = index.txt
serial = serial
default_days = 3650
default_md = sha256
policy = policy_anything
x509_extensions = usr_cert
[ policy_anything ]
commonName = supplied
[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
string_mask = utf8only
prompt = no
[ req_distinguished_name ]
CN = FRP-CA
[ v3_ca ]
basicConstraints = critical,CA:true
[ usr_cert ]
basicConstraints = CA:FALSE
[ server_ext ]
basicConstraints = CA:FALSE
subjectAltName = @alt_names
[ alt_names ]
IP.1 = 127.0.0.1
IP.2 = $PUBLIC_IP
CONF

rm -f index.txt serial *.crt *.key *.csr
touch index.txt && echo 1000 > serial
openssl genrsa -out ca.key 2048 2>/dev/null
openssl req -new -x509 -key ca.key -out ca.crt -days 3650 -config my-openssl.cnf 2>/dev/null
openssl genrsa -out server.key 2048 2>/dev/null
openssl req -new -key server.key -out server.csr -subj "/CN=frp-server" -config my-openssl.cnf 2>/dev/null
openssl ca -batch -in server.csr -out server.crt -cert ca.crt -keyfile ca.key -extensions server_ext -config my-openssl.cnf 2>/dev/null
openssl genrsa -out client.key 2048 2>/dev/null
openssl req -new -key client.key -out client.csr -subj "/CN=frp-client" -config my-openssl.cnf 2>/dev/null
openssl ca -batch -in client.csr -out client.crt -cert ca.crt -keyfile ca.key -extensions usr_cert -config my-openssl.cnf 2>/dev/null
rm -f *.csr index.txt* serial* my-openssl.cnf *.old
echo -e "   \033[32m✅ mTLS 双向认证证书签发完毕 (有效期 10 年)。\033[0m"

# ------------------------------------------------------------------------------
# 6. 生成服务配置并启动后台隧道守护进程
# ------------------------------------------------------------------------------
echo -e "\n\033[33m⚙️  [6/7] 正在生成专属服务端配置并拉起隧道守护服务...\033[0m"
RANDOM_TOKEN=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
GOST_USER="user$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 5)"
GOST_PASS=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

cat > /root/frp/frps.toml << TOML
bindPort = 9000
auth.method = "token"
auth.token = "${RANDOM_TOKEN}"
transport.maxPoolCount = 50
transport.heartbeatTimeout = 90
transport.tcpMux = true
transport.wireProtocol = "v2"
transport.tls.force = true
transport.tls.certFile = "/root/frp/server.crt"
transport.tls.keyFile = "/root/frp/server.key"
transport.tls.trustedCaFile = "/root/frp/ca.crt"
webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "${RANDOM_TOKEN}"
TOML

cat > /etc/systemd/system/frps.service << SVC
[Unit]
Description=Frp Server Service
After=network.target
[Service]
Type=simple
User=root
ExecStart=/root/frp/frps -c /root/frp/frps.toml
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable frps >/dev/null 2>&1
systemctl restart frps
echo -e "   \033[32m✅ frps 服务已成功启动并在后台守护运行！\033[0m"

# ------------------------------------------------------------------------------
# 7. 构建“真·离线傻瓜版” Windows 客户端部署包
# ------------------------------------------------------------------------------
echo -e "\n\033[33m📦 [7/7] 正在预下载 Windows 组件并构建一体化离线极速安装包...\033[0m"

PKG_DIR="/root/frp/win_pkg"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"
cd "$PKG_DIR"

# A. 拷入证书
cp ../ca.crt ../client.crt ../client.key ./

# B. 预下载 Windows 版 frpc.exe
echo "   -> 正在下载 Windows 版 FRP (frpc.exe)..."
wget -qO frp_win.zip "${H_S}://github.com/fatedier/frp/releases/download/${LATEST_FRP_TAG}/frp_${FRP_VERSION_NUM}_windows_amd64.zip" || true
if [ -f frp_win.zip ]; then
    unzip -q frp_win.zip
    find . -type f -name "frpc.exe" -exec mv {} ./ \;
    rm -rf frp_win.zip frp_${FRP_VERSION_NUM}_windows_amd64
fi

# C. 预下载 Windows 版 gost.exe
echo "   -> 正在下载 Windows 版 Gost 代理核心 (gost.exe)..."
LATEST_GOST_TAG=$(curl -s "${H_S}://api.github.com/repos/go-gost/gost/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
if [ -z "$LATEST_GOST_TAG" ]; then LATEST_GOST_TAG="v3.3.2"; fi
GOST_VER_NUM=${LATEST_GOST_TAG#v}

wget -qO gost_win.zip "${H_S}://github.com/go-gost/gost/releases/download/${LATEST_GOST_TAG}/gost_${GOST_VER_NUM}_windows_amd64.zip" || true
if [ -f gost_win.zip ]; then
    unzip -q gost_win.zip
    find . -type f -name "gost*.exe" -exec mv {} ./gost.exe \;
    rm -rf gost_win.zip
fi

# D. 预下载 Windows 版 Servy 服务管理组件
echo "   -> 正在下载 Windows 版 Servy 服务守护组件..."
LATEST_SERVY_TAG=$(curl -s "${H_S}://api.github.com/repos/aelassas/servy/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
if [ -z "$LATEST_SERVY_TAG" ]; then LATEST_SERVY_TAG="v10.7"; fi
SERVY_VER_NUM=${LATEST_SERVY_TAG#v}

wget -qO servy.7z "${H_S}://github.com/aelassas/servy/releases/download/${LATEST_SERVY_TAG}/servy-${SERVY_VER_NUM}-net48-x64-portable.7z" || true
if [ -f servy.7z ]; then
    mkdir -p servy_tmp
    if command -v 7z &>/dev/null; then
        7z x -y -oservy_tmp servy.7z >/dev/null 2>&1 || true
    elif command -v 7za &>/dev/null; then
        7za x -y -oservy_tmp servy.7z >/dev/null 2>&1 || true
    fi
    find servy_tmp -type f \( -name "*.exe" -o -name "*.dll" \) -exec cp {} ./ \; 2>/dev/null || true
    rm -rf servy.7z servy_tmp
fi

# E. 写入引导批处理文件: 一键安装(以管理员运行).bat
cat > "一键安装(以管理员运行).bat" << 'BATEOF'
@echo off
chcp 65001 >nul
title TikTok 住宅机环境一键极速部署 (FRP + GOST)

:: 检查是否具备管理员权限
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo [提示] 正在请求系统管理员权限，请在弹出的系统提示中点击【是】...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
echo =======================================================
echo  正在启动 TikTok 住宅机部署引擎 (FRP + GOST 组合架构)...
echo =======================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_frp_gost.ps1"

echo.
echo =======================================================
echo 请按任意键关闭此窗口...
pause >nul
BATEOF

# F. 写入卸载批处理文件: 一键卸载(以管理员运行).bat
cat > "一键卸载(以管理员运行).bat" << 'BATEOF'
@echo off
chcp 65001 >nul
title TikTok 住宅机环境一键卸载清理 (FRP + GOST)

:: 检查是否具备管理员权限
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo [提示] 正在请求系统管理员权限，请在弹出的系统提示中点击【是】...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall_frp_gost.ps1"

echo.
echo =======================================================
echo 请按任意键关闭此窗口...
pause >nul
BATEOF

# G. 写入 uninstall_frp_gost.ps1
cat > "uninstall_frp_gost.ps1" << 'PS1EOF'
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "正在请求管理员权限，请在弹窗中选择【是】..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

$ToolsDir = "C:\Tools"
$ServyCli = "$ToolsDir\servy-cli.exe"

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "🗑️  正在停止并清理 TikTok 住宅机后台服务..." -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

if (Test-Path $ServyCli) {
    & $ServyCli stop --quiet --name="TikTok_Gost" 2>$null
    & $ServyCli stop --quiet --name="TikTok_FRP" 2>$null
    & $ServyCli uninstall --quiet --name="TikTok_Gost" 2>$null
    & $ServyCli uninstall --quiet --name="TikTok_FRP" 2>$null
}

try {
    & sc.exe stop TikTok_Gost 2>$null | Out-Null
    & sc.exe delete TikTok_Gost 2>$null | Out-Null
    & sc.exe stop TikTok_FRP 2>$null | Out-Null
    & sc.exe delete TikTok_FRP 2>$null | Out-Null
} catch {}

Get-Process -Name "frpc", "gost", "servy", "Servy.Manager" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$DesktopPath = [Environment]::GetFolderPath('Desktop')
$ShortcutPath = "$DesktopPath\TikTok服务监控.lnk"
if (Test-Path $ShortcutPath) {
    Remove-Item -Path $ShortcutPath -Force -ErrorAction SilentlyContinue
}

Write-Host ""
$Confirm = Read-Host "❓ 是否同时彻底删除 C:\Tools 运行目录与证书配置？(y/N)"
if ($Confirm -eq 'y' -or $Confirm -eq 'Y') {
    try {
        Remove-Item -Path $ToolsDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✅ C:\Tools 目录已彻底删除。" -ForegroundColor Green
    } catch {}
}

Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host "🎉 卸载与清理工作已完成！" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
PS1EOF

# H. 写入使用说明
cat > "README_住宅机安装说明.txt" << 'TXTEOF'
====================================================================
🚀 TikTok 住宅机环境一键傻瓜式部署说明 (FRP + GOST 双进程版)
====================================================================

【使用方法 - 仅需 2 步】

第 1 步：
将收到的压缩包 (windows_frp_gost_pkg.zip) 解压到电脑的任意位置（例如桌面）。

第 2 步：
进入解压后的文件夹，找到：
【一键安装(以管理员运行).bat】
鼠标右键点击它，选择【以管理员身份运行】（或直接双击，在弹出的系统提示中点击【是】）。

====================================================================
【安装过程中你不需要做任何操作】
脚本会自动为你完成以下事项：
1. 自动添加 Windows Defender 信任目录 (C:\Tools)，防止被杀软误杀。
2. 自动设置系统电源策略：接通电源下永不休眠、永不断网。
3. 自动安装 mTLS 双向安全通信证书。
4. 自动配置后台系统服务，并设置为随开机自动启动、崩溃自动重连。
5. 自动在电脑桌面创建【TikTok服务监控】快捷方式，方便随时查看运行状态。

====================================================================
【日常管理与常见问题】

1. 日常需要手动打开软件吗？
   不需要！服务已经作为 Windows 系统底层服务运行，重启电脑也会自动启动。

2. 如何查看服务是否正常运行？
   双击桌面的【TikTok服务监控】图标，可以看到 TikTok_Gost 和 TikTok_FRP 两个服务。
   只要显示绿色的 "Running"，就代表网络隧道完全通畅。

3. 如果想要卸载怎么做？
   打开本目录下的【一键卸载(以管理员运行).bat】，右键以管理员身份运行即可一键清理干净。
====================================================================
TXTEOF

# I. 写入 setup_frp_gost.ps1 并注入动态凭据
cat > "setup_frp_gost.ps1" << 'PS1EOF'
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "正在请求管理员权限，请在弹窗中选择【是】..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

$CurrentDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrWhiteSpace($CurrentDir)) { $CurrentDir = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($CurrentDir)) { $CurrentDir = (Get-Location).Path }

$ToolsDir = "C:\Tools"
$CertsDir = "$ToolsDir\certs"
$LogsDir  = "$ToolsDir\logs"
$P_HS     = "https"

$VpsServerIp = "VPS_PUBLIC_IP_PLACEHOLDER"
$AuthToken   = "TOKEN_PLACEHOLDER"
$GostUser    = "GOST_USER_PLACEHOLDER"
$GostPass    = "GOST_PASS_PLACEHOLDER"

Clear-Host
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "🚀 Windows 住宅机端 - 极速部署系统 (V2.5 傻瓜版)" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "📁 [1/6] 正在初始化运行环境并添加防病毒白名单..." -ForegroundColor Yellow
New-Item -Path $ToolsDir, $CertsDir, $LogsDir -ItemType Directory -Force | Out-Null
try {
    Add-MpPreference -ExclusionPath $ToolsDir -ErrorAction SilentlyContinue
    Write-Host "   -> 安全防护白名单已应用: $ToolsDir" -ForegroundColor Green
} catch {}

Write-Host "⚡ [2/6] 正在优化系统电源策略 (防止待机/休眠掉线)..." -ForegroundColor Yellow
try {
    & powercfg /change standby-timeout-ac 0 2>$null
    & powercfg /change hibernate-timeout-ac 0 2>$null
    & powercfg /change monitor-timeout-ac 15 2>$null
    Write-Host "   -> 电源计划已优化：接通电源下永不休眠。" -ForegroundColor Green
} catch {}

Write-Host "🔐 [3/6] 正在校验并安装 mTLS 双向加密证书..." -ForegroundColor Yellow
$CaCert     = Join-Path $CurrentDir "ca.crt"
$ClientCert = Join-Path $CurrentDir "client.crt"
$ClientKey  = Join-Path $CurrentDir "client.key"

if ((Test-Path $CaCert) -and (Test-Path $ClientCert) -and (Test-Path $ClientKey)) {
    Copy-Item -Path $CaCert, $ClientCert, $ClientKey -Destination $CertsDir -Force
    Write-Host "   -> 证书校验成功并已导入安全存储区。" -ForegroundColor Green
} else {
    Write-Host "❌ 致命错误：未找到验证证书！请确保您完整解压了 ZIP 压缩包。" -ForegroundColor Red
    Read-Host "按回车键退出..."
    Exit
}

Write-Host "📦 [4/6] 正在部署核心组件程序 (离线极速模式)..." -ForegroundColor Yellow
Get-ChildItem -Path $CurrentDir -Filter "*.exe" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $ToolsDir -Force
}
Get-ChildItem -Path $CurrentDir -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $ToolsDir -Force
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (!(Test-Path "$ToolsDir\frpc.exe")) {
    Write-Host "   [!] 正在从官方备用源下载 frpc.exe..." -ForegroundColor DarkYellow
    try {
        $FrpUrl = "$P_HS://github.com/fatedier/frp/releases/download/v0.71.1/frp_0.71.1_windows_amd64.zip"
        Invoke-WebRequest -Uri $FrpUrl -OutFile "$ToolsDir\frp.zip" -TimeoutSec 15
        Expand-Archive -Path "$ToolsDir\frp.zip" -DestinationPath "$ToolsDir\frp_temp" -Force
        Get-ChildItem -Path "$ToolsDir\frp_temp" -Recurse -Filter "frpc.exe" | Move-Item -Destination "$ToolsDir\frpc.exe" -Force
        Remove-Item -Path "$ToolsDir\frp.zip", "$ToolsDir\frp_temp" -Recurse -Force
    } catch {}
}

if (!(Test-Path "$ToolsDir\gost.exe")) {
    Write-Host "   [!] 正在从官方备用源下载 gost.exe..." -ForegroundColor DarkYellow
    try {
        $GostUrl = "$P_HS://github.com/go-gost/gost/releases/download/v3.3.2/gost_3.3.2_windows_amd64.zip"
        Invoke-WebRequest -Uri $GostUrl -OutFile "$ToolsDir\gost.zip" -TimeoutSec 15
        Expand-Archive -Path "$ToolsDir\gost.zip" -DestinationPath "$ToolsDir\gost_temp" -Force
        Get-ChildItem -Path "$ToolsDir\gost_temp" -Recurse -Filter "gost*.exe" | Move-Item -Destination "$ToolsDir\gost.exe" -Force
        Remove-Item -Path "$ToolsDir\gost.zip", "$ToolsDir\gost_temp" -Recurse -Force
    } catch {}
}

$ServyCliPath = "$ToolsDir\servy-cli.exe"
if (!(Test-Path $ServyCliPath) -and (Get-Command "servy-cli.exe" -ErrorAction SilentlyContinue)) {
    $ServyCliPath = (Get-Command "servy-cli.exe").Source
}

Write-Host "   -> 核心运行组件就绪！" -ForegroundColor Green

Write-Host "⚙️  [5/6] 正在生成加密隧道配置文件 (frpc.toml)..." -ForegroundColor Yellow
$FrpcConfig = @"
serverAddr = "$VpsServerIp"
serverPort = 9000
transport.protocol = "tcp"
transport.wireProtocol = "v2"
transport.tls.enable = true
transport.tls.certFile = "C:/Tools/certs/client.crt"
transport.tls.keyFile = "C:/Tools/certs/client.key"
transport.tls.trustedCaFile = "C:/Tools/certs/ca.crt"
transport.heartbeatInterval = 15
transport.heartbeatTimeout = 90
transport.tcpMux = true
auth.method = "token"
auth.token = "$AuthToken"
loginFailExit = false

[[proxies]]
name = "jp_socks5"
type = "tcp"
localIP = "127.0.0.1"
localPort = 10000
remotePort = 10001
transport.useEncryption = true
transport.useCompression = true

[[proxies]]
name = "jp_rdp"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3389
remotePort = 33389
transport.useEncryption = true
transport.useCompression = true
"@
Set-Content -Path "$ToolsDir\frpc.toml" -Value $FrpcConfig -Encoding Ascii
Write-Host "   -> 隧道配置已写入: $ToolsDir\frpc.toml" -ForegroundColor Green

Write-Host "🚀 [6/6] 正在注册并启动后台系统服务..." -ForegroundColor Yellow
if (Test-Path $ServyCliPath) {
    try {
        & $ServyCliPath stop --quiet --name="TikTok_Gost" 2>$null
        & $ServyCliPath stop --quiet --name="TikTok_FRP" 2>$null
        & $ServyCliPath uninstall --quiet --name="TikTok_Gost" 2>$null
        & $ServyCliPath uninstall --quiet --name="TikTok_FRP" 2>$null

        # 安装 GOST 代理服务 (深度适配 Servy v10.x 企业级标准)
        & $ServyCliPath install --quiet `
            --name="TikTok_Gost" `
            --displayName="TikTok GOST SOCKS5 Gateway" `
            --description="TikTok Physical Isolation Local SOCKS5 Gateway" `
            --path="$ToolsDir\gost.exe" `
            --startupDir="$ToolsDir" `
            --params="-L `"socks5://${GostUser}:${GostPass}@127.0.0.1:10000`"" `
            --startupType="Automatic" `
            --recoveryAction="RestartService" `
            --maxRestartAttempts=0 `
            --stdout="$LogsDir\gost.log" `
            --stderr="$LogsDir\gost_err.log" `
            --enableSizeRotation `
            --rotationSize=10 `
            --maxRotations=5

        # 安装 FRP 客户端服务 (深度适配 Servy v10.x 企业级标准)
        & $ServyCliPath install --quiet `
            --name="TikTok_FRP" `
            --displayName="TikTok FRP Reverse Tunnel" `
            --description="TikTok Encrypted Reverse Tunnel to VPS Relay" `
            --path="$ToolsDir\frpc.exe" `
            --startupDir="$ToolsDir" `
            --params="-c `"$ToolsDir\frpc.toml`"" `
            --startupType="Automatic" `
            --recoveryAction="RestartService" `
            --maxRestartAttempts=0 `
            --stdout="$LogsDir\frpc.log" `
            --stderr="$LogsDir\frpc_err.log" `
            --enableSizeRotation `
            --rotationSize=10 `
            --maxRotations=5

        & $ServyCliPath start --quiet --name="TikTok_Gost"
        & $ServyCliPath start --quiet --name="TikTok_FRP"
        Write-Host "   -> 系统服务安装成功，已随系统开机自动启动！" -ForegroundColor Green
    } catch {
        Write-Host "⚠️ 服务静默注册失败，请检查杀软拦截。" -ForegroundColor Red
    }
}

if (Test-Path "$ToolsDir\Servy.exe") {
    try {
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut("$([Environment]::GetFolderPath('Desktop'))\TikTok服务监控.lnk")
        $Shortcut.TargetPath = "$ToolsDir\Servy.exe"
        $Shortcut.WorkingDirectory = $ToolsDir
        $Shortcut.Save()
        Write-Host "   -> 桌面已生成【TikTok服务监控】可视化管理面板！" -ForegroundColor Green
    } catch {}
}

Write-Host ""
Write-Host "🔍 正在进行本地服务健康自检..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

$GostRunning = (Get-Process -Name "gost" -ErrorAction SilentlyContinue) -ne $null
$FrpRunning  = (Get-Process -Name "frpc" -ErrorAction SilentlyContinue) -ne $null

Write-Host ""
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host "🎉 住宅机端环境与底层隧道已部署完成！" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "【系统服务运行状态】" -ForegroundColor Cyan
if ($GostRunning) {
    Write-Host "  ✅ Gost 代理核心   : 正在运行 (进程正常)" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ Gost 代理核心   : 等待启动或请检查 Servy 面板" -ForegroundColor Yellow
}
if ($FrpRunning) {
    Write-Host "  ✅ FRP 隧道核心    : 正在运行 (进程正常)" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ FRP 隧道核心    : 等待启动或请检查 Servy 面板" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "-------------------------------------------------" -ForegroundColor Yellow
Write-Host "🔑【SOCKS5 认证凭证信息】" -ForegroundColor Yellow
Write-Host "👤 代理网关账号 : $GostUser" -ForegroundColor White
Write-Host "🔑 代理网关密码 : $GostPass" -ForegroundColor White
Write-Host "📌 远程映射端口 : 10001 (VPS 内部对接)" -ForegroundColor White
Write-Host "🖥️ 远程桌面端口 : 33389 (RDP 远程管理)" -ForegroundColor White
Write-Host "-------------------------------------------------" -ForegroundColor Yellow
Write-Host ""
Write-Host "💡 提示：本程序已永久常驻后台，开机自启、断线重连、永不休眠。" -ForegroundColor DarkCyan
Write-Host "如需查看或管理服务，可双击桌面的【TikTok服务监控】快捷方式。" -ForegroundColor DarkCyan
Write-Host ""
PS1EOF

# 替换真实配置
sed -i "s/VPS_PUBLIC_IP_PLACEHOLDER/${PUBLIC_IP}/g" setup_frp_gost.ps1
sed -i "s/TOKEN_PLACEHOLDER/${RANDOM_TOKEN}/g" setup_frp_gost.ps1
sed -i "s/GOST_USER_PLACEHOLDER/${GOST_USER}/g" setup_frp_gost.ps1
sed -i "s/GOST_PASS_PLACEHOLDER/${GOST_PASS}/g" setup_frp_gost.ps1

# 打包为 zip (同时放置于 /root/frp 与 /root 方便获取)
rm -f ../windows_frp_gost_pkg.zip /root/windows_frp_gost_pkg.zip
zip -q -r ../windows_frp_gost_pkg.zip ./*
cp ../windows_frp_gost_pkg.zip /root/windows_frp_gost_pkg.zip 2>/dev/null || true
cd ..
rm -rf "$PKG_DIR"

# ------------------------------------------------------------------------------
# 启动临时极速下载 Web 服务 (无需 SFTP)
# ------------------------------------------------------------------------------
RAND_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo "28989")
(cd /root/frp && python3 -m http.server "$RAND_PORT" >/dev/null 2>&1) &
PY_PID=$!
(sleep 1200 && kill -9 "$PY_PID" 2>/dev/null) >/dev/null 2>&1 &

# ------------------------------------------------------------------------------
# 终端完成汇报
# ------------------------------------------------------------------------------
clear
echo "======================================================================"
echo -e "\033[32m🎉 [成功] FRP 服务端部署完毕 & Windows 客户端极速离线包生成完成！\033[0m"
echo "======================================================================"
echo ""
echo -e "\033[36m【📥 获取 Windows 部署包的方法 (二选一)】\033[0m"
echo "----------------------------------------------------------------------"
echo -e "\033[33m【方式一：住宅机浏览器直链下载 (最推荐，零门槛)】\033[0m"
echo "在 Windows 住宅机浏览器（Edge/Chrome）中打开下方链接直接下载："
echo -e "👉 \033[32mhttp://${PUBLIC_IP}:${RAND_PORT}/windows_frp_gost_pkg.zip\033[0m"
echo "   (⚠️ 该临时下载链接由 Python 提供，将在 20 分钟后自动销毁)"
echo ""
echo -e "\033[33m【方式二：使用 SFTP 工具下载】\033[0m"
echo "使用 FinalShell / WinSCP 连接 VPS，下载以下路径的文件："
echo -e "📁 \033[32m/root/frp/windows_frp_gost_pkg.zip\033[0m (或 /root/windows_frp_gost_pkg.zip)"
echo "----------------------------------------------------------------------"
echo ""
echo -e "\033[36m【🖥️ Windows 住宅机端操作说明】\033[0m"
echo "1. 下载后将 windows_frp_gost_pkg.zip 解压到桌面。"
echo "2. 右键点击【一键安装(以管理员运行).bat】，选择【以管理员身份运行】。"
echo "3. 脚本全自动离线部署，5 秒内完成，无任何网络依赖！"
echo ""
echo "======================================================================"
echo -e "\033[36m【🌐 S-UI 面板对接配置指南 (打通最后一公里)】\033[0m"
echo "======================================================================"
echo "请登录您的 S-UI 面板，根据以下参数进行配置："
echo ""
echo -e "\033[33m1. 创建出站 (Outbounds -> Add Outbound)\033[0m"
echo "   - 标签 (Tag)       : proxy_jp"
echo "   - 协议 (Protocol)  : socks"
echo "   - 地址 (Address)   : 127.0.0.1"
echo "   - 端口 (Port)      : 10001"
echo -e "   - 账号 (Username)  : \033[32m${GOST_USER}\033[0m"
echo -e "   - 密码 (Password)  : \033[32m${GOST_PASS}\033[0m"
echo ""
echo -e "\033[33m2. 创建业务专属入站 (Inbounds -> Add Inbound)\033[0m"
echo "   - 协议 (Protocol)  : vless"
echo "   - 端口 (Port)      : 8443"
echo "   - 传输 (Network)   : tcp"
echo "   - 安全 (TLS)       : reality"
echo "   - 目标 (Dest)      : gateway.icloud.com:443"
echo "   - 域名 (SNI)       : gateway.icloud.com"
echo "   - 标签 (Tag)       : tiktok_in"
echo ""
echo -e "\033[33m3. 配置路由规则 (Routes -> Add Rule)\033[0m"
echo "   - 规则一 (TikTok流量走住宅机) :"
echo "     Inbound Tag = tiktok_in  ==>  Outbound Tag = proxy_jp"
echo "   - 规则二 (国内直连降低延迟)   :"
echo "     Domain = geosite:cn, IP = geoip:cn  ==>  Outbound Tag = direct"
echo ""
echo "======================================================================"
echo -e "\033[36m【🔎 验收与排查命令 (在 VPS 终端执行)】\033[0m"
echo "----------------------------------------------------------------------"
echo "1. 检查住宅机隧道是否连通："
echo "   ss -antp | grep 10001"
echo ""
echo "2. 验证业务出口 IP (返回住宅机公网 IP 即表示完美成功)："
echo "   curl -x socks5://${GOST_USER}:${GOST_PASS}@127.0.0.1:10001 http://ip-api.com/json"
echo "======================================================================"
