#requires -Version 5.1
<#
.SYNOPSIS
Create a dedicated AD user and application-only Exchange roles.
.DESCRIPTION
Run locally on an Exchange server in Windows PowerShell 5.1 or Exchange
Management Shell, using an administrator who can create AD users AND manage
Exchange RBAC. Local elevation alone does not grant either directory permission.
No Windows feature installation, endpoint ACL change, group membership grant,
firewall change, credential delegation or server security downgrade is performed.
No employee mailbox is created by this installer.
Designed for an isolated intranet: uses installed Windows/Exchange components
and internal AD/Exchange services only. No Internet probe or package download.
With no arguments, enter only the NEW service account name and password.
The AD domain/DC and Exchange endpoint are discovered automatically. Employee
mail domains, databases and placement belong to application deployment, not
service account creation. On success the script returns the account UPN.
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

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

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

function Get-NormalGroupFilter {
    # All present/future ordinary distribution groups, not a maintained allowlist.
    return "RecipientTypeDetails -eq 'MailUniversalDistributionGroup'"
}

function Get-NormalizedRecipientFilter {
    param($Filter)
    return (([string]$Filter -replace '[\s()]', '').ToLowerInvariant())
}

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

function Assert-NoNameCollisions {
    param([string[]] $Names, [object[]] $Existing, [string] $Kind)
    foreach ($item in $Existing) {
        if ($Names -contains [string]$item.Name) { throw "$Kind '$($item.Name)' already exists. Nothing will be overwritten; choose a fresh ServiceAccountName or have the administrator review the previous run." }
    }
}

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

function Get-ExchangeObjectName {
    param($Value)
    # EMS versions may return an ADObjectId or its remoting string projection.
    if ($Value -is [string]) { return $Value }
    if ($null -ne $Value -and $null -ne $Value.PSObject.Properties['Name']) { return [string]$Value.Name }
    throw 'Cannot verify Exchange object name from the returned metadata.'
}

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

function New-DisabledServicePrincipal {
    param($Directory, [string] $Sam, [string] $UPN, [System.Security.SecureString] $Secret)
    $principal = [System.DirectoryServices.AccountManagement.UserPrincipal]::new($Directory.Context)
    try {
        $principal.SamAccountName = $Sam
        $principal.Name = $Sam
        $principal.UserPrincipalName = $UPN
        $principal.DisplayName = 'Exchange Automation Service'
        $principal.Description = 'Exchange automation: create mailbox, read recipients, manage ordinary distribution group members.'
        $principal.Enabled = $false
        $principal.PasswordNotRequired = $false
        $principal.PasswordNeverExpires = $false
        $principal.DelegationPermitted = $false
        $principal.Save()
        # .NET requires plaintext for SetPassword; transient only, never exported/logged.
        $credential = [pscredential]::new($UPN, $Secret)
        $principal.SetPassword($credential.GetNetworkCredential().Password)
        $principal.Save()
        return $principal
    }
    catch {
        # This newly created account stays disabled if password policy rejects it.
        $principal.Dispose()
        throw 'AD account/password setup failed. A disabled account may remain; review the reported account name. No password is logged.'
    }
}

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

function Test-ServiceEndpoint {
    param([string] $URL, [pscredential] $Credential, [object[]] $Specifications, [string] $DC)
    $connection = New-ExchangeConnectionInfo $URL $Credential
    $pool = [runspacefactory]::CreateRunspacePool(1, 1, $connection, $Host)
    try {
        $pool.Open()
        $required = Get-RequiredEndpointParameters $Specifications
        $metadata = @(Invoke-EndpointCommand $pool 'Get-Command' @{ Name = [string[]]@($required.Keys) })
        foreach ($name in $required.Keys) {
            $commands = @($metadata | Where-Object { $_.Name -eq $name })
            if ($commands.Count -ne 1) { throw "Service endpoint is missing $name. RBAC replication/cache refresh may be pending." }
            foreach ($parameter in $required[$name]) {
                if (-not $commands[0].Parameters.ContainsKey($parameter)) { throw "Service endpoint is missing $name/$parameter." }
            }
        }
        $null = Invoke-EndpointCommand $pool 'Get-DistributionGroup' @{
            RecipientTypeDetails = 'MailUniversalDistributionGroup'; ResultSize = 1; DomainController = $DC
        }
        return [pscustomobject]@{ Authentication = 'Kerberos'; Endpoint = 'Microsoft.Exchange'; ReadOnlyCheck = 'Passed'; BusinessWriteTest = 'NotRun' }
    }
    finally { $pool.Dispose() }
}

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

function Resolve-ServiceAccountName {
    param([string] $Requested, [switch] $Preview)
    if ([string]::IsNullOrWhiteSpace($Requested)) {
        if ($Preview) { throw 'Specify -ServiceAccountName when using -WhatIf; no password is required.' }
        $Requested = Read-Host 'Enter the NEW service account name (without domain, e.g. svc_exchange_app)'
    }
    # Read-Host input needs the same validation as a bound command-line argument.
    if ($Requested -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,19}$') {
        throw 'Use 1-20 letters, digits, underscores or hyphens, starting with a letter or digit. Enter only the new account name, without DOMAIN\ or @domain.'
    }
    return $Requested
}

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
$principal = $null
$directory = $null
$createdRoles = @()
$createdAssignments = @()
$scopeCreated = $false
$scopeReused = $false
$stage = 'preflight'
$reportDirectory = $null
try {
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
    if (-not $PSCmdlet.ShouldProcess($upn, 'Create new dedicated AD account and application-only Exchange RBAC roles')) { return }
    if ($null -eq $Password) { $Password = Read-Host 'Enter the NEW service account password (not your administrator password)' -AsSecureString }
    if ($Password.Length -eq 0) { throw 'An empty service password is not allowed.' }
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot ("exchange-handoff-" + [guid]::NewGuid().ToString('N')) }
    if (Test-Path -LiteralPath $OutputDirectory) { throw 'OutputDirectory already exists; choose a new directory. Existing files are never overwritten.' }
    $null = New-Item -ItemType Directory -Path $OutputDirectory -ErrorAction Stop
    $reportDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
    $stage = 'create-unassigned-roles'
    foreach ($plan in $plans) {
        $createdRoles += $plan.Name
        New-ApplicationRole $plan $dc
    }
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
    $stage = 'create-disabled-account'
    $principal = New-DisabledServicePrincipal $directory $ServiceAccountName $upn $Password
    $accountGuid = $principal.Guid.ToString()
    # Fixed GUID/DC after creation; never add the service account to an admin group.
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
    $stage = 'enable-account'
    $principal.Enabled = $true
    $principal.Save()
    $stage = 'verify-service-login'
    # Only one authentication attempt: do not loop wrong passwords into lockout.
    $check = Test-ServiceEndpoint $url ([pscredential]::new($upn, $Password)) $specifications $dc
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
        employee_ou_restriction = $false; password_exported = $false; password_never_expires = $false
        verification = $check; linux_connectivity_verified = $false; business_write_verified = $false
        next_step = 'Use this account and the password entered. Connection details are in connection.env.example. Employee mail domain/database and Linux deployment are configured separately by the application operator.'
    }
    Write-SetupHandoff $reportDirectory $report $settings
    Write-Host "SUCCESS: $upn. Service login and required command parameters verified."
    Write-Host "Handoff files: $reportDirectory (no passwords). The password is the one you entered."
    Write-Warning 'Password expiry follows domain policy: arrange rotation. Linux connectivity and isolated mailbox/group writes still require acceptance.'
    Write-Output $upn
}
catch {
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
    if ($null -ne $principal) { $principal.Dispose() }
    if ($null -ne $directory) { $directory.Context.Dispose() }
}
