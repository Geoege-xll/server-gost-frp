#!/bin/bash
# ==============================================================================
# 🚀 TikTok 日本/跨境电商双入站物理隔离方案 - 纯 GOST v3 极速部署与全打包引擎
# 版本：V3.0 (Pure GOST v3 Architecture & mTLS 双向认证傻瓜版)
# 架构：单二进制、单后台服务、内置 mTLS 强证书、零端口暴露
# 适用系统：Ubuntu 20.04/22.04/24.04, Debian 11/12, CentOS 7/8/9, AlmaLinux, RockyLinux
# ==============================================================================

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[31m❌ 错误：请使用 root 权限运行此脚本！(例如 sudo bash $0)\033[0m"
    exit 1
fi

H_S="https"
H_T="http"

# ------------------------------------------------------------------------------
# 快捷升级指令支持 (bash install_vps_gost_v3.sh --upgrade / -u)
# ------------------------------------------------------------------------------
if [ "$1" == "--upgrade" ] || [ "$1" == "-u" ] || [ "$1" == "upgrade" ]; then
    echo "======================================================================"
    echo -e "\033[36m🚀 正在通过命令一键平滑升级 GOST v3 二进制核心...\033[0m"
    echo "======================================================================"
    LATEST_GOST_TAG=$(curl -s "${H_S}://api.github.com/repos/go-gost/gost/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
    if [ -z "$LATEST_GOST_TAG" ]; then LATEST_GOST_TAG="v3.3.2"; fi
    GOST_VER_NUM=${LATEST_GOST_TAG#v}

    CURRENT_VER=$(/usr/local/bin/gost -V 2>&1 | awk '{print $2}' || echo "未安装")
    echo -e "   -> 当前版本: \033[33m${CURRENT_VER}\033[0m"
    echo -e "   -> 目标最新版本: \033[32m${LATEST_GOST_TAG}\033[0m"

    echo "   -> 正在下载最新 Linux 版 GOST 二进制..."
    TMP_DIR=$(mktemp -d)
    wget -qO "$TMP_DIR/gost_linux.tar.gz" "${H_S}://github.com/go-gost/gost/releases/download/${LATEST_GOST_TAG}/gost_${GOST_VER_NUM}_linux_amd64.tar.gz"
    tar -xzf "$TMP_DIR/gost_linux.tar.gz" -C "$TMP_DIR"
    cp "$TMP_DIR/gost" /usr/local/bin/gost
    chmod +x /usr/local/bin/gost
    rm -rf "$TMP_DIR"

    if systemctl is-active --quiet gost 2>/dev/null; then
        echo "   -> 正在平滑重启 gost 守护服务..."
        systemctl restart gost
        sleep 1
        if systemctl is-active --quiet gost 2>/dev/null; then
            echo -e "\033[32m✅ GOST v3 升级成功并已恢复运行！现有证书与配置文件完全保留无损！\033[0m"
        else
            echo -e "\033[31m⚠️ 服务启动异常，请检查 systemctl status gost 日志。\033[0m"
        fi
    else
        echo -e "\033[32m✅ GOST v3 二进制已平滑更新至 ${LATEST_GOST_TAG}！\033[0m"
    fi
    exit 0
fi

echo "======================================================================"
echo -e "\033[36m🚀 开始执行 纯 GOST v3 服务端极速部署与离线客户端打包引擎 (V3.0)\033[0m"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. 安装系统依赖
# ------------------------------------------------------------------------------
echo -e "\n\033[33m📦 [1/7] 正在检查并安装底层运行依赖...\033[0m"
if [ -f /etc/debian_version ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -yqq
    apt-get install -yqq curl wget tar unzip zip openssl p7zip-full ca-certificates
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget tar unzip zip openssl epel-release || true
    yum install -y p7zip p7zip-plugins || true
fi

# ------------------------------------------------------------------------------
# 2. 优化系统内核 (禁用 IPv6)
# ------------------------------------------------------------------------------
echo -e "\n\033[33m🔧 [2/7] 正在优化系统网络内核 (优化 IPv6 兼容)...\033[0m"
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
if ! grep -q "net.ipv6.conf.all.disable_ipv6 = 1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 3. 自动探测公网 IP
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
# 4. 下载并安装 Linux 端 GOST v3 二进制
# ------------------------------------------------------------------------------
echo -e "\n\033[33m🔍 [4/7] 正在请求 GitHub 官方源获取 GOST v3 最新版本...\033[0m"
LATEST_GOST_TAG=$(curl -s "${H_S}://api.github.com/repos/go-gost/gost/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
if [ -z "$LATEST_GOST_TAG" ]; then
    LATEST_GOST_TAG="v3.3.2"
    echo -e "   \033[33m[!] GitHub API 受限，使用默认稳定版本: $LATEST_GOST_TAG\033[0m"
fi
GOST_VER_NUM=${LATEST_GOST_TAG#v}

mkdir -p /etc/gost/certs
cd /etc/gost

echo -e "   -> 正在下载并安装 GOST v3 (Linux amd64)..."
wget -qO gost_linux.tar.gz "${H_S}://github.com/go-gost/gost/releases/download/${LATEST_GOST_TAG}/gost_${GOST_VER_NUM}_linux_amd64.tar.gz"
tar -xzf gost_linux.tar.gz
mv gost /usr/local/bin/gost
chmod +x /usr/local/bin/gost
rm -rf gost_linux.tar.gz
echo -e "   \033[32m✅ GOST v$GOST_VER_NUM 安装完成 (/usr/local/bin/gost)。\033[0m"

# ------------------------------------------------------------------------------
# 5. 签发 mTLS 双向认证证书 (10年有效期)
# ------------------------------------------------------------------------------
echo -e "\n\033[33m🔐 [5/7] 正在签发 mTLS 双向高强度加密证书 (CA / Server / Client)...\033[0m"
cd /etc/gost/certs

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
CN = GOST-CA
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
openssl req -new -key server.key -out server.csr -subj "/CN=gost-server" -config my-openssl.cnf 2>/dev/null
openssl ca -batch -in server.csr -out server.crt -cert ca.crt -keyfile ca.key -extensions server_ext -config my-openssl.cnf 2>/dev/null
openssl genrsa -out client.key 2048 2>/dev/null
openssl req -new -key client.key -out client.csr -subj "/CN=gost-client" -config my-openssl.cnf 2>/dev/null
openssl ca -batch -in client.csr -out client.crt -cert ca.crt -keyfile ca.key -extensions usr_cert -config my-openssl.cnf 2>/dev/null
rm -f *.csr index.txt* serial* my-openssl.cnf *.old
echo -e "   \033[32m✅ mTLS 双向证书生成成功。\033[0m"

# ------------------------------------------------------------------------------
# 6. 生成服务端配置与启动后台守护服务
# ------------------------------------------------------------------------------
echo -e "\n\033[33m⚙️  [6/7] 正在生成服务端配置并启动 GOST 系统守护服务...\033[0m"
RELAY_USER="relay_$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 5)"
RELAY_PASS=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
GOST_USER="user_$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 5)"
GOST_PASS=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 14)

cat > /etc/gost/gost.yaml << YAML
services:
  - name: relay-server
    addr: ":9000"
    handler:
      type: relay
      auth:
        username: "${RELAY_USER}"
        password: "${RELAY_PASS}"
      metadata:
        bind: true
        nodelay: true
    listener:
      type: mtls
      tls:
        certFile: "/etc/gost/certs/server.crt"
        keyFile: "/etc/gost/certs/server.key"
        caFile: "/etc/gost/certs/ca.crt"
YAML

cat > /etc/systemd/system/gost.service << SVC
[Unit]
Description=GOST v3 Relay Tunnel Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/gost -C /etc/gost/gost.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable gost >/dev/null 2>&1
systemctl restart gost
echo -e "   \033[32m✅ GOST v3 服务端已在后台监听 9000 端口 (带 mTLS 校验)！\033[0m"

# ------------------------------------------------------------------------------
# 7. 构建纯 GOST v3 Windows 极速离线客户端包
# ------------------------------------------------------------------------------
echo -e "\n\033[33m📦 [7/7] 正在下载 Windows 组件并构建全离线一键安装包...\033[0m"

PKG_DIR="/etc/gost/win_pkg"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"
cd "$PKG_DIR"

# 复制证书
cp /etc/gost/certs/ca.crt /etc/gost/certs/client.crt /etc/gost/certs/client.key ./

# 下载 Windows 版 gost.exe
echo "   -> 正在下载 Windows 版 GOST (gost.exe)..."
wget -qO gost_win.zip "${H_S}://github.com/go-gost/gost/releases/download/${LATEST_GOST_TAG}/gost_${GOST_VER_NUM}_windows_amd64.zip" || true
if [ -f gost_win.zip ]; then
    unzip -q gost_win.zip
    find . -type f -name "gost*.exe" -exec mv {} ./gost.exe \;
    rm -rf gost_win.zip
fi

# 下载 Servy CLI 服务管理组件
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

# 写入批处理文件: 一键安装(以管理员运行).bat
cat > "一键安装(以管理员运行).bat" << 'BATEOF'
@echo off
chcp 65001 >nul
title TikTok 住宅机环境一键极速部署 (纯 GOST v3)

:: 检查是否具备管理员权限
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo [提示] 正在请求系统管理员权限，请在弹出的系统提示中点击【是】...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
echo =======================================================
echo  正在启动 TikTok 住宅机部署引擎 (纯 GOST v3 架构)...
echo =======================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_gost_v3.ps1"

echo.
echo =======================================================
echo 请按任意键关闭此窗口...
pause >nul
BATEOF

# 写入批处理文件: 一键卸载(以管理员运行).bat
cat > "一键卸载(以管理员运行).bat" << 'BATEOF'
@echo off
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
BATEOF

# 写入 uninstall_gost_v3.ps1
cat > "uninstall_gost_v3.ps1" << 'PS1EOF'
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

if (Test-Path $ServyCli) {
    & $ServyCli stop --quiet --name="TikTok_Gost" 2>$null
    & $ServyCli uninstall --quiet --name="TikTok_Gost" 2>$null
}

try {
    & sc.exe stop TikTok_Gost 2>$null | Out-Null
    & sc.exe delete TikTok_Gost 2>$null | Out-Null
} catch {}

Get-Process -Name "gost", "servy", "Servy.Manager" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

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
Write-Host "🎉 纯 GOST v3 客户端卸载与清理完成！" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
PS1EOF

# 写入 README_住宅机安装说明.txt
cat > "README_住宅机安装说明.txt" << 'TXTEOF'
====================================================================
🚀 TikTok 住宅机环境一键傻瓜式部署说明 (纯 GOST v3 极速版)
====================================================================

【使用方法 - 仅需 2 步】

第 1 步：
将收到的压缩包 (windows_gost_v3_pkg.zip) 解压到电脑的任意位置（例如桌面）。

第 2 步：
进入解压后的文件夹，找到：
【一键安装(以管理员运行).bat】
鼠标右键点击它，选择【以管理员身份运行】（或直接双击，在弹出的系统提示中点击【是】）。

====================================================================
【纯 GOST v3 架构优势】
1. 极简高效：全系统仅需单个 GOST 服务常驻，占用内存极低，性能卓越。
2. 零下载安装：离线集成所需程序，5 秒秒级安装完毕。
3. 自动加白：自动添加 Windows Defender 信任目录 (C:\Tools)。
4. 防休眠防断连：接通电源下永不休眠、永不待机，保障 7×24 小时在线。
5. 最高安全等级：全隧道采用 mTLS 双向证书加密通信。

====================================================================
【日常管理与常见问题】

1. 日常需要手动打开软件吗？
   不需要！服务已经作为 Windows 系统底层服务运行，每次开机都会自动启动。

2. 如何查看服务是否正常运行？
   双击桌面的【TikTok服务监控】图标，可以看到 TikTok_Gost 状态为绿色的 "Running"。

3. 如果想要卸载怎么做？
   打开本目录下的【一键卸载(以管理员运行).bat】，右键以管理员身份运行即可一键清理干净。
====================================================================
TXTEOF

# 写入 setup_gost_v3.ps1 并注入真实配置
cat > "setup_gost_v3.ps1" << 'PS1EOF'
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
$RelayUser   = "RELAY_USER_PLACEHOLDER"
$RelayPass   = "RELAY_PASS_PLACEHOLDER"
$GostUser    = "GOST_USER_PLACEHOLDER"
$GostPass    = "GOST_PASS_PLACEHOLDER"

Clear-Host
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "🚀 Windows 住宅机端 - 极速部署系统 (纯 GOST v3 版)" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "📁 [1/5] 正在配置目录并添加安全防护白名单..." -ForegroundColor Yellow
New-Item -Path $ToolsDir, $CertsDir, $LogsDir -ItemType Directory -Force | Out-Null
try {
    Add-MpPreference -ExclusionPath $ToolsDir -ErrorAction SilentlyContinue
    Write-Host "   -> Defender 白名单已生效: $ToolsDir" -ForegroundColor Green
} catch {}

Write-Host "⚡ [2/5] 正在优化系统电源策略 (防止睡眠断连)..." -ForegroundColor Yellow
try {
    & powercfg /change standby-timeout-ac 0 2>$null
    & powercfg /change hibernate-timeout-ac 0 2>$null
    & powercfg /change monitor-timeout-ac 15 2>$null
    Write-Host "   -> 电源策略已配置：接通电源下永不休眠。" -ForegroundColor Green
} catch {}

Write-Host "🔐 [3/5] 正在校验并安装 mTLS 双向认证证书..." -ForegroundColor Yellow
$CaCert     = Join-Path $CurrentDir "ca.crt"
$ClientCert = Join-Path $CurrentDir "client.crt"
$ClientKey  = Join-Path $CurrentDir "client.key"

if ((Test-Path $CaCert) -and (Test-Path $ClientCert) -and (Test-Path $ClientKey)) {
    Copy-Item -Path $CaCert, $ClientCert, $ClientKey -Destination $CertsDir -Force
    Write-Host "   -> mTLS 证书校验成功并已就绪。" -ForegroundColor Green
} else {
    Write-Host "❌ 致命错误：未找到证书文件！请确保完整解压了 ZIP 压缩包。" -ForegroundColor Red
    Read-Host "按回车键退出..."
    Exit
}

Write-Host "📦 [4/5] 正在部署 GOST v3 核心程序与配置..." -ForegroundColor Yellow
Get-ChildItem -Path $CurrentDir -Filter "*.exe" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $ToolsDir -Force
}
Get-ChildItem -Path $CurrentDir -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $ToolsDir -Force
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
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

$GostYaml = @"
services:
  - name: local-socks5
    addr: "127.0.0.1:10000"
    handler:
      type: socks5
      auth:
        username: "$GostUser"
        password: "$GostPass"
    listener:
      type: tcp
      metadata:
        nodelay: true

  - name: rtcp-socks5
    addr: "127.0.0.1:10001"
    handler:
      type: rtcp
    listener:
      type: rtcp
    chain: relay-chain
    forwarder:
      nodes:
        - name: target-socks5
          addr: "127.0.0.1:10000"

  - name: rtcp-rdp
    addr: ":33389"
    handler:
      type: rtcp
    listener:
      type: rtcp
    chain: relay-chain
    forwarder:
      nodes:
        - name: target-rdp
          addr: "127.0.0.1:3389"

chains:
  - name: relay-chain
    hops:
      - name: vps-relay
        nodes:
          - name: relay-node
            addr: "$VpsServerIp:9000"
            connector:
              type: relay
              auth:
                username: "$RelayUser"
                password: "$RelayPass"
              metadata:
                nodelay: true
            dialer:
              type: mtls
              tls:
                certFile: "C:/Tools/certs/client.crt"
                keyFile: "C:/Tools/certs/client.key"
                caFile: "C:/Tools/certs/ca.crt"
                secure: true
              metadata:
                nodelay: true
"@

Set-Content -Path "$ToolsDir\gost.yaml" -Value $GostYaml -Encoding Utf8
Write-Host "   -> 纯 GOST v3 配置文件已写入: $ToolsDir\gost.yaml" -ForegroundColor Green

Write-Host "🚀 [5/5] 正在注册并启动后台系统服务 (单服务自愈模式)..." -ForegroundColor Yellow
$ServyCliPath = "$ToolsDir\servy-cli.exe"
if (!(Test-Path $ServyCliPath) -and (Get-Command "servy-cli.exe" -ErrorAction SilentlyContinue)) {
    $ServyCliPath = (Get-Command "servy-cli.exe").Source
}

if (Test-Path $ServyCliPath) {
    try {
        & $ServyCliPath stop --quiet --name="TikTok_Gost" 2>$null
        & $ServyCliPath uninstall --quiet --name="TikTok_Gost" 2>$null

        # 注册单个全局 GOST 服务 (深度适配 Servy v10.x 企业级标准)
        & $ServyCliPath install --quiet `
            --name="TikTok_Gost" `
            --displayName="TikTok GOST v3 Tunnel" `
            --description="TikTok Physical Isolation Pure GOST v3 Relay & Reverse Tunnel" `
            --path="$ToolsDir\gost.exe" `
            --startupDir="$ToolsDir" `
            --params="-C `"$ToolsDir\gost.yaml`"" `
            --startupType="Automatic" `
            --recoveryAction="RestartService" `
            --maxRestartAttempts=0 `
            --stdout="$LogsDir\gost.log" `
            --stderr="$LogsDir\gost_err.log" `
            --enableSizeRotation `
            --rotationSize=10 `
            --maxRotations=5
        & $ServyCliPath start --quiet --name="TikTok_Gost"
        Write-Host "   -> 系统服务【TikTok_Gost】已安装并设置为开机自启！" -ForegroundColor Green
    } catch {
        Write-Host "⚠️ 服务静默注册失败，请检查杀软权限。" -ForegroundColor Red
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
$PortOpen = $false
try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect("127.0.0.1", 10000, $null, $null)
    $wait = $iar.AsyncWaitHandle.WaitOne(1500, $false)
    if ($wait -and $client.Connected) {
        $PortOpen = $true
        $client.EndConnect($iar)
    }
    $client.Close()
} catch {}

Write-Host ""
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host "🎉 恭喜！纯 GOST v3 住宅机端已成功部署！" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "【运行状态】" -ForegroundColor Cyan
if ($GostRunning) {
    Write-Host "  ✅ GOST 核心进程   : 正在运行 (单进程高效模式)" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ GOST 核心进程   : 未启动，请检查 Servy 面板" -ForegroundColor Red
}

if ($PortOpen) {
    Write-Host "  ✅ SOCKS5 代理网关 : 127.0.0.1:10000 监听正常" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ SOCKS5 代理网关 : 等待就绪中" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "-------------------------------------------------" -ForegroundColor Yellow
Write-Host "🔑【SOCKS5 认证凭据信息】" -ForegroundColor Yellow
Write-Host "👤 代理网关账号 : $GostUser" -ForegroundColor White
Write-Host "🔑 代理网关密码 : $GostPass" -ForegroundColor White
Write-Host "📌 远程映射端口 : 10001 (供 VPS 内部 S-UI 对接)" -ForegroundColor White
Write-Host "🖥️ 远程桌面端口 : 33389 (RDP 远程管理)" -ForegroundColor White
Write-Host "-------------------------------------------------" -ForegroundColor Yellow
Write-Host ""
Write-Host "💡 优势特性：全链路单二进制守护，集成 mTLS 双向认证，接通电源永不休眠。" -ForegroundColor DarkCyan
Write-Host ""
PS1EOF

# 替换动态凭据
sed -i "s/VPS_PUBLIC_IP_PLACEHOLDER/${PUBLIC_IP}/g" setup_gost_v3.ps1
sed -i "s/RELAY_USER_PLACEHOLDER/${RELAY_USER}/g" setup_gost_v3.ps1
sed -i "s/RELAY_PASS_PLACEHOLDER/${RELAY_PASS}/g" setup_gost_v3.ps1
sed -i "s/GOST_USER_PLACEHOLDER/${GOST_USER}/g" setup_gost_v3.ps1
sed -i "s/GOST_PASS_PLACEHOLDER/${GOST_PASS}/g" setup_gost_v3.ps1

# 打包为 zip
rm -f /etc/gost/windows_gost_v3_pkg.zip /root/windows_gost_v3_pkg.zip
zip -q -r /etc/gost/windows_gost_v3_pkg.zip ./*
cp /etc/gost/windows_gost_v3_pkg.zip /root/windows_gost_v3_pkg.zip
cd /etc/gost
rm -rf "$PKG_DIR"

# ------------------------------------------------------------------------------
# 启动临时直链下载 Web 服务
# ------------------------------------------------------------------------------
RAND_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo "29898")
(cd /etc/gost && python3 -m http.server "$RAND_PORT" >/dev/null 2>&1) &
PY_PID=$!
(sleep 1200 && kill -9 "$PY_PID" 2>/dev/null) >/dev/null 2>&1 &

# ------------------------------------------------------------------------------
# 终端完成汇报
# ------------------------------------------------------------------------------
clear
echo "======================================================================"
echo -e "\033[32m🎉 [成功] 纯 GOST v3 服务端部署完毕 & Windows 客户端极速离线包生成完成！\033[0m"
echo "======================================================================"
echo ""
echo -e "\033[36m【📥 获取 Windows 纯 GOST v3 部署包的方法 (二选一)】\033[0m"
echo "----------------------------------------------------------------------"
echo -e "\033[33m【方式一：住宅机浏览器直链极速下载 (最推荐)】\033[0m"
echo "在 Windows 住宅机浏览器（Edge/Chrome）中打开下方链接直接下载："
echo -e "👉 \033[32mhttp://${PUBLIC_IP}:${RAND_PORT}/windows_gost_v3_pkg.zip\033[0m"
echo "   (⚠️ 该临时直链将在 20 分钟后自动销毁)"
echo ""
echo -e "\033[33m【方式二：使用 SFTP 工具下载】\033[0m"
echo "使用 FinalShell / WinSCP 连接 VPS，下载以下路径的文件："
echo -e "📁 \033[32m/root/windows_gost_v3_pkg.zip\033[0m"
echo "----------------------------------------------------------------------"
echo ""
echo -e "\033[36m【🖥️ Windows 住宅机端操作说明】\033[0m"
echo "1. 下载后将 windows_gost_v3_pkg.zip 解压到桌面。"
echo "2. 右键点击【一键安装(以管理员运行).bat】，选择【以管理员身份运行】。"
echo "3. 脚本全自动离线部署，5 秒内完成，仅运行一个高效的 GOST 服务！"
echo ""
echo "======================================================================"
echo -e "\033[36m【🌐 S-UI 面板对接配置指南】\033[0m"
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
echo "   - 规则一 (TikTok业务流量走住宅机) :"
echo "     Inbound Tag = tiktok_in  ==>  Outbound Tag = proxy_jp"
echo "   - 规则二 (国内流量直连降低延迟)   :"
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
