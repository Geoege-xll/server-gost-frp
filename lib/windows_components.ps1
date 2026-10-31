# Windows PowerShell 5.1 / PowerShell 7 offline-package component validation; copied to the package root.
# Components ship inside the package; nothing is downloaded and no executable from
# PATH or an existing installation is used.
# On modern .NET the file-system ACL types (DirectorySecurity, and the
# System.IO.FileSystemAclExtensions static class) live in the
# System.IO.FileSystem.AccessControl assembly; PS 5.1 has them in mscorlib and
# no FileSystemAclExtensions at all. Explicit framework load; no compilation.
if ($PSVersionTable.PSEdition -ceq 'Core') { Add-Type -AssemblyName System.IO.FileSystem.AccessControl }

function Assert-ClientPlainPath([string]$Path) {
    $Current = [IO.Path]::GetFullPath($Path)
    while ($Current) {
        $Item = Get-Item -LiteralPath $Current -Force -ErrorAction Stop
        if ($Item.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Device)) {
            throw "拒绝使用链接或特殊文件：$Current"
        }
        $Parent = [IO.Directory]::GetParent($Current)
        $Current = if ($null -eq $Parent) { $null } else { $Parent.FullName }
    }
}

function Get-ClientPlainTree([string]$Directory) {
    Assert-ClientPlainPath $Directory
    if (!(Get-Item -LiteralPath $Directory -Force -ErrorAction Stop).PSIsContainer) { throw "不是目录：$Directory" }
    $Pending = New-Object 'Collections.Generic.Stack[string]'
    $Pending.Push($Directory)
    while ($Pending.Count -gt 0) {
        foreach ($Item in @(Get-ChildItem -LiteralPath ($Pending.Pop()) -Force -ErrorAction Stop)) {
            if ($Item.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Device)) {
                throw "组件目录中不允许链接或特殊文件：$($Item.FullName)"
            }
            $Item
            if ($Item.PSIsContainer) { $Pending.Push($Item.FullName) }
        }
    }
}

function Get-ClientSingleExecutable([object[]]$Items, [string]$Name) {
    $Files = @($Items | Where-Object { !$_.PSIsContainer -and $_.Name -ieq $Name })
    if ($Files.Count -ne 1 -or $Files[0].Length -eq 0) { throw "组件中必须恰好有一个非空 $Name。" }
    return $Files[0].FullName
}

function Assert-ClientComponentSource([string]$Root, [string]$Scheme) {
    Assert-ClientPlainPath $Root
    $Names = @('gost.exe')
    if ($Scheme -ceq 'frp') { $Names += 'frpc.exe' }
    foreach ($Name in $Names) {
        $Path = Join-Path $Root $Name
        Assert-ClientPlainPath $Path
        $File = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($File.PSIsContainer -or $File.Length -eq 0) { throw "组件文件无效：$Path" }
    }
    $ServyFiles = @(Get-ClientPlainTree (Join-Path $Root 'servy'))
    Get-ClientSingleExecutable $ServyFiles 'Servy.exe' | Out-Null
    Get-ClientSingleExecutable $ServyFiles 'servy-cli.exe' | Out-Null
}

function Assert-ClientJsonObject($Value, [string[]]$Properties) {
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) { throw 'components.json 对象格式无效。' }
    $Actual = @($Value.PSObject.Properties.Name)
    if ($Actual.Count -ne $Properties.Count) { throw 'components.json 字段数量无效。' }
    foreach ($Name in $Actual) {
        if ($Properties -cnotcontains $Name) { throw "components.json 含未知或大小写错误字段：$Name" }
    }
}

function Get-ClientNumericVersion([string]$Tag) {
    if ($Tag -cnotmatch '^v?[0-9]+\.[0-9]+(?:\.[0-9]+)?$') { throw "不支持的稳定版本：$Tag" }
    $Number = $Tag -creplace '^v', ''
    if ($Number.Split('.').Count -eq 2) { $Number += '.0' }
    return [version]$Number
}

function Assert-ClientComponentManifest([string]$PackageDir, [ValidateSet('gost', 'frp')][string]$Scheme) {
    $ErrorActionPreference = 'Stop'
    $EditionOk = ($PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion -ge [version]'5.1') -or
        ($PSVersionTable.PSEdition -ceq 'Core' -and $PSVersionTable.PSVersion -ge [version]'7.0')
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        ![Environment]::Is64BitOperatingSystem -or ![Environment]::Is64BitProcess -or
        $env:PROCESSOR_ARCHITECTURE -ine 'AMD64' -or !$EditionOk) {
        throw '请在 x64 Windows 上使用 64 位 Windows PowerShell 5.1 或 PowerShell 7 运行安装脚本。'
    }
    $ManifestPath = Join-Path $PackageDir 'components.json'
    Assert-ClientPlainPath $ManifestPath
    $File = Get-Item -LiteralPath $ManifestPath -Force
    if ($File.PSIsContainer -or $File.Length -eq 0 -or $File.Length -gt 65536) { throw 'components.json 缺失、为空或过大。' }
    $Json = [IO.File]::ReadAllText($ManifestPath).Trim()
    $StringToken = '"(?:[^"\\\x00-\x1f]|\\.)*"'
    $Structure = [regex]::Replace($Json, $StringToken, '""')
    if (!$Json.StartsWith('{') -or !$Json.EndsWith('}') -or $Structure -match '/|,\s*[}\]]') {
        throw 'components.json 必须是严格 JSON 对象，不能包含注释或尾随逗号。'
    }
    $Manifest = ConvertFrom-Json -InputObject $Json
    $RootFields = @('schemaVersion', 'mode', 'scheme', 'architecture', 'tunnelVersion', 'components')
    $ComponentFields = @('id', 'repo', 'version', 'asset', 'url', 'sha256')
    Assert-ClientJsonObject $Manifest $RootFields
    if (($Manifest.schemaVersion -isnot [int] -and $Manifest.schemaVersion -isnot [long]) -or $Manifest.schemaVersion -ne 1 -or
        $Manifest.mode -isnot [string] -or $Manifest.mode -cne 'offline' -or
        $Manifest.scheme -isnot [string] -or $Manifest.scheme -cne $Scheme -or
        $Manifest.architecture -isnot [string] -or $Manifest.architecture -cne 'amd64' -or
        $Manifest.tunnelVersion -isnot [string] -or $Manifest.components -isnot [array]) {
        throw 'components.json 的架构、方案或版本格式无效；此安装脚本仅支持离线完整包。'
    }
    Get-ClientNumericVersion $Manifest.tunnelVersion | Out-Null
    $Expected = @('gost', 'servy')
    if ($Scheme -ceq 'frp') { $Expected += 'frpc' }
    if ($Manifest.components.Count -ne $Expected.Count) { throw 'components.json 的组件集合不完整或含额外组件。' }
    $Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($Component in $Manifest.components) {
        Assert-ClientJsonObject $Component $ComponentFields
        foreach ($Field in @('id', 'repo', 'version', 'asset', 'url', 'sha256')) {
            if ($Component.$Field -isnot [string]) { throw "组件字段必须是字符串：$Field" }
        }
        if ($Expected -cnotcontains $Component.id -or !$Seen.Add($Component.id)) { throw '组件 ID 未知或重复。' }
        $Version = Get-ClientNumericVersion $Component.version
        $Number = $Component.version -creplace '^v', ''
        switch -CaseSensitive ($Component.id) {
            'gost' { $Repo = 'go-gost/gost'; $Asset = "gost_${Number}_windows_amd64.zip"; $Minimum = [version]'3.3.2' }
            'frpc' { $Repo = 'fatedier/frp'; $Asset = "frp_${Number}_windows_amd64.zip"; $Minimum = [version]'0.71.1' }
            'servy' { $Repo = 'aelassas/servy'; $Asset = "servy-${Number}-net48-x64-portable.7z"; $Minimum = [version]'10.7.0' }
        }
        $Url = "https://github.com/$Repo/releases/download/$($Component.version)/$Asset"
        if ($Version -lt $Minimum -or $Component.repo -cne $Repo -or $Component.asset -cne $Asset -or
            $Component.url -cne $Url -or $Component.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "组件版本、官方仓库、资产名、URL 或 SHA-256 无效：$($Component.id)"
        }
        if (($Component.id -ceq 'frpc' -or ($Scheme -ceq 'gost' -and $Component.id -ceq 'gost')) -and
            $Component.version -cne $Manifest.tunnelVersion) { throw '隧道客户端版本必须与 tunnelVersion 完全一致。' }
    }
    # ConvertFrom-Json may overwrite duplicate keys. Count decoded property names as well.
    # All accepted values above are constrained strings, so none can masquerade as a property token.
    $KeyCounts = @{}
    foreach ($Token in [regex]::Matches($Json, ($StringToken + '\s*:'))) {
        $KeyObject = ConvertFrom-Json -InputObject ('{' + $Token.Value + 'null}')
        $Key = @($KeyObject.PSObject.Properties.Name)[0]
        $Limit = if ($RootFields -ccontains $Key) { 1 } elseif ($ComponentFields -ccontains $Key) { $Expected.Count } else { 0 }
        if (!$KeyCounts.ContainsKey($Key)) { $KeyCounts[$Key] = 0 }
        $KeyCounts[$Key]++
        if ($KeyCounts[$Key] -gt $Limit) { throw "components.json 含重复或未知字段：$Key" }
    }
    # Offline-only: the package must already contain the verified components.
    Assert-ClientComponentSource $PackageDir $Scheme
    return $Manifest
}

function New-ClientPrivateAcl([bool]$Directory) {
    $Acl = if ($Directory) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $Acl.SetAccessRuleProtection($true, $false)
    $User = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $Acl.SetOwner($User)
    $Inheritance = [Security.AccessControl.InheritanceFlags]::None
    if ($Directory) { $Inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit }
    foreach ($Sid in @($User, [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'), [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $Rule = [Security.AccessControl.FileSystemAccessRule]::new($Sid, [Security.AccessControl.FileSystemRights]::FullControl,
            $Inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $Acl.AddAccessRule($Rule)
    }
    return $Acl
}

function Get-ClientRuntimeItem([string]$Path) {
    try { return Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { return $null }
}

function Assert-ClientRuntimeAcl([string]$Path, [switch]$Ancestor) {
    Assert-ClientPlainPath $Path
    $Acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $Trusted = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-32-544', 'S-1-5-18',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464') # TrustedInstaller may own system ancestors.
    if ($Trusted -cnotcontains $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) {
        throw "运行路径由不可信账户持有；不会接管或修改权限：$Path"
    }
    $Descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Acl.GetSecurityDescriptorBinaryForm(), 0)
    if ($null -eq $Descriptor.DiscretionaryAcl -or !$Acl.AreAccessRulesCanonical) { throw "运行路径 DACL 缺失或无法安全判定：$Path" }
    $Risk = [long]([Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership)
    # Creating unrelated sibling directories on an ancestor (the normal C:\ permission)
    # cannot replace an existing protected child. New paths are owner/ACL checked after creation.
    if (!$Ancestor) { $Risk = $Risk -bor [long][Security.AccessControl.FileSystemRights]::AppendData }
    $Risk = $Risk -bor 0x10000000 -bor 0x40000000 # GENERIC_ALL / GENERIC_WRITE
    foreach ($Ace in $Descriptor.DiscretionaryAcl) {
        if ($Ace -isnot [Security.AccessControl.CommonAce] -or $Ace.AceType -notin @(
                [Security.AccessControl.AceType]::AccessAllowed, [Security.AccessControl.AceType]::AccessDenied)) {
            throw "运行路径包含不支持的 DACL 条目；不会修改：$Path"
        }
        # Inherit-only entries do not grant access to this object. Existing descendants
        # are checked separately; newly created private directories never inherit them.
        # Enum.HasFlag is a plain CLR call: PS 5.1 -band converts enum operands and
        # throws InvalidCastException for AceFlags (reproduced on Win11).
        if ($Ace.AceFlags.HasFlag([Security.AccessControl.AceFlags]::InheritOnly) -or
            $Ace.AceType -eq [Security.AccessControl.AceType]::AccessDenied) { continue }
        if ($Trusted -cnotcontains $Ace.SecurityIdentifier.Value -and (([long]$Ace.AccessMask -band $Risk) -ne 0)) {
            throw "运行路径允许不可信账户写入、删除或修改权限；请先人工检查，不会接管：$Path"
        }
    }
}

function Assert-ClientRuntimePath([string]$Root) {
    $Full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ([IO.Directory]::GetParent($Full).FullName -ine 'C:\Tools') { throw '运行目录必须是 C:\Tools 下的独立方案目录；不会修改共享父目录。' }
    $Parents = New-Object 'Collections.Generic.Stack[string]'
    $Parent = [IO.Directory]::GetParent($Full)
    while ($null -ne $Parent) { $Parents.Push($Parent.FullName); $Parent = $Parent.Parent }
    while ($Parents.Count -gt 0) {
        $Path = $Parents.Pop()
        $Item = Get-ClientRuntimeItem $Path
        if ($null -eq $Item) { continue }
        if (!$Item.PSIsContainer) { throw "运行路径祖先不是目录：$Path" }
        Assert-ClientRuntimeAcl $Path -Ancestor
    }
    $Item = Get-ClientRuntimeItem $Full
    if ($null -eq $Item) { return }
    if (!$Item.PSIsContainer) { throw "运行路径不是目录：$Full" }
    Assert-ClientRuntimeAcl $Full
    Get-ClientPlainTree $Full | ForEach-Object { Assert-ClientRuntimeAcl $_.FullName }
}

function Set-ClientRuntimePrivateAcl($Item) {
    Assert-ClientRuntimeAcl $Item.FullName
    $Acl = New-ClientPrivateAcl $Item.PSIsContainer
    # PS has no C# extension-method syntax and the static class is
    # System.IO.FileSystemAclExtensions (System.IO namespace) on PS 7;
    # PS 5.1 has the DirectoryInfo instance method instead.
    if ($PSVersionTable.PSEdition -ceq 'Core') {
        [IO.FileSystemAclExtensions]::SetAccessControl($Item, $Acl)
    } else {
        $Item.SetAccessControl($Acl)
    }
    $Written = Get-Acl -LiteralPath $Item.FullName -ErrorAction Stop
    $User = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $Trusted = @($User, 'S-1-5-32-544', 'S-1-5-18')
    if (!$Written.AreAccessRulesProtected -or $Written.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $User) {
        throw "运行路径的私有权限未正确保存：$($Item.FullName)"
    }
    $ExpectedRules = $Acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])
    $ExpectedInheritance = $ExpectedRules[0].InheritanceFlags
    $Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($Rule in $Written.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($Trusted -cnotcontains $Rule.IdentityReference.Value -or $Rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $Rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
            $Rule.InheritanceFlags -ne $ExpectedInheritance -or
            $Rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) { throw "运行路径的私有 DACL 验证失败：$($Item.FullName)" }
        $Seen.Add($Rule.IdentityReference.Value) | Out-Null
    }
    foreach ($Sid in $Trusted) { if (!$Seen.Contains($Sid)) { throw "运行路径缺少必要的私有权限：$($Item.FullName)" } }
}

function New-ClientPrivateDirectory([string]$Path) {
    # .NET Framework applies the protected DACL atomically at directory creation.
    # Modern .NET (PS 7) lacks that overload: create, apply immediately, and rely on
    # the callers' Assert-ClientRuntimePath / Set-ClientRuntimePrivateAcl rechecks;
    # parent trees were already verified non-writable by untrusted accounts.
    if ($PSVersionTable.PSEdition -ceq 'Core') {
        [IO.Directory]::CreateDirectory($Path) | Out-Null
        $Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        [IO.FileSystemAclExtensions]::SetAccessControl($Item, (New-ClientPrivateAcl $true))
    } else {
        [IO.Directory]::CreateDirectory($Path, (New-ClientPrivateAcl $true)) | Out-Null
    }
}

function New-ClientRuntimeSubdirectory([string]$Root, [ValidateSet('certs', 'logs', 'servy')][string]$Name) {
    $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    Assert-ClientRuntimePath $Root
    $Path = Join-Path $Root $Name
    if ($null -eq (Get-ClientRuntimeItem $Path)) { New-ClientPrivateDirectory $Path }
    $Item = Get-ClientRuntimeItem $Path
    if ($null -eq $Item -or !$Item.PSIsContainer) { throw "运行子目录无效：$Path" }
    Set-ClientRuntimePrivateAcl $Item
}

function Initialize-ClientRuntimeDirectory([string]$Root) {
    $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    # Recheck before any ACL write. Unsafe existing paths are rejected, never repaired.
    Assert-ClientRuntimePath $Root
    $Shared = [IO.Directory]::GetParent([IO.Path]::GetFullPath($Root)).FullName
    if ($null -eq (Get-ClientRuntimeItem $Shared)) { New-ClientPrivateDirectory $Shared }
    # CreateDirectory can encounter a concurrently created directory: recheck its
    # owner and effective-on-object allow entries before touching the runtime tree.
    Assert-ClientRuntimePath $Root
    if ($null -eq (Get-ClientRuntimeItem $Root)) { New-ClientPrivateDirectory $Root }
    Assert-ClientRuntimePath $Root
    $Items = @((Get-ClientRuntimeItem $Root)) + @(Get-ClientPlainTree $Root)
    foreach ($Item in $Items) { Set-ClientRuntimePrivateAcl $Item }
    foreach ($Name in @('certs', 'logs', 'servy')) { New-ClientRuntimeSubdirectory $Root $Name }
}

function Initialize-ClientComponents([string]$PackageDir, [ValidateSet('gost', 'frp')][string]$Scheme) {
    # Offline-only: components are packaged and hash-verified on the VPS; validate
    # the manifest and packaged sources, then return the package root.
    Assert-ClientComponentManifest $PackageDir $Scheme | Out-Null
    return [IO.Path]::GetFullPath($PackageDir)
}
