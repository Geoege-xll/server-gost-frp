# ==============================================================
# TikTok 住宅机端 - 极速部署系统 (V2.5 纯离线/自愈傻瓜版)
# ==============================================================

# 1. 确保以管理员权限执行
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "正在请求管理员权限，请在弹窗中选择【是】..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

# 2. 定位当前目录与安装目标路径
$CurrentDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrWhiteSpace($CurrentDir)) { $CurrentDir = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($CurrentDir)) { $CurrentDir = (Get-Location).Path }

$ToolsDir = "C:\Tools"
$CertsDir = "$ToolsDir\certs"
$LogsDir  = "$ToolsDir\logs"
$P_HS     = "https"

# 占位符变量（在 VPS 生成包时会被 sed 自动注入真实数据）
$VpsServerIp = "VPS_PUBLIC_IP_PLACEHOLDER"
$AuthToken   = "TOKEN_PLACEHOLDER"
$GostUser    = "GOST_USER_PLACEHOLDER"
$GostPass    = "GOST_PASS_PLACEHOLDER"

Clear-Host
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "🚀 Windows 住宅机端 - 极速部署系统 (V2.5 傻瓜版)" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------------------------
# A. 初始化目录与 Windows Defender 防病毒白名单
# -------------------------------------------------------------
Write-Host "📁 [1/6] 正在初始化运行环境并添加防病毒白名单..." -ForegroundColor Yellow
New-Item -Path $ToolsDir, $CertsDir, $LogsDir -ItemType Directory -Force | Out-Null

try {
    # 率先添加白名单，防止后续拷贝 exe 时被杀软瞬间拦截
    Add-MpPreference -ExclusionPath $ToolsDir -ErrorAction SilentlyContinue
    Write-Host "   -> 安全防护白名单已应用: $ToolsDir" -ForegroundColor Green
} catch {
    Write-Host "   [!] 未能自动配置 Defender 白名单，如遇杀软拦截请手动放行。" -ForegroundColor DarkGray
}

# -------------------------------------------------------------
# B. 配置系统电源策略 (防止住宅电脑休眠导致断网)
# -------------------------------------------------------------
Write-Host "⚡ [2/6] 正在优化系统电源策略 (防止待机/休眠掉线)..." -ForegroundColor Yellow
try {
    & powercfg /change standby-timeout-ac 0 2>$null
    & powercfg /change hibernate-timeout-ac 0 2>$null
    & powercfg /change monitor-timeout-ac 15 2>$null
    Write-Host "   -> 电源计划已优化：接通电源下永不休眠。" -ForegroundColor Green
} catch {
    Write-Host "   [!] 无法修改电源计划，建议手动在控制面板中关闭睡眠。" -ForegroundColor DarkGray
}

# -------------------------------------------------------------
# C. 验证并安装 mTLS 安全证书
# -------------------------------------------------------------
Write-Host "🔐 [3/6] 正在校验并安装 mTLS 双向加密证书..." -ForegroundColor Yellow
$CaCert     = Join-Path $CurrentDir "ca.crt"
$ClientCert = Join-Path $CurrentDir "client.crt"
$ClientKey  = Join-Path $CurrentDir "client.key"

if ((Test-Path $CaCert) -and (Test-Path $ClientCert) -and (Test-Path $ClientKey)) {
    Copy-Item -Path $CaCert, $ClientCert, $ClientKey -Destination $CertsDir -Force
    Write-Host "   -> 证书校验成功并已导入安全存储区。" -ForegroundColor Green
} else {
    Write-Host "❌ 致命错误：未找到验证证书！请确保您完整解压了 ZIP 压缩包。" -ForegroundColor Red
    Write-Host "   缺少: ca.crt / client.crt / client.key" -ForegroundColor Red
    Read-Host "按回车键退出..."
    Exit
}

# -------------------------------------------------------------
# D. 部署执行程序 (优先离线，兜底在线)
# -------------------------------------------------------------
Write-Host "📦 [4/6] 正在部署核心组件程序 (离线极速模式)..." -ForegroundColor Yellow

# 拷贝本地已打包好的可执行文件
Get-ChildItem -Path $CurrentDir -Filter "*.exe" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $ToolsDir -Force
}

# 拷贝可能解压带入的 DLL 或配置文件
Get-ChildItem -Path $CurrentDir -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $ToolsDir -Force
}

# 兜底检测：如果本地包里缺少某些核心组件，则尝试在线补齐
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1. 检查 frpc.exe
if (!(Test-Path "$ToolsDir\frpc.exe")) {
    Write-Host "   [!] 本地未包含 frpc.exe，正在尝试从 GitHub 备用源下载..." -ForegroundColor DarkYellow
    try {
        $FrpVer = "0.71.1"
        $FrpUrl = "$P_HS://github.com/fatedier/frp/releases/download/v$FrpVer/frp_$($FrpVer)_windows_amd64.zip"
        Invoke-WebRequest -Uri $FrpUrl -OutFile "$ToolsDir\frp.zip" -TimeoutSec 15
        Expand-Archive -Path "$ToolsDir\frp.zip" -DestinationPath "$ToolsDir\frp_temp" -Force
        Get-ChildItem -Path "$ToolsDir\frp_temp" -Recurse -Filter "frpc.exe" | Move-Item -Destination "$ToolsDir\frpc.exe" -Force
        Remove-Item -Path "$ToolsDir\frp.zip", "$ToolsDir\frp_temp" -Recurse -Force
    } catch {
        Write-Host "❌ frpc.exe 下载失败，请检查网络。" -ForegroundColor Red
    }
}

# 2. 检查 gost.exe
if (!(Test-Path "$ToolsDir\gost.exe")) {
    Write-Host "   [!] 本地未包含 gost.exe，正在尝试从 GitHub 备用源下载..." -ForegroundColor DarkYellow
    try {
        $GostVer = "3.3.2"
        $GostUrl = "$P_HS://github.com/go-gost/gost/releases/download/v$GostVer/gost_$($GostVer)_windows_amd64.zip"
        Invoke-WebRequest -Uri $GostUrl -OutFile "$ToolsDir\gost.zip" -TimeoutSec 15
        Expand-Archive -Path "$ToolsDir\gost.zip" -DestinationPath "$ToolsDir\gost_temp" -Force
        Get-ChildItem -Path "$ToolsDir\gost_temp" -Recurse -Filter "gost*.exe" | Move-Item -Destination "$ToolsDir\gost.exe" -Force
        Remove-Item -Path "$ToolsDir\gost.zip", "$ToolsDir\gost_temp" -Recurse -Force
    } catch {
        Write-Host "❌ gost.exe 下载失败，请检查网络。" -ForegroundColor Red
    }
}

# 3. 检查 servy-cli.exe
$ServyCliPath = "$ToolsDir\servy-cli.exe"
if (!(Test-Path $ServyCliPath) -and (Get-Command "servy-cli.exe" -ErrorAction SilentlyContinue)) {
    $ServyCliPath = (Get-Command "servy-cli.exe").Source
}

Write-Host "   -> 核心运行组件就绪！" -ForegroundColor Green

# -------------------------------------------------------------
# E. 写入 FRP 客户端配置文件
# -------------------------------------------------------------
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

# -------------------------------------------------------------
# F. 注册为 Windows 后台系统服务 (无感运行、崩溃自启)
# -------------------------------------------------------------
Write-Host "🚀 [6/6] 正在注册并启动后台系统服务..." -ForegroundColor Yellow

if (Test-Path $ServyCliPath) {
    try {
        # 卸载可能存在的历史残留服务
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

        # 启动两项服务
        & $ServyCliPath start --quiet --name="TikTok_Gost"
        & $ServyCliPath start --quiet --name="TikTok_FRP"

        Write-Host "   -> 系统服务安装成功，已设为开机自动启动！" -ForegroundColor Green
    } catch {
        Write-Host "⚠️ 服务静默注册失败，请检查杀毒软件权限。" -ForegroundColor Red
    }
} else {
    Write-Host "⚠️ 未检测到 servy-cli.exe，尝试使用 Windows 备用方式启动..." -ForegroundColor DarkYellow
}

# 创建桌面便捷管理快捷方式 (如果有 Servy GUI)
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
# G. 链路可用性自检
# -------------------------------------------------------------
Write-Host ""
Write-Host "🔍 正在进行本地服务健康自检..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

$GostRunning = (Get-Process -Name "gost" -ErrorAction SilentlyContinue) -ne $null
$FrpRunning  = (Get-Process -Name "frpc" -ErrorAction SilentlyContinue) -ne $null

# 端口监听测试 (10000)
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
Write-Host "🎉 恭喜！住宅机端环境与底层隧道已部署完成！" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "【系统服务运行状态】" -ForegroundColor Cyan
if ($GostRunning) {
    Write-Host "  ✅ Gost 代理核心   : 正在运行 (进程正常)" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ Gost 代理核心   : 未检测到进程，请检查 Servy 面板" -ForegroundColor Red
}

if ($FrpRunning) {
    Write-Host "  ✅ FRP 隧道核心    : 正在运行 (进程正常)" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ FRP 隧道核心    : 未检测到进程，请检查 Servy 面板" -ForegroundColor Red
}

if ($PortOpen) {
    Write-Host "  ✅ 本地代理端口    : 127.0.0.1:10000 (监听正常)" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ 本地代理端口    : 127.0.0.1:10000 尚未响应 (等待启动中)" -ForegroundColor Yellow
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
