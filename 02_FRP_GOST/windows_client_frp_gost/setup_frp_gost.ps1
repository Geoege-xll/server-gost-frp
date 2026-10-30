# ==============================================================
# TikTok 住宅机端 - FRP + GOST 离线部署 (Windows PowerShell 5.1)
# ==============================================================
$ErrorActionPreference = 'Stop'
$CurrentDir = $PSScriptRoot
$ToolsDir = 'C:\Tools\TikTokFrpGost'
$CertsDir = "$ToolsDir\certs"
$LogsDir = "$ToolsDir\logs"
$ServyDir = "$ToolsDir\servy"
$ServiceNames = @('TikTok_FRPGost', 'TikTok_FRP')

# 占位符变量（由 VPS 生成离线包时注入）
$VpsServerIp = "VPS_PUBLIC_IP_PLACEHOLDER"
$AuthToken = "TOKEN_PLACEHOLDER"
$GostUser = "GOST_USER_PLACEHOLDER"
$GostPass = "GOST_PASS_PLACEHOLDER"

function Find-ServyCli([string]$Directory) {
    $Files = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter 'servy-cli.exe')
    if ($Files.Count -ne 1) { throw "需要完整 servy 目录，且其中必须恰好有一个 servy-cli.exe：$Directory" }
    if ($Files[0].Length -eq 0) { throw "servy-cli.exe 文件为空：$Directory" }
    return $Files[0].FullName
}

function Assert-OwnedService([string]$Name, [string]$Cli) {
    if ($null -eq (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { return }
    # Servy 10.7 的 SCM 路径是共享 wrapper，须检查官方导出的真实程序配置。
    $ExportPath = Join-Path ([IO.Path]::GetTempPath()) ("TikTok-service-" + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        & $Cli export --quiet --name=$Name --config=json --path=$ExportPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "无法确认 $Name 的 Servy 配置归属，退出码 $LASTEXITCODE。请先使用对应旧版卸载方式处理。" }
        $Config = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($ExportPath))
        $Program = if ($Name -eq 'TikTok_FRP') { 'frpc.exe' } else { 'gost.exe' }
        if ($Config.Name -ine $Name -or [IO.Path]::GetFullPath($Config.ExecutablePath) -ine "$ToolsDir\$Program" -or [IO.Path]::GetFullPath($Config.StartupDirectory).TrimEnd('\') -ine $ToolsDir) {
            throw "服务 $Name 不属于 $ToolsDir（可能是旧版共享安装）。请先用对应旧版卸载方式处理；本脚本不会改动它。"
        }
    } finally {
        if (Test-Path -LiteralPath $ExportPath) { Remove-Item -LiteralPath $ExportPath -Force }
    }
}

function Assert-LocalGateway([bool]$Required) {
    $Connections = @(Get-NetTCPConnection -State Listen -LocalPort 10000 -ErrorAction SilentlyContinue)
    if ($Required -and $Connections.Count -eq 0) { throw '本方案本地 SOCKS5 端口 10000 尚未监听，请检查日志后重试。' }
    foreach ($Connection in $Connections) {
        $ProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$($Connection.OwningProcess)"
        if ($null -eq $ProcessInfo -or $ProcessInfo.ExecutablePath -ine "$ToolsDir\gost.exe") {
            throw '本地端口 10000 被其他程序或方案占用。请先停止/卸载对应程序；本脚本不会终止它。'
        }
    }
}

function Install-TunnelService([string]$Name, [string]$DisplayName, [string]$Program, [string]$Parameters, [string]$LogName) {
    # Servy 官方：恢复参数只在 enableHealth 时生效；0 表示无限重试。
    & $ServyCliPath install --quiet --name=$Name --displayName=$DisplayName `
        --description='TikTok FRP and GOST residential client' `
        --path="$ToolsDir\$Program" --startupDir=$ToolsDir --params=$Parameters `
        --startupType=Automatic --enableHealth --heartbeatInterval=10 --maxFailedChecks=3 `
        --recoveryAction=RestartService --maxRestartAttempts=0 `
        --stdout="$LogsDir\$LogName.log" --stderr="$LogsDir\${LogName}_err.log" `
        --enableSizeRotation --rotationSize=10 --maxRotations=5
    if ($LASTEXITCODE -ne 0) { throw "Servy 安装 $Name 失败，退出码 $LASTEXITCODE。" }
    & $ServyCliPath start --quiet --name=$Name
    if ($LASTEXITCODE -ne 0) { throw "Servy 启动 $Name 失败，退出码 $LASTEXITCODE。" }
    $Service = Get-Service -Name $Name
    $Service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
}

try {
    # 只读预检：任何占位符或离线文件缺失都在系统变更之前拒绝。
    foreach ($Value in @($VpsServerIp, $AuthToken, $GostUser, $GostPass)) {
        if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match 'PLACEHOLDER') { throw '配置尚未注入，请使用 VPS 生成的完整离线包。' }
    }
    $ParsedIp = $null
    if (![Net.IPAddress]::TryParse($VpsServerIp, [ref]$ParsedIp) -or $ParsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'VPS 地址必须是服务器证书 IP SAN 中的公网 IPv4 地址。'
    }
    foreach ($Name in @('gost.exe', 'frpc.exe', 'ca.crt', 'client.crt', 'client.key')) {
        $File = Get-Item -LiteralPath (Join-Path $CurrentDir $Name)
        if ($File.PSIsContainer -or $File.Length -eq 0) { throw "离线包文件无效：$Name" }
    }
    $SourceServyDir = Join-Path $CurrentDir 'servy'
    $SourceCli = Find-ServyCli $SourceServyDir
    if ([IO.Path]::GetFullPath($CurrentDir).TrimEnd('\').StartsWith($ToolsDir, [StringComparison]::OrdinalIgnoreCase)) {
        throw '请将离线包解压到运行目录之外，再执行安装。'
    }
    if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $Child = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -Wait -PassThru
        exit $Child.ExitCode
    }
    foreach ($Directory in @('C:\Tools', $ToolsDir, $CertsDir, $LogsDir, $ServyDir)) {
        if ((Test-Path -LiteralPath $Directory) -and ((Get-Item -LiteralPath $Directory).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "拒绝使用链接目录：$Directory" }
    }
    if ($null -ne (Get-Service -Name 'TikTok_Gost' -ErrorAction SilentlyContinue)) {
        throw '检测到旧版共享服务 TikTok_Gost。请先使用对应旧版卸载方式处理；不会修改或删除旧 C:\Tools 共享安装。'
    }
    $OtherServyServices = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -notin $ServiceNames -and $_.PathName -match 'Servy\.Service(?:\.CLI)?\.exe' })
    if ($OtherServyServices.Count -gt 0) { throw "检测到其他 Servy 托管服务：$($OtherServyServices.Name -join ', ')。Servy 10.7 共享运行时可能影响它们，请先处理对应安装。" }
    foreach ($Name in $ServiceNames) { Assert-OwnedService $Name $SourceCli }
    Assert-LocalGateway $false

    Write-Host '[1/5] 停止并注销本方案已有服务（先全部停止，再复制程序）...' -ForegroundColor Cyan
    foreach ($Name in @('TikTok_FRP', 'TikTok_FRPGost')) {
        $Existing = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $Existing) {
            if ($Existing.Status -ne 'Stopped') { Stop-Service -Name $Name; $Existing.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) }
            & $SourceCli uninstall --quiet --name=$Name
            if ($LASTEXITCODE -ne 0) { throw "Servy 卸载 $Name 失败，退出码 $LASTEXITCODE。" }
            for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
                if ($null -eq (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { break }
                Start-Sleep -Seconds 1
            }
            if ($null -ne (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { throw "$Name 尚未删除，请关闭服务管理窗口后重试。" }
        }
    }

    for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
        $Remaining = @(Get-CimInstance Win32_Process -Filter "Name='gost.exe' OR Name='frpc.exe'" | Where-Object { $_.ExecutablePath -in @("$ToolsDir\gost.exe", "$ToolsDir\frpc.exe") })
        if ($Remaining.Count -eq 0) { break }
        if ($Attempt -eq 29) { throw '本方案 gost.exe/frpc.exe 尚未退出；请关闭本方案手动运行的进程后重试，不会强制杀进程。' }
        Start-Sleep -Seconds 1
    }
    Write-Host '[2/5] 复制离线程序、证书和完整 Servy 目录...' -ForegroundColor Cyan
    # 只替换本方案 Servy 树，避免发行包顶层目录名变化留下多个 CLI。
    if (Test-Path -LiteralPath $ServyDir) { Remove-Item -LiteralPath $ServyDir -Recurse -Force }
    New-Item -Path $ToolsDir, $CertsDir, $LogsDir, $ServyDir -ItemType Directory -Force | Out-Null
    foreach ($Name in @('gost.exe', 'frpc.exe')) { Copy-Item -LiteralPath (Join-Path $CurrentDir $Name) -Destination $ToolsDir -Force }
    foreach ($Name in @('ca.crt', 'client.crt', 'client.key')) { Copy-Item -LiteralPath (Join-Path $CurrentDir $Name) -Destination $CertsDir -Force }
    Get-ChildItem -LiteralPath $SourceServyDir -Force | Copy-Item -Destination $ServyDir -Recurse -Force
    $ServyCliPath = Find-ServyCli $ServyDir

    Write-Host '[3/5] 写入 GOST 和 FRP 配置...' -ForegroundColor Cyan
    $GostUserYaml = ConvertTo-Json -InputObject $GostUser -Compress
    $GostPassYaml = ConvertTo-Json -InputObject $GostPass -Compress
    $GostYaml = @"
services:
  - name: local-socks5
    addr: "127.0.0.1:10000"
    handler:
      type: socks5
      auth:
        username: $GostUserYaml
        password: $GostPassYaml
    listener:
      type: tcp
"@
    # TOML basic string 与 JSON 的字符串转义兼容。
    $AuthTokenToml = ConvertTo-Json -InputObject $AuthToken -Compress
    $FrpcConfig = @"
serverAddr = "$VpsServerIp"
serverPort = 9000
transport.protocol = "tcp"
transport.wireProtocol = "v2"
transport.tls.enable = true
transport.tls.serverName = "$VpsServerIp"
transport.tls.certFile = "C:/Tools/TikTokFrpGost/certs/client.crt"
transport.tls.keyFile = "C:/Tools/TikTokFrpGost/certs/client.key"
transport.tls.trustedCaFile = "C:/Tools/TikTokFrpGost/certs/ca.crt"
transport.heartbeatInterval = 15
transport.heartbeatTimeout = 90
transport.tcpMux = true
auth.method = "token"
auth.token = $AuthTokenToml
loginFailExit = false

# TCP 映射的绑定地址由 frps 的 proxyBindAddr 控制，服务端必须为 127.0.0.1。
[[proxies]]
name = "jp_socks5"
type = "tcp"
localIP = "127.0.0.1"
localPort = 10000
remotePort = 10001
# 全局 TLS 已加密，不重复做 payload 加密；视频流不再压缩。
transport.useEncryption = false
transport.useCompression = false

[[proxies]]
name = "jp_rdp"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3389
remotePort = 33389
transport.useEncryption = false
transport.useCompression = false
"@
    [IO.File]::WriteAllText("$ToolsDir\gost.yaml", $GostYaml, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText("$ToolsDir\frpc.toml", $FrpcConfig, (New-Object Text.UTF8Encoding($false)))
    $SocksInfoPath = Join-Path $ToolsDir 'SOCKS5账号密码.txt'
    $SocksInfo = @"
SOCKS5 连接信息（FRP + GOST）
配套 VPS：$VpsServerIp
住宅机本地地址：127.0.0.1:10000
VPS 上的 S-UI 出站地址：127.0.0.1:10001（VPS 回环地址，不对公网开放）
账号：$GostUser
密码：$GostPass

账号密码与本次写入的 gost.yaml 一致；住宅机不会重新生成账号密码。
本文件含明文密码，请妥善保管，勿上传公开仓库或转发。
保存此文件不代表隧道已连通；请另行完成链路验收。
"@
    [IO.File]::WriteAllText($SocksInfoPath, ($SocksInfo -replace '\r?\n', "`r`n"), (New-Object Text.UTF8Encoding($true)))
    Write-Host "SOCKS5 账号密码已保存：$SocksInfoPath（明文文件，请妥善保管）"
    & "$ToolsDir\frpc.exe" verify -c "$ToolsDir\frpc.toml"
    if ($LASTEXITCODE -ne 0) { throw "frpc 配置检查失败，退出码 $LASTEXITCODE。" }

    Write-Host '[4/5] 安装并启动本方案服务...' -ForegroundColor Cyan
    Install-TunnelService 'TikTok_FRPGost' 'TikTok FRP GOST SOCKS5 Gateway' 'gost.exe' "-C `"$ToolsDir\gost.yaml`"" 'gost'
    Install-TunnelService 'TikTok_FRP' 'TikTok FRP Reverse Tunnel' 'frpc.exe' "-c `"$ToolsDir\frpc.toml`"" 'frpc'
    Start-Sleep -Seconds 2
    foreach ($Name in $ServiceNames) {
        if ((Get-Service -Name $Name).Status -ne 'Running') { throw "$Name 当前未运行。" }
    }
    Assert-LocalGateway $true

    Write-Host '[5/5] 设置接通电源时防睡眠...' -ForegroundColor Cyan
    $PowerOk = $true
    foreach ($Setting in @('standby-timeout-ac', 'hibernate-timeout-ac')) {
        & powercfg.exe /change $Setting 0
        if ($LASTEXITCODE -ne 0) { $PowerOk = $false; Write-Warning "电源设置 $Setting 失败，退出码 $LASTEXITCODE，请手动配置。" }
    }
    if ($PowerOk) { Write-Host '已设置接通电源时不自动睡眠/休眠（不保证网络持续可用）。' -ForegroundColor Green }

    try {
        $Gui = @(Get-ChildItem -LiteralPath $ServyDir -Recurse -File -Filter 'Servy.exe')
        if ($Gui.Count -eq 1) {
            $Shell = New-Object -ComObject WScript.Shell
            $Shortcut = $Shell.CreateShortcut("$([Environment]::GetFolderPath('Desktop'))\TikTok FRP GOST服务监控.lnk")
            $Shortcut.TargetPath = $Gui[0].FullName
            $Shortcut.WorkingDirectory = $Gui[0].DirectoryName
            $Shortcut.Save()
        }
    } catch { Write-Warning "可选的桌面快捷方式创建失败：$($_.Exception.Message)" }
    Write-Host '本地检查通过：TikTok_FRPGost、TikTok_FRP 为 Running，本方案 SOCKS5 端口 10000 已监听。' -ForegroundColor Green
    Write-Host "运行目录：$ToolsDir；日志：$LogsDir"
    Write-Host '以上不证明 TLS、VPS 远端映射或端到端连通。请检查两端日志并单独验证。'
    Write-Host '服务端须设置 proxyBindAddr = "127.0.0.1"，仅在 VPS 回环开放 10001/33389；RDP 经 SSH/受控通道访问，不直连公网。'
    Write-Host '未添加 Defender 排除项，也未修改旧 C:\Tools 共享文件。'
    exit 0
} catch {
    Write-Host "安装失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "不会宣称部署成功。若已部分安装，请检查 $LogsDir 或运行本方案卸载脚本。"
    exit 1
}
