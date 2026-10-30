# ==============================================================
# TikTok 住宅机端 - 仅卸载 FRP + GOST 独立安装
# ==============================================================
$ErrorActionPreference = 'Stop'
$ToolsDir = 'C:\Tools\TikTokFrpGost'
$ServiceNames = @('TikTok_FRP', 'TikTok_FRPGost')
$ShortcutName = 'TikTok FRP GOST服务监控.lnk'

function Assert-OwnedService([string]$Name, [string]$Cli) {
    if ($null -eq (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { return }
    if ([string]::IsNullOrWhiteSpace($Cli)) { throw '无法确认服务归属：缺少本方案 servy-cli.exe，请恢复完整离线包后重试。' }
    # Servy 10.7 的 SCM 路径是共享 wrapper，不能据此判断真实程序归属。
    $ExportPath = Join-Path ([IO.Path]::GetTempPath()) ("TikTok-service-" + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        & $Cli export --quiet --name=$Name --config=json --path=$ExportPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "无法确认 $Name 的 Servy 配置归属，退出码 $LASTEXITCODE。请使用对应旧版卸载方式处理。" }
        $Config = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($ExportPath))
        $Program = if ($Name -eq 'TikTok_FRP') { 'frpc.exe' } else { 'gost.exe' }
        if ($Config.Name -ine $Name -or [IO.Path]::GetFullPath($Config.ExecutablePath) -ine "$ToolsDir\$Program" -or [IO.Path]::GetFullPath($Config.StartupDirectory).TrimEnd('\') -ine $ToolsDir) {
            throw "服务 $Name 不属于 $ToolsDir。请使用对应旧版卸载方式处理；本脚本拒绝改动它。"
        }
    } finally {
        if (Test-Path -LiteralPath $ExportPath) { Remove-Item -LiteralPath $ExportPath -Force }
    }
}

try {
    if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $Child = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -Wait -PassThru
        exit $Child.ExitCode
    }
    foreach ($Directory in @('C:\Tools', $ToolsDir)) {
        if ((Test-Path -LiteralPath $Directory) -and ((Get-Item -LiteralPath $Directory).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "拒绝操作链接目录：$Directory" }
    }
    if ($null -ne (Get-Service -Name 'TikTok_Gost' -ErrorAction SilentlyContinue)) {
        throw '检测到旧版共享服务 TikTok_Gost。请使用对应旧版卸载方式处理；本脚本不修改它，也不会删除旧 C:\Tools 共享安装。'
    }
    $OtherServyServices = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -notin $ServiceNames -and $_.PathName -match 'Servy\.Service(?:\.CLI)?\.exe' })
    if ($OtherServyServices.Count -gt 0) { throw "检测到其他 Servy 托管服务：$($OtherServyServices.Name -join ', ')。Servy 10.7 共享运行时可能影响它们，请先处理对应安装。" }
    $ServyCli = $null
    foreach ($Directory in @("$ToolsDir\servy", (Join-Path $PSScriptRoot 'servy'))) {
        if (Test-Path -LiteralPath $Directory) {
            $Files = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter 'servy-cli.exe')
            if ($Files.Count -gt 1) { throw "存在多个 servy-cli.exe，无法安全选择：$Directory" }
            if ($Files.Count -eq 1) { $ServyCli = $Files[0].FullName; break }
        }
    }
    # 先确认全部服务归属，再执行停止/注销操作。
    foreach ($Name in $ServiceNames) { Assert-OwnedService $Name $ServyCli }
    foreach ($Name in $ServiceNames) {
        $Service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $Service) { Write-Host "$Name 未安装，跳过。"; continue }
        if ($Service.Status -ne 'Stopped') { Stop-Service -Name $Name; $Service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) }
        & $ServyCli uninstall --quiet --name=$Name
        if ($LASTEXITCODE -ne 0) { throw "注销 $Name 失败，退出码 $LASTEXITCODE。" }
        for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
            if ($null -eq (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Seconds 1
        }
        if ($null -ne (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { throw "$Name 尚未删除，请关闭服务管理窗口后重试。" }
        Write-Host "已停止并注销 $Name。" -ForegroundColor Green
    }
    for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
        $Remaining = @(Get-CimInstance Win32_Process -Filter "Name='gost.exe' OR Name='frpc.exe'" | Where-Object { $_.ExecutablePath -in @("$ToolsDir\gost.exe", "$ToolsDir\frpc.exe") })
        if ($Remaining.Count -eq 0) { break }
        if ($Attempt -eq 29) { throw '本方案 gost.exe/frpc.exe 尚未退出，保留运行目录；请关闭本方案手动运行的进程后重试。' }
        Start-Sleep -Seconds 1
    }
    $ShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName
    if (Test-Path -LiteralPath $ShortcutPath) {
        $Shell = New-Object -ComObject WScript.Shell
        $Shortcut = $Shell.CreateShortcut($ShortcutPath)
        if ($Shortcut.TargetPath.StartsWith("$ToolsDir\", [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $ShortcutPath -Force }
    }
    if (Test-Path -LiteralPath $ToolsDir) {
        $Confirm = Read-Host "是否删除本方案目录 $ToolsDir（含证书、配置、日志和 SOCKS5账号密码.txt，请先备份所需凭据）？(y/N)"
        if ($Confirm -ieq 'y') {
            Remove-Item -LiteralPath $ToolsDir -Recurse -Force
            Write-Host "已删除 $ToolsDir。" -ForegroundColor Green
        } else { Write-Host "已保留 $ToolsDir。" }
    }
    Write-Host '本方案卸载完成；未按进程名杀进程，未删除 C:\Tools 共享目录，未主动管理其他方案服务。' -ForegroundColor Green
    Write-Host 'Servy 官方共享 host/ProgramData 数据与电源策略保留，不执行全局清理。'
    exit 0
} catch {
    Write-Host "卸载未完成：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '不会终止其他程序或强制删除共享目录；若文件占用，请先关闭本方案 Servy 界面后重试。'
    exit 1
}
