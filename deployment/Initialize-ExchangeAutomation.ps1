#requires -Version 5.1
<#
.SYNOPSIS
创建普通 AD 服务账号，并授予本程序所需的 Exchange 精简权限。
.DESCRIPTION
在 Exchange 服务器的 64 位 Windows PowerShell 5.1 / Exchange Management Shell 执行。
执行管理员需要 AD 创建用户和 Exchange RBAC 管理权限；仅本机管理员权限不够。
正常执行只输入新账号短名称、新密码，域名、域控和连接地址自动发现。
创建的账号没有邮箱；账号@域名是登录名。密码永不过期，不要求首次登录修改。
本脚本会创建 AD 用户、4 个精简角色及其分配，必要时创建普通通讯组权限范围。
只授予员工邮箱创建、收件人查询和普通通讯组成员维护权限；不加管理员组。
不安装 Windows 功能，不修改防火墙、证书或现有角色，不下载组件，不访问互联网。
成功前以新账号进行只读登录检查；失败时尝试禁用本次新账号，保留报告供排查。
员工数据库、邮箱后缀由程序部署配置决定，不在此处询问，也不在此处创建员工邮箱。
.EXAMPLE
.\Initialize-ExchangeAutomation.ps1 -ServiceAccountName svc_exchange_app -WhatIf
.EXAMPLE
.\Initialize-ExchangeAutomation.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,19}$')]
    [string] $ServiceAccountName,
    [System.Security.SecureString] $Password,
    [string] $DomainController,
    [string] $OutputDirectory
)

# 遇到错误立即停止，防止某一步失败后继续授权或误报成功。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# 【权限清单】只允许 8 个业务命令；New-Mailbox 是授予程序的权限，此处不会执行。
function Get-ApplicationRoleSpecifications {
    param([string] $Prefix)
    # Read-only cmdlets retain their parent parameters for Exchange compatibility.
    # Writes allow only ordinary mailbox creation and single-member maintenance.
    @(
        [pscustomobject]@{
            Name = "$Prefix-Read"; RoleType = 'ViewOnlyRecipients'; Kind = 'Read'
            Commands = @{
                'Get-Mailbox' = @('Identity', 'DomainController')
                'Get-Recipient' = @('Identity')
                'Get-User' = @('Identity', 'DomainController')
                'Get-DistributionGroup' = @('Identity', 'RecipientTypeDetails', 'ResultSize', 'DomainController')
                'Get-DistributionGroupMember' = @('Identity', 'ResultSize', 'DomainController')
            }
        }
        [pscustomobject]@{
            Name = "$Prefix-Create"; RoleType = 'MailRecipientCreation'; Kind = 'Create'
            Commands = @{
                'New-Mailbox' = @('Name', 'FirstName', 'Alias', 'SamAccountName', 'DisplayName',
                    'UserPrincipalName', 'PrimarySmtpAddress', 'Password', 'ResetPasswordOnNextLogon',
                    'OrganizationalUnit', 'Database', 'DomainController')
            }
        }
        [pscustomobject]@{
            Name = "$Prefix-Members"; RoleType = 'DistributionGroups'; Kind = 'Members'
            Commands = @{
                'Add-DistributionGroupMember' = @('Identity', 'Member', 'DomainController')
                'Remove-DistributionGroupMember' = @('Identity', 'Member', 'DomainController', 'Confirm')
            }
        }
        [pscustomobject]@{
            # Exchange splits DC/common parameters and the manager-bypass switch
            # across two built-in roles. Both child assignments use the SAME
            # ordinary-group scope; neither grants security-group maintenance.
            Name = "$Prefix-GroupBypass"; RoleType = 'SecurityGroupCreationAndMembership'; Kind = 'Members'
            Commands = @{
                'Add-DistributionGroupMember' = @('Identity', 'Member', 'BypassSecurityGroupManagerCheck')
                'Remove-DistributionGroupMember' = @('Identity', 'Member', 'BypassSecurityGroupManagerCheck')
            }
        }
    )
}

# 【范围定义】覆盖全部现有及未来普通静态通讯组，排除安全组和动态组。
function Get-NormalGroupFilter {
    # All present/future ordinary distribution groups, not a maintained allowlist.
    return "RecipientTypeDetails -eq 'MailUniversalDistributionGroup'"
}

# 【格式处理】仅消除 Exchange 回读过滤条件时增加的空白和括号。
function Get-NormalizedRecipientFilter {
    param($Filter)
    return (([string]$Filter -replace '[\s()]', '').ToLowerInvariant())
}

# 【只读】已有范围必须与目标条件完全匹配，且不含 OU 根或独占限制，才允许复用。
function Find-ReusableNormalGroupScope {
    param([object[]] $Scopes)
    $expected = Get-NormalizedRecipientFilter (Get-NormalGroupFilter)
    $matches = @($Scopes | Where-Object {
        -not $_.Exclusive -and -not $_.RecipientRoot -and
        (Get-NormalizedRecipientFilter $_.RecipientFilter) -eq $expected
    })
    if ($matches.Count -gt 1) { throw 'Multiple equivalent ordinary-group scopes exist; administrator review is required.' }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

# 【权限计算】写命令只保留业务必需参数；查询参数保留父角色能力以兼容各版本。
function Get-AllowedEntryParameters {
    param($Specification, [string] $CommandName, [string[]] $ParentParameters)
    $required = @($Specification.Commands[$CommandName])
    foreach ($name in $required) {
        if ($ParentParameters -notcontains $name) {
            throw "Parent role lacks required parameter $CommandName/$name. No broad-role fallback is allowed."
        }
    }
    if ($Specification.Kind -eq 'Read') { return $ParentParameters }
    $common = @('Confirm', 'WhatIf', 'ErrorAction', 'ErrorVariable', 'WarningAction', 'WarningVariable',
        'Verbose', 'Debug', 'OutBuffer', 'OutVariable', 'PipelineVariable', 'InformationAction', 'InformationVariable')
    return @($ParentParameters | Where-Object { $required -contains $_ -or $common -contains $_ })
}

# 【只读】按 RoleType 识别内置角色，不依赖中英文名称；缺少必需权限时停止。
function Resolve-RolePlans {
    param([object[]] $Specifications, [object[]] $AllRoles, [string] $DC)
    foreach ($spec in $Specifications) {
        $parents = @($AllRoles | Where-Object { $_.IsRootRole -and [string]$_.RoleType -eq $spec.RoleType })
        if ($parents.Count -ne 1) { throw "Cannot uniquely resolve built-in parent RoleType=$($spec.RoleType)." }
        $parent = $parents[0]
        if ([string]$parent.ImplicitRecipientReadScope -ne 'Organization') {
            throw "Parent role $($parent.Name) does not have organization-wide recipient reads."
        }
        if ($spec.Kind -ne 'Read' -and [string]$parent.ImplicitRecipientWriteScope -ne 'Organization') {
            throw "Parent role $($parent.Name) does not have organization-wide recipient writes."
        }
        $entries = @(Get-ManagementRoleEntry -Identity "$($parent.Name)\*" -DomainController $DC -ErrorAction Stop)
        $allowed = @{}
        foreach ($name in $spec.Commands.Keys) {
            $found = @($entries | Where-Object { $_.Name -eq $name })
            if ($found.Count -ne 1) { throw "Parent role $($parent.Name) lacks $name." }
            $allowed[$name] = @(Get-AllowedEntryParameters $spec $name @($found[0].Parameters))
        }
        [pscustomobject]@{ Name = $spec.Name; Parent = [string]$parent.Name; Kind = $spec.Kind; Entries = $allowed }
    }
}

# 【只读回查】确认新角色实际保存的命令及参数与精简清单一致。
function Assert-RoleContents {
    param($Plan, [string] $DC)
    $entries = @(Get-ManagementRoleEntry -Identity "$($Plan.Name)\*" -DomainController $DC -ErrorAction Stop)
    if ($entries.Count -ne $Plan.Entries.Count) { throw "Role verification failed: $($Plan.Name) has unexpected cmdlets." }
    foreach ($entry in $entries) {
        if (-not $Plan.Entries.ContainsKey([string]$entry.Name)) { throw "Role contains an unapproved cmdlet: $($entry.Name)." }
        $delta = @(Compare-Object -ReferenceObject @($Plan.Entries[[string]$entry.Name] | Sort-Object) -DifferenceObject @($entry.Parameters | Sort-Object))
        if ($delta.Count -ne 0) { throw "Role parameter readback failed: $($entry.Name)." }
    }
}

# 【写入】仅创建本次专用子角色，先裁剪再授权；不修改内置角色或其他人的角色。
function New-ApplicationRole {
    param($Plan, [string] $DC)
    # Only called for names proven absent before writes. Never edit built-in or
    # pre-existing roles. Trim BEFORE assigning this role to any principal.
    $null = New-ManagementRole -Name $Plan.Name -Parent $Plan.Parent -DomainController $DC -ErrorAction Stop
    $entries = @(Get-ManagementRoleEntry -Identity "$($Plan.Name)\*" -DomainController $DC -ErrorAction Stop)
    foreach ($entry in $entries) {
        $identity = "$($Plan.Name)\$($entry.Name)"
        if ($Plan.Entries.ContainsKey([string]$entry.Name)) {
            Set-ManagementRoleEntry -Identity $identity -Parameters @($Plan.Entries[[string]$entry.Name]) -DomainController $DC -Confirm:$false -ErrorAction Stop
        }
        else {
            Remove-ManagementRoleEntry -Identity $identity -DomainController $DC -Confirm:$false -ErrorAction Stop
        }
    }
    Assert-RoleContents $Plan $DC
}

# 【只读保护】同名对象已经存在时停止，避免覆盖或向旧账号叠加权限。
function Assert-NoNameCollisions {
    param([string[]] $Names, [object[]] $Existing, [string] $Kind)
    foreach ($item in $Existing) {
        if ($Names -contains [string]$item.Name) { throw "$Kind '$($item.Name)' already exists. Nothing will be overwritten; choose a fresh ServiceAccountName or have the administrator review the previous run." }
    }
}

# 【只读回查】拒绝额外/可委派角色，并确认两项组维护授权都限制为普通通讯组。
function Assert-ApplicationAssignments {
    param([object[]] $Plans, [object[]] $Assignments, [string] $ScopeName)
    $names = @($Plans | ForEach-Object { "$($_.Name)-Assignment" })
    foreach ($assignment in $Assignments) {
        if ($assignment.Enabled -and ([string]$assignment.RoleAssignmentDelegationType -ne 'Regular' -or $names -notcontains [string]$assignment.Name)) {
            throw 'Unexpected effective RBAC assignment detected. No broad/extra role is allowed.'
        }
    }
    foreach ($plan in $Plans) {
        $matches = @($Assignments | Where-Object { $_.Name -eq "$($plan.Name)-Assignment" -and $_.Enabled -and [string]$_.RoleAssignmentDelegationType -eq 'Regular' })
        if ($matches.Count -ne 1) { throw "Missing or disabled assignment: $($plan.Name)." }
        $assignment = $matches[0]
        if ((Get-ExchangeObjectName $assignment.Role) -ne $plan.Name) { throw 'Assigned role differs from the verified role.' }
        if ($plan.Kind -eq 'Members') {
            if ((Get-ExchangeObjectName $assignment.CustomRecipientWriteScope) -ne $ScopeName -or [string]$assignment.RecipientWriteScope -ne 'CustomRecipientScope') {
                throw 'Group membership assignment is missing its ordinary-group-only scope.'
            }
        }
        elseif ($plan.Kind -eq 'Create' -and [string]$assignment.RecipientWriteScope -ne 'Organization') {
            throw 'Mailbox creation is unexpectedly restricted by a recipient scope.'
        }
    }
}

# 【兼容处理】兼容 EMS 返回的对象名或远程序列化字符串。
function Get-ExchangeObjectName {
    param($Value)
    # EMS versions may return an ADObjectId or its remoting string projection.
    if ($Value -is [string]) { return $Value }
    if ($null -ne $Value -and $null -ne $Value.PSObject.Properties['Name']) { return [string]$Value.Name }
    throw 'Cannot verify Exchange object name from the returned metadata.'
}

# 【本机加载】使用服务器已安装的 Exchange 管理组件，不联网安装或修改执行策略。
function Initialize-ManagementShell {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
        throw 'Use 64-bit Windows PowerShell 5.1 on the Exchange server, not PowerShell 7.'
    }
    if (-not (Get-Command Get-ExchangeServer -ErrorAction SilentlyContinue)) {
        if (-not $env:ExchangeInstallPath) { throw 'Exchange installation not detected. Open Exchange Management Shell on the Exchange server.' }
        $loader = Join-Path $env:ExchangeInstallPath 'bin\RemoteExchange.ps1'
        if (-not (Test-Path -LiteralPath $loader -PathType Leaf)) { throw 'Exchange Management Shell bootstrap was not found.' }
        # The vendor bootstrap assumes a console host and non-strict semantics
        # (e.g. RawUI sizes can be null in a remote/noninteractive host). Do not
        # impose our strict mode on Microsoft's installed scripts. Restore it
        # before validating commands or performing any provisioning.
        try {
            Set-StrictMode -Off
            . $loader
            Connect-ExchangeServer -Auto -ClientApplication ManagementShell -ErrorAction Stop
        }
        finally { Set-StrictMode -Version 2.0 }
        $module = (Get-Command Get-ExchangeServer -ErrorAction Stop).Module
        if ($null -ne $module) { Import-Module $module -Global -ErrorAction Stop }
    }
    # The actual cmdlets below enforce administrator permissions. Avoid a
    # duplicate command/parameter preflight for the whole management shell.
}

# 【只读发现】从本机所属 AD 域选择可写域控；使用 Windows 自带 .NET，无需 RSAT。
function Get-DirectoryContext {
    param([string] $RequestedDC)
    # Built into Windows/.NET Framework; no RSAT AD module installation required.
    Add-Type -AssemblyName System.DirectoryServices
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
    if ([string]::IsNullOrWhiteSpace($RequestedDC)) {
        $RequestedDC = $domain.FindDomainController([System.DirectoryServices.ActiveDirectory.LocatorOptions]::WriteableRequired).Name
    }
    $root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$RequestedDC/RootDSE")
    try {
        $dn = [string]$root.Properties['defaultNamingContext'][0]
        if ([string]::IsNullOrWhiteSpace($dn)) { throw 'Cannot read AD default naming context.' }
        $domainEntry = $domain.GetDirectoryEntry()
        try {
            if ([string]$domainEntry.Properties['distinguishedName'][0] -ne $dn) { throw 'DomainController must be in the Exchange server computer domain for this installer.' }
        }
        finally { $domainEntry.Dispose() }
        $context = [System.DirectoryServices.AccountManagement.PrincipalContext]::new(
            [System.DirectoryServices.AccountManagement.ContextType]::Domain, $RequestedDC)
        return [pscustomobject]@{ Domain = [string]$domain.Name; DC = $RequestedDC; Context = $context }
    }
    finally { $root.Dispose(); $domain.Dispose() }
}

# 【只读保护】同时检查短名称和登录名，绝不重置或接管已有账号。
function Assert-NewAccount {
    param($Directory, [string] $Sam, [string] $UPN)
    foreach ($identity in @(
        @{ Type = [System.DirectoryServices.AccountManagement.IdentityType]::SamAccountName; Value = $Sam },
        @{ Type = [System.DirectoryServices.AccountManagement.IdentityType]::UserPrincipalName; Value = $UPN }
    )) {
        $existing = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($Directory.Context, $identity.Type, $identity.Value)
        if ($null -ne $existing) {
            $existing.Dispose()
            throw 'The requested AD account already exists. Refusing to reset its password, reuse it, or add permissions. Choose a fresh ServiceAccountName.'
        }
    }
}

# 【本机对象】构造尚未保存的普通 AD 用户对象；实际写入由下一个函数完成。
function New-ServicePrincipal {
    param($Context)
    return [System.DirectoryServices.AccountManagement.UserPrincipal]::new($Context)
}

# 【写入 AD】先创建禁用账号，再设密码；没有 New-Mailbox / Enable-Mailbox 操作。
function New-DisabledServicePrincipal {
    param($Directory, [string] $Sam, [string] $UPN, [System.Security.SecureString] $Secret)
    $principal = New-ServicePrincipal $Directory.Context
    try {
        $principal.SamAccountName = $Sam
        $principal.Name = $Sam
        $principal.UserPrincipalName = $UPN
        $principal.DisplayName = 'Exchange Automation Service'
        $principal.Description = 'Exchange automation: create mailbox, read recipients, manage ordinary distribution group members.'
        $principal.Enabled = $false
        $principal.PasswordNotRequired = $false
        $principal.PasswordNeverExpires = $true
        $principal.DelegationPermitted = $false
        $principal.Save()
        # .NET 设置密码时短暂使用明文，仅在内存中，不回显、不写报告；密码复杂度仍由 AD 检查。
        $credential = [pscredential]::new($UPN, $Secret)
        $principal.SetPassword($credential.GetNetworkCredential().Password)
        # 将 pwdLastSet 更新为当前时间，明确取消“下次登录必须更改密码”。
        $principal.RefreshExpiredPassword()
        $principal.Save()
        return $principal
    }
    catch {
        # This newly created account stays disabled if password policy rejects it.
        $principal.Dispose()
        throw 'AD account/password setup failed. A disabled account may remain; review the reported account name. No password is logged.'
    }
}

# 【只读远程调用】用于查询命令元数据和一条通讯组；不执行任何员工业务写入。
function Invoke-EndpointCommand {
    param($Pool, [string] $Name, [hashtable] $Parameters)
    $powershell = [powershell]::Create()
    try {
        $powershell.RunspacePool = $Pool
        $null = $powershell.AddCommand($Name)
        foreach ($key in $Parameters.Keys) { $null = $powershell.AddParameter($key, $Parameters[$key]) }
        $null = $powershell.AddParameter('ErrorAction', 'Stop')
        $output = @($powershell.Invoke())
        if ($powershell.HadErrors -or $powershell.InvocationStateInfo.State -ne 'Completed') {
            throw "Read-only endpoint check failed for $Name. Inspect Exchange server diagnostics; no write command was attempted."
        }
        return $output
    }
    finally { $powershell.Dispose() }
}

# 【连接配置】目标是内网 Exchange；微软 URI 仅为协议标识，不是要访问的网站。
function New-ExchangeConnectionInfo {
    param([string] $URL, [pscredential] $Credential)
    # URL is the internal Exchange network destination. The second argument is
    # a fixed WSMan shell identifier, NOT a website to resolve, visit or download.
    $connection = [System.Management.Automation.Runspaces.WSManConnectionInfo]::new(
        [uri]$URL, 'http://schemas.microsoft.com/powershell/Microsoft.Exchange', $Credential)
    $connection.AuthenticationMechanism = [System.Management.Automation.Runspaces.AuthenticationMechanism]::Kerberos
    $connection.ProxyAccessType = [System.Management.Automation.Remoting.ProxyAccessType]::NoProxyServer
    $connection.MaximumConnectionRedirectionCount = 0
    $connection.OpenTimeout = 20000
    $connection.OperationTimeout = 60000
    return $connection
}

# 【连接对象】创建独立 Exchange 会话；不申请普通 Windows PowerShell 管理权限。
function New-ExchangeRunspacePool {
    param([string] $URL, [pscredential] $Credential)
    $connection = New-ExchangeConnectionInfo $URL $Credential
    return [runspacefactory]::CreateRunspacePool(1, 1, $connection, $Host)
}

# 【只读验收】仅在登录成功但权限元数据未齐全时，间隔 5 秒重新建会话，最多检查 3 次。
# 认证失败、查询报错直接停止，避免反复尝试错误密码；最终失败仍由主流程禁用账号。
function Test-ServiceEndpoint {
    param([string] $URL, [pscredential] $Credential, [object[]] $Specifications, [string] $DC)
    $required = Get-RequiredEndpointParameters $Specifications
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds 5 }
        $pool = New-ExchangeRunspacePool $URL $Credential
        try {
            $pool.Open()
            # 不按名称筛选，避免缺失命令先触发远程错误，使后面的缓存延迟判断失效。
            $metadata = @(Invoke-EndpointCommand $pool 'Get-Command' @{})
            $missing = @()
            foreach ($name in $required.Keys) {
                $commands = @($metadata | Where-Object { $_.Name -eq $name })
                if ($commands.Count -ne 1) { $missing += $name; continue }
                foreach ($parameter in $required[$name]) {
                    if (-not $commands[0].Parameters.ContainsKey($parameter)) { $missing += "$name/$parameter" }
                }
            }
            if ($missing.Count -gt 0) {
                if ($attempt -eq 3) { throw "Service endpoint still lacks required RBAC capabilities: $($missing -join ', ')." }
                Write-Warning '登录已成功，但部分命令权限尚未生效；5 秒后刷新会话检查。'
                continue
            }
            $null = Invoke-EndpointCommand $pool 'Get-DistributionGroup' @{
                RecipientTypeDetails = 'MailUniversalDistributionGroup'; ResultSize = 1; DomainController = $DC
            }
            return [pscustomobject]@{ Authentication = 'Kerberos'; Endpoint = 'Microsoft.Exchange'; ReadOnlyCheck = 'Passed'; BusinessWriteTest = 'NotRun'; Attempts = $attempt }
        }
        finally { $pool.Dispose() }
    }
}

# 【权限计算】合并多个子角色对同一个命令提供的参数，用于实际会话验证。
function Get-RequiredEndpointParameters {
    param([object[]] $Specifications)
    $required = @{}
    foreach ($spec in $Specifications) {
        foreach ($name in $spec.Commands.Keys) {
            $required[$name] = @(@($required[$name]) + @($spec.Commands[$name]) | Where-Object { $_ } | Sort-Object -Unique)
        }
    }
    return $required
}

# 【输入 1】只输入新账号短名称；域后缀自动追加，已有账号不允许复用。
function Resolve-ServiceAccountName {
    param([string] $Requested, [switch] $Preview)
    if ([string]::IsNullOrWhiteSpace($Requested)) {
        if ($Preview) { throw 'Specify -ServiceAccountName when using -WhatIf; no password is required.' }
        $Requested = Read-Host '输入新服务账号名（不含域名，例如 svc_exchange_app）'
    }
    # Read-Host input needs the same validation as a bound command-line argument.
    if ($Requested -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,19}$') {
        throw 'Use 1-20 letters, digits, underscores or hyphens, starting with a letter or digit. Enter only the new account name, without DOMAIN\ or @domain.'
    }
    return $Requested
}

# 【写入本地报告】只保存账号、连接和检查结果，不保存密码；文件写入本次新目录。
function Write-SetupHandoff {
    param([string] $Directory, $Report, [hashtable] $Settings)
    # Directory was newly created by this invocation. Exports contain no password/token.
    $Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Directory 'setup-report.json') -Encoding UTF8
    if ($null -ne $Settings) {
        $lines = @('# Connection settings only; merge into the application deployment configuration.',
            '# systemd EnvironmentFile syntax; NOT a shell script. Password supplied separately.')
        foreach ($name in @($Settings.Keys | Sort-Object)) {
            $text = [string]$Settings[$name]
            if ($text -match '[\r\n\x00]') { throw 'Invalid configuration value in handoff.' }
            $text = $text.Replace('\', '\\').Replace('"', '\"')
            $lines += "$name=`"$text`""
        }
        $lines | Set-Content -LiteralPath (Join-Path $Directory 'connection.env.example') -Encoding UTF8
    }
}

# MAIN -- tests load only function definitions from this file's AST.
# 【主流程】以下按顺序完成查询、角色准备、建号、授权和只读验收。
$principal = $null
$directory = $null
$createdRoles = @()
$createdAssignments = @()
$scopeCreated = $false
$scopeReused = $false
$stage = 'preflight'
$reportDirectory = $null
try {
    # 1. 只读准备：确定域与连接地址，确认账号、角色名未占用，计算所需权限。
    $ServiceAccountName = Resolve-ServiceAccountName $ServiceAccountName -Preview:$WhatIfPreference
    Initialize-ManagementShell
    $directory = Get-DirectoryContext $DomainController
    $dc = $directory.DC
    $upn = "$ServiceAccountName@$($directory.Domain)"
    Assert-NewAccount $directory $ServiceAccountName $upn
    $prefix = "EA-$ServiceAccountName"
    $scopeName = "$prefix-AllDistributionGroups"
    $specifications = @(Get-ApplicationRoleSpecifications $prefix)
    $allRoles = @(Get-ManagementRole -DomainController $dc -ErrorAction Stop)
    Assert-NoNameCollisions @($specifications.Name) $allRoles 'Role'
    $allScopes = @(Get-ManagementScope -DomainController $dc -ErrorAction Stop)
    $reusableScope = Find-ReusableNormalGroupScope $allScopes
    if ($null -ne $reusableScope) {
        $scopeName = [string]$reusableScope.Name
        $scopeReused = $true
    }
    else { Assert-NoNameCollisions @($scopeName) $allScopes 'Scope' }
    if (@($allScopes | Where-Object { $_.Exclusive }).Count -gt 0) {
        Write-Warning 'Exclusive management scopes exist. This script does not override them; protected recipients/databases may remain inaccessible.'
    }
    $assignmentNames = @($specifications | ForEach-Object { "$($_.Name)-Assignment" })
    Assert-NoNameCollisions $assignmentNames @(Get-ManagementRoleAssignment -DomainController $dc -ErrorAction Stop) 'Assignment'
    $plans = @(Resolve-RolePlans $specifications $allRoles $dc)
    $server = Get-ExchangeServer -Identity $env:COMPUTERNAME -DomainController $dc -ErrorAction Stop
    $exchangeFqdn = [string]$server.Fqdn
    $exchangeVersion = [string]$server.AdminDisplayVersion
    if ([string]::IsNullOrWhiteSpace($exchangeFqdn)) { throw 'Exchange server FQDN was not returned.' }
    # Use the real server FQDN for Kerberos, not an IIS alias whose HTTP SPN is unknown.
    $url = "http://$exchangeFqdn/PowerShell/"
    Write-Host "Account: $upn; Exchange endpoint: $url; DC: $dc; Exchange: $exchangeVersion"
    Write-Host 'Scope: organization-wide mailbox creation; all present/future ordinary distribution group memberships. No employee OU or group-name allowlist.'
    Write-Host 'No mailbox deletion/disable/reset, group creation/deletion, server administration, role administration or Windows shell rights will be granted.'
    # 2. 输入密码并建立新报告目录；-WhatIf 在此返回，不创建任何对象或文件。
    if (-not $PSCmdlet.ShouldProcess($upn, 'Create new dedicated AD account and application-only Exchange RBAC roles')) { return }
    if ($null -eq $Password) { $Password = Read-Host '输入新服务账号密码（不是管理员密码）' -AsSecureString }
    if ($Password.Length -eq 0) { throw 'An empty service password is not allowed.' }
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot ("exchange-handoff-" + [guid]::NewGuid().ToString('N')) }
    if (Test-Path -LiteralPath $OutputDirectory) { throw 'OutputDirectory already exists; choose a new directory. Existing files are never overwritten.' }
    $null = New-Item -ItemType Directory -Path $OutputDirectory -ErrorAction Stop
    $reportDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
    # 3. 创建精简子角色，此时尚未授权给任何账号；逐项回读确认。
    $stage = 'create-unassigned-roles'
    foreach ($plan in $plans) {
        $createdRoles += $plan.Name
        New-ApplicationRole $plan $dc
    }
    # 4. 创建或复用普通通讯组范围；不按员工 OU 或组名限制，不包含安全组。
    $stage = 'create-group-type-scope'
    if (-not $scopeReused) {
        $null = New-ManagementScope -Name $scopeName -RecipientRestrictionFilter (Get-NormalGroupFilter) -DomainController $dc -ErrorAction Stop
        $scopeCreated = $true
    }
    $scope = Get-ManagementScope -Identity $scopeName -DomainController $dc -ErrorAction Stop
    # Exchange may normalize parentheses/whitespace in this filter on readback.
    $actualFilter = Get-NormalizedRecipientFilter $scope.RecipientFilter
    $expectedFilter = Get-NormalizedRecipientFilter (Get-NormalGroupFilter)
    if ($scope.Exclusive -or $scope.RecipientRoot -or $actualFilter -ne $expectedFilter) { throw 'New group scope failed readback verification.' }
    # 5. 创建禁用状态的普通 AD 账号，密码永不过期且无需首次改密，不创建邮箱。
    $stage = 'create-disabled-account'
    $principal = New-DisabledServicePrincipal $directory $ServiceAccountName $upn $Password
    $accountGuid = $principal.Guid.ToString()
    # Fixed GUID/DC after creation; never add the service account to an admin group.
    # 6. 只给本次账号 GUID 分配精简角色，启用 Exchange 远程权限并回查分配。
    $stage = 'assign-application-roles'
    foreach ($plan in $plans) {
        $assignment = @{ Name = "$($plan.Name)-Assignment"; Role = $plan.Name; User = $accountGuid; DomainController = $dc; ErrorAction = 'Stop' }
        if ($plan.Kind -eq 'Members') { $assignment['CustomRecipientWriteScope'] = $scopeName }
        # No OU restriction for Create. No group-name or member allowlist.
        $createdAssignments += $assignment.Name
        $null = New-ManagementRoleAssignment @assignment
    }
    Set-User -Identity $accountGuid -RemotePowerShellEnabled $true -DomainController $dc -ErrorAction Stop
    $stage = 'verify-role-assignments'
    # Each new role was already trimmed and verified before assignment.
    $effective = @(Get-ManagementRoleAssignment -RoleAssignee $accountGuid -DomainController $dc -ErrorAction Stop)
    Assert-ApplicationAssignments $plans $effective $scopeName
    # 7. 授权核对通过后启用账号；以新账号连接内网 Exchange，执行只读检查。
    $stage = 'enable-account'
    $principal.Enabled = $true
    $principal.Save()
    $stage = 'verify-service-login'
    # 认证错误不重试；仅成功认证后的权限缓存延迟允许有限次重查。
    $check = Test-ServiceEndpoint $url ([pscredential]::new($upn, $Password)) $specifications $dc
    # 8. 保存不含密码的交付文件；只读检查通过后才输出 SUCCESS 和完整登录名。
    $settings = @{
        EXCHANGE_CONNECTION_MODE = 'direct'
        EXCHANGE_POWERSHELL_URL = $url; EXCHANGE_AUTH = 'kerberos'; EXCHANGE_USERNAME = $upn
        EXCHANGE_DOMAIN_CONTROLLER = $dc; EXCHANGE_BYPASS_GROUP_MANAGER_CHECK = 'true'
    }
    $report = [ordered]@{
        status = 'provisioned_and_read_check_passed'; username = $upn; account_guid = $accountGuid
        setup_mode = 'service_account_only'
        account_dn = $principal.DistinguishedName; endpoint = $url; domain_controller = $dc
        exchange_server = $exchangeFqdn; exchange_version = $exchangeVersion
        roles = $createdRoles; assignments = $createdAssignments; group_scope_name = $scopeName
        group_scope = (Get-NormalGroupFilter); group_scope_reused = $scopeReused
        employee_ou_restriction = $false; password_exported = $false; password_never_expires = $true
        change_password_at_next_logon = $false; service_mailbox_created = $false
        verification = $check; linux_connectivity_verified = $false; business_write_verified = $false
        next_step = 'Use this account and the password entered. Connection details are in connection.env.example. Employee mail domain/database and Linux deployment are configured separately by the application operator.'
    }
    Write-SetupHandoff $reportDirectory $report $settings
    Write-Host "SUCCESS: $upn. Service login and required command parameters verified."
    Write-Host "Handoff files: $reportDirectory (no passwords). The password is the one you entered."
    Write-Host '服务账号无邮箱；密码永不过期，首次登录无需改密。请妥善保管输入的密码。'
    Write-Warning '以上仅为服务器端只读验收；Linux 连接及隔离员工的创建、加组、离组仍需验收。'
    Write-Output $upn
}
catch {
    # 【失败保护】尝试禁用本次新账号并记录阶段；保留对象，不删除、不覆盖旧数据。
    $setupError = $_
    $accountDisabled = $null
    if ($null -ne $principal) {
        try { $principal.Enabled = $false; $principal.Save(); $accountDisabled = $true }
        catch { $accountDisabled = $false }
    }
    if ($reportDirectory) {
        $failure = [ordered]@{
            status = 'failed_not_ready'; stage = $stage; service_account_name = $ServiceAccountName
            account_disabled_after_failure = $accountDisabled; roles_attempted = $createdRoles
            assignments_attempted = $createdAssignments; group_scope_created = $scopeCreated; group_scope_reused = $scopeReused
            error_type = $setupError.Exception.GetType().FullName; business_write_verified = $false
            next_step = 'Do not use this account until reviewed. Newly created roles/accounts may remain; no existing object was overwritten and no rollback deletion was attempted.'
        }
        try { Write-SetupHandoff $reportDirectory $failure $null } catch { Write-Warning 'Could not write failure report.' }
    }
    # Preflight messages contain no password; suppress directory/Exchange write errors
    # that could include arguments. Stage/type plus server diagnostics identify failure.
    if ($stage -eq 'preflight') { Write-Warning $setupError.Exception.Message }
    Write-Error "Setup failed at stage '$stage'. Error type: $($setupError.Exception.GetType().Name). Check setup-report.json and server diagnostics. No automatic privilege broadening was attempted." -ErrorAction Continue
    if ($accountDisabled -eq $false) { Write-Warning 'URGENT: could not confirm the new account was disabled; an administrator must inspect it immediately.' }
    throw 'Exchange automation setup did not complete; do not treat the account as ready.'
}
finally {
    # 【释放本机资源】关闭目录对象；不更改服务器配置。
    if ($null -ne $principal) { $principal.Dispose() }
    if ($null -ne $directory) { $directory.Context.Dispose() }
}
