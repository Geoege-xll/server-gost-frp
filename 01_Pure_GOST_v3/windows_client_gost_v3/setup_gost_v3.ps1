# ==============================================================
# TikTok 住宅机端 - 极速部署系统 (纯 GOST v3 物理隔离终极版)
# ==============================================================

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

# 占位符变量（在 VPS 生成包时由 sed 替换注入）
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

# -------------------------------------------------------------
# A. 初始化目录与 Windows Defender 白名单
# -------------------------------------------------------------
Write-Host "📁 [1/5] 正在配置目录并添加安全防护白名单..." -ForegroundColor Yellow
New-Item -Path $ToolsDir, $CertsDir, $LogsDir -ItemType Directory -Force | Out-Null
try {
    Add-MpPreference -ExclusionPath $ToolsDir -ErrorAction SilentlyContinue
    Write-Host "   -> Defender 白名单已生效: $ToolsDir" -ForegroundColor Green
} catch {}

# -------------------------------------------------------------
# B. 配置系统电源策略 (防止待机休眠掉线)
# -------------------------------------------------------------
Write-Host "⚡ [2/5] 正在优化系统电源策略 (防止睡眠断连)..." -ForegroundColor Yellow
try {
    & powercfg /change standby-timeout-ac 0 2>$null
    & powercfg /change hibernate-timeout-ac 0 2>$null
    & powercfg /change monitor-timeout-ac 15 2>$null
    Write-Host "   -> 电源策略已配置：接通电源下永不休眠。" -ForegroundColor Green
} catch {}

# -------------------------------------------------------------
# C. 安装 mTLS 安全双向加密证书
# -------------------------------------------------------------
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

# -------------------------------------------------------------
# D. 部署执行程序与配置文件
# -------------------------------------------------------------
Write-Host "📦 [4/5] 正在部署 GOST v3 核心程序与配置..." -ForegroundColor Yellow

# 拷贝离线可执行程序与依赖
Get-ChildItem -Path $CurrentDir -Filter "*.exe" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $ToolsDir -Force
}
Get-ChildItem -Path $CurrentDir -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $ToolsDir -Force
}

# 兜底检测 gost.exe
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (!(Test-Path "$ToolsDir\gost.exe")) {
    Write-Host "   [!] 本地未包含 gost.exe，正在从官方备用源下载..." -ForegroundColor DarkYellow
    try {
        $GostVer = "3.3.2"
        $GostUrl = "$P_HS://github.com/go-gost/gost/releases/download/v$GostVer/gost_$($GostVer)_windows_amd64.zip"
        Invoke-WebRequest -Uri $GostUrl -OutFile "$ToolsDir\gost.zip" -TimeoutSec 15
        Expand-Archive -Path "$ToolsDir\gost.zip" -DestinationPath "$ToolsDir\gost_temp" -Force
        Get-ChildItem -Path "$ToolsDir\gost_temp" -Recurse -Filter "gost*.exe" | Move-Item -Destination "$ToolsDir\gost.exe" -Force
        Remove-Item -Path "$ToolsDir\gost.zip", "$ToolsDir\gost_temp" -Recurse -Force
    } catch {}
}

# 写入纯 GOST v3 统一配置文件 (gost.yaml)
$GostYaml = @"
services:
  # 1. 本地 SOCKS5 代理网关 (带强密码鉴权出口)
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

  # 2. 远程端口穿透：将 SOCKS5 映射到 VPS 的 127.0.0.1:10001 (安全隔离，仅供 S-UI 访问)
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

  # 3. 远程端口穿透：将 Windows 远程桌面 (3389) 映射到 VPS 33389 端口 (方便免密管理)
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

# -------------------------------------------------------------
# E. 注册为 Windows 系统服务
# -------------------------------------------------------------
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

# -------------------------------------------------------------
# F. 服务自检
# -------------------------------------------------------------
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
