#requires -Version 5.1
<#
在生产 Exchange 服务器已有的 64 位 Exchange Management Shell 中直接运行，无需参数。
仅查询：不建号、不授权、不改配置、不装模块、不访问公网、不执行业务写入。
仅输出到屏幕/管道：脚本不写文件。报告含内网资产信息，回传前请管理员审核。
不采集员工名单、邮件内容、组成员、密码、证书私钥。查询不等于生产业务验收。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$FormatEnumerationLimit = -1

# 运行前提：只检查当前 Shell，不自动加载、安装或修复任何管理组件。
if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
    throw '请在 Exchange 服务器已有的 64 位 Windows PowerShell 5.1 / Exchange Management Shell 中运行。'
}
if (-not (Get-Command Get-ExchangeServer -ErrorAction SilentlyContinue)) {
    throw '当前没有 Exchange 管理命令。请打开 Exchange Management Shell 后重新运行；不要安装额外模块。'
}

# 唯一的辅助方法：打印章节和查询结果；失败记录原因并继续，不重试、不修复。
function Show-Query {
    param([string] $Title, [scriptblock] $Query)
    Write-Output ("`r`n========== " + $Title + ' ==========')
    try {
        & $Query | Format-List | Out-String -Width 4096
    }
    catch {
        Write-Output ('[查询失败] ' + $_.Exception.Message)
    }
}

Write-Output ('Exchange 只读环境报告；UTC 时间：' + [DateTime]::UtcNow.ToString('o'))

# 01：查询 Windows、PowerShell、.NET 版本及执行策略，判断兼容性；不修改执行策略。
Show-Query '01 服务器及运行环境' {
    Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber
    Get-CimInstance Win32_ComputerSystem | Select-Object Name,Domain,DomainRole
    [pscustomobject]@{ PowerShell = $PSVersionTable.PSVersion.ToString(); Is64Bit = [Environment]::Is64BitProcess }
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' | Select-Object Release
    Get-ExecutionPolicy -List | Select-Object Scope,ExecutionPolicy
}

# 02：查询 Exchange 节点 FQDN、版本和角色；读取本机补丁文件版本，不执行该文件。
Show-Query '02 Exchange 节点和版本' {
    Get-ExchangeServer | Select-Object Name,Fqdn,AdminDisplayVersion,Edition,ServerRole
    if ($env:ExchangeInstallPath) {
        (Get-Item -LiteralPath (Join-Path $env:ExchangeInstallPath 'bin\ExSetup.exe')).VersionInfo |
            Select-Object FileVersion,ProductVersion
    }
}

# 03：查询 AD 域、可写域控和允许的 UPN 后缀；只读 LDAP，不要求 AD/RSAT 模块。
# UPN 后缀是登录名后缀，不一定是员工邮箱后缀；Dispose 只关闭本地查询连接。
Show-Query '03 AD 域和域控' {
    $domain = $null; $dc = $null; $forest = $null; $root = $null; $partitions = $null
    try {
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
        $dc = $domain.FindDomainController([System.DirectoryServices.ActiveDirectory.LocatorOptions]::WriteableRequired)
        $forest = $domain.Forest
        $root = [adsi]("LDAP://$($dc.Name)/RootDSE")
        $partitions = [adsi]("LDAP://$($dc.Name)/CN=Partitions,$($root.configurationNamingContext)")
        [pscustomobject]@{
            Domain = $domain.Name; WritableDC = $dc.Name; Forest = $forest.Name
            ForestDomains = ($forest.Domains | ForEach-Object { $_.Name }) -join ', '
            AlternativeUPNSuffixes = $partitions.Properties['uPNSuffixes'] -join ', '
        }
    }
    finally {
        foreach ($item in @($partitions, $root, $forest, $dc, $domain)) {
            if ($null -ne $item) { $item.Dispose() }
        }
    }
}

# 04：查询已配置的 IP 和 DNS，为内网部署提供地址信息；不改网卡、不探测公网。
Show-Query '04 本机 IP 和 DNS 配置' {
    Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' |
        Select-Object IPAddress,DNSHostName,DNSDomain,DNSServerSearchOrder
}

# 05：查询数据库名称、归属和挂载状态；不创建、挂载或移动数据库，多库时不自动选库。
Show-Query '05 邮箱数据库' {
    Get-MailboxDatabase -Status | Select-Object Name,Server,Mounted,Recovery,IsExcludedFromProvisioning
}

# 06：查询接受域，核对员工邮箱后缀；不询问或修改后缀，默认接受域未必就是员工邮箱域。
Show-Query '06 Exchange 接受域' {
    Get-AcceptedDomain | Select-Object Name,DomainName,DomainType,Default
}

# 07：查询邮件地址策略的名称和模板，为邮箱后缀判断提供线索；不应用策略、不查员工。
Show-Query '07 邮件地址策略模板' {
    Get-EmailAddressPolicy | Select-Object Name,Priority,EnabledEmailAddressTemplates
}

# 08：查询本机前端/后端 PowerShell 端点认证、HTTPS 和扩展保护设置；不改 IIS 或认证。
Show-Query '08 PowerShell 端点配置' {
    Get-PowerShellVirtualDirectory -Server $env:COMPUTERNAME -ShowMailboxVirtualDirectories |
        Select-Object Identity,InternalUrl,ExternalUrl,RequireSSL,WindowsAuthentication,BasicAuthentication,
            CertificateAuthentication,InternalAuthenticationMethods,ExternalAuthenticationMethods,
            ExtendedProtectionTokenChecking,ExtendedProtectionFlags,ExtendedProtectionSPNList
}

# 09：只看本机 IIS 证书的公开信息，核对 HTTPS 名称/有效期；不导出证书，不读私钥。
Show-Query '09 IIS 证书公开信息' {
    Get-ExchangeCertificate -Server $env:COMPUTERNAME | Where-Object { [string]$_.Services -match 'IIS' } |
        Select-Object Subject,Issuer,CertificateDomains,NotBefore,NotAfter,Services
}

# 10：查看 Exchange 依赖服务是否运行；不启动、停止、重启服务或修改启动方式。
Show-Query '10 依赖服务状态' {
    Get-Service -Name WinRM,W3SVC,MSExchangeADTopology,MSExchangeIS,Netlogon | Select-Object Name,Status,StartType
}

# 11：Get-Command 只查询“建号授权命令是否可见”，下列引号里的 New/Set/Remove 不会执行。
# 命令可见不等于有 AD 建号权限，也不证明具备完整的 RBAC 委派权限。
Show-Query '11 当前 Shell 管理命令可见性' {
    foreach ($name in @('New-ManagementRole', 'Set-ManagementRoleEntry', 'Remove-ManagementRoleEntry',
            'New-ManagementScope', 'New-ManagementRoleAssignment', 'Set-User')) {
        [pscustomobject]@{ Name = $name; Visible = [bool](Get-Command -Name $name -ErrorAction SilentlyContinue) }
    }
}

# 12：按 RoleType 查询四类内置角色及八个业务命令参数，核对权限裁剪兼容性。
# 不依赖角色显示语言；只读角色定义，不授权、不查角色成员、不执行任何业务命令。
Show-Query '12 内置业务角色和参数' {
    $types = @('ViewOnlyRecipients', 'MailRecipientCreation', 'DistributionGroups', 'SecurityGroupCreationAndMembership')
    $commands = @('Get-Mailbox', 'Get-Recipient', 'Get-User', 'New-Mailbox', 'Get-DistributionGroup',
        'Get-DistributionGroupMember', 'Add-DistributionGroupMember', 'Remove-DistributionGroupMember')
    $roots = @(Get-ManagementRole | Where-Object { $_.IsRootRole -and [string]$_.RoleType -in $types })
    foreach ($type in $types) {
        $matches = @($roots | Where-Object { [string]$_.RoleType -eq $type })
        [pscustomobject]@{ RoleType = $type; RootRoleCount = $matches.Count }
        foreach ($role in $matches) {
            [pscustomobject]@{
                Role = [string]$role.Name; RoleType = [string]$role.RoleType
                ReadScope = [string]$role.ImplicitRecipientReadScope; WriteScope = [string]$role.ImplicitRecipientWriteScope
            }
            Get-ManagementRoleEntry -Identity "$($role.Name)\*" | Where-Object { $_.Name -in $commands } |
                Select-Object Name,@{Name='Parameters';Expression={$_.Parameters -join ', '}}
        }
    }
}

# 13：查询现有自定义/独占范围，判断组织隔离要求和普通组范围能否复用；不改范围。
Show-Query '13 自定义及独占管理范围' {
    Get-ManagementScope | Select-Object Name,Exclusive,ScopeRestrictionType,RecipientRoot,RecipientFilter,ServerFilter,DatabaseFilter
}

# 结束说明：不输出“生产就绪”；空白字段可能是不适用或当前权限看不到，不能当作正常。
Write-Output '采集结束。查询失败请保留原文；本报告未验证 AD 建号/分离权限、业务写入或 Linux 连通性。'
