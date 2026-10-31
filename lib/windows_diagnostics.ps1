# Read-only Windows package diagnostics. Never runs an installer or downloaded code.
param([switch]$Pause)

$ErrorActionPreference = 'Stop'
$Failed = $false
$CanParse = $true

try {
    Write-Host 'Residential Tunnel - read-only package diagnostics'
    Write-Host 'No downloads, elevation, service changes or credential output.'
    Write-Host ('PowerShell: {0}; edition: {1}; 64-bit process: {2}; architecture: {3}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [Environment]::Is64BitProcess, $env:PROCESSOR_ARCHITECTURE)
    $EditionOk = ($PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion -ge [version]'5.1') -or
        ($PSVersionTable.PSEdition -ceq 'Core' -and $PSVersionTable.PSVersion -ge [version]'7.0')
    if (!$EditionOk -or
        ![Environment]::Is64BitOperatingSystem -or ![Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ine 'AMD64') {
        Write-Host 'FAIL: use 64-bit Windows PowerShell 5.1 or PowerShell 7 on x64 Windows.' -ForegroundColor Red
        $Failed = $true
    }
    $Candidates = @('setup_gost_v3.ps1', 'setup_frp_gost.ps1')
    $Setups = @($Candidates | Where-Object { Test-Path -LiteralPath (Join-Path $PSScriptRoot $_) -PathType Leaf })
    if ($Setups.Count -ne 1) { throw 'Extract one complete scheme folder. Exactly one setup script is required.' }
    $Scheme = if ($Setups[0] -eq 'setup_gost_v3.ps1') { 'gost' } else { 'frp' }
    $Uninstall = if ($Scheme -eq 'gost') { 'uninstall_gost_v3.ps1' } else { 'uninstall_frp_gost.ps1' }
    foreach ($Name in @($Setups[0], $Uninstall, 'windows_components.ps1', 'diagnose_windows.ps1')) {
        $Path = Join-Path $PSScriptRoot $Name
        if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-Host "FAIL: missing file: $Name" -ForegroundColor Red
            $Failed = $true
            $CanParse = $false
            continue
        }
        $Tokens = $null
        $ParseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors) | Out-Null
        if (@($ParseErrors).Count -gt 0) {
            $Failed = $true
            $CanParse = $false
            foreach ($Problem in $ParseErrors) {
                # Do not print source excerpts: setup scripts contain injected credentials.
                Write-Host ('FAIL: {0}, line {1}, column {2}, error ID: {3}' -f $Name, $Problem.Extent.StartLineNumber, $Problem.Extent.StartColumnNumber, $Problem.ErrorId) -ForegroundColor Red
            }
        } else { Write-Host "PASS: PowerShell syntax: $Name" -ForegroundColor Green }
    }
    foreach ($Name in @('ca.crt', 'client.crt', 'client.key', 'components.json')) {
        $File = Get-Item -LiteralPath (Join-Path $PSScriptRoot $Name) -Force -ErrorAction SilentlyContinue
        if ($null -eq $File -or $File.PSIsContainer -or $File.Length -eq 0 -or
            ($File.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Device))) {
            Write-Host "FAIL: missing, empty or unsafe package file: $Name" -ForegroundColor Red
            $Failed = $true
        } else { Write-Host "PASS: package file present: $Name" -ForegroundColor Green }
    }
    if ($CanParse) {
        # The shared helper defines functions only. This validator reads local files;
        # it does not prepare/download components or execute component binaries.
        . (Join-Path $PSScriptRoot 'windows_components.ps1')
        try {
            $Manifest = Assert-ClientComponentManifest -PackageDir $PSScriptRoot -Scheme $Scheme
            Write-Host ('PASS: component manifest; scheme: {0}; mode: {1}; pinned tunnel: {2}' -f $Manifest.scheme, $Manifest.mode, $Manifest.tunnelVersion) -ForegroundColor Green
        } catch {
            Write-Host ('FAIL: component preflight: {0}' -f $_.Exception.Message) -ForegroundColor Red
            $Failed = $true
        }
    }
    $Connections = @(Get-NetTCPConnection -State Listen -LocalPort 10000 -ErrorAction SilentlyContinue)
    if ($Connections.Count -gt 0) {
        Write-Host 'NOTE: local port 10000 is occupied; ownership must be checked before installation.' -ForegroundColor Yellow
    } else { Write-Host 'NOTE: no visible listener on local port 10000.' }
    if ($Failed) {
        Write-Host 'RESULT: local preflight failed. Do not run setup yet.' -ForegroundColor Red
    } else {
        Write-Host 'RESULT: read-only local preflight passed; installation, ACL, TLS and connectivity are NOT verified.' -ForegroundColor Green
    }
} catch {
    Write-Host ('FAIL: diagnostics: {0}' -f $_.Exception.Message) -ForegroundColor Red
    $Failed = $true
} finally {
    if ($Pause) {
        try { Read-Host 'Press Enter after reading the diagnostic output' | Out-Null } catch { }
    }
}
if ($Failed) { exit 1 }
exit 0
