# PowerShell 5.1 regression for the administrator installer. All AD/RBAC writes
# below are mocks. Only isolated test handoff files may be written locally.
param([string] $SourceText, [string] $SourcePath)
$ErrorActionPreference = 'Stop'
if (-not $SourceText) {
    if (-not $SourcePath) { $SourcePath = Join-Path $PSScriptRoot '../../deployment/Initialize-ExchangeAutomation.ps1' }
    $SourceText = Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8
}
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($SourceText, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | ForEach-Object { $_.Message } | Out-String) }
$definitions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
$functionText = ($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
. ([scriptblock]::Create($functionText))
$script:Passed = @()
function Assert-Test([string] $Name, [bool] $Condition) {
    if (-not $Condition) { throw "Setup regression failed: $Name" }
    $script:Passed += $Name
}
function Assert-Throws([string] $Name, [scriptblock] $Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-Test $Name $failed
}

$specs = @(Get-ApplicationRoleSpecifications 'EA-unit')
Assert-Test 'syntax / four isolated role specifications' ($specs.Count -eq 4)
$allCommands = @($specs | ForEach-Object { $_.Commands.Keys } | Sort-Object -Unique)
Assert-Test 'exactly eight business commands' ($allCommands.Count -eq 8)
Assert-Test 'all ordinary groups, no OU/name restriction' ((Get-NormalGroupFilter) -eq "RecipientTypeDetails -eq 'MailUniversalDistributionGroup'")
$reusableScope = Find-ReusableNormalGroupScope @([pscustomobject]@{
    Name = 'EA-existing-AllDistributionGroups'; Exclusive = $false; RecipientRoot = $null
    RecipientFilter = "( RecipientTypeDetails -eq 'MailUniversalDistributionGroup' )"
})
Assert-Test 'equivalent safe group scope can be reused' ($reusableScope.Name -eq 'EA-existing-AllDistributionGroups')
Assert-Test 'broader group scope is not reused' ($null -eq (Find-ReusableNormalGroupScope @([pscustomobject]@{
    Name = 'broad'; Exclusive = $false; RecipientRoot = $null; RecipientFilter = "Alias -ne `$null"
})))
Assert-Test 'OU-rooted group scope is not reused' ($null -eq (Find-ReusableNormalGroupScope @([pscustomobject]@{
    Name = 'rooted'; Exclusive = $false; RecipientRoot = 'OU=Groups,DC=example,DC=com'; RecipientFilter = (Get-NormalGroupFilter)
})))
Assert-Throws 'multiple equivalent scopes require review' { Find-ReusableNormalGroupScope @(
    [pscustomobject]@{ Name = 'one'; Exclusive = $false; RecipientRoot = $null; RecipientFilter = (Get-NormalGroupFilter) },
    [pscustomobject]@{ Name = 'two'; Exclusive = $false; RecipientRoot = $null; RecipientFilter = (Get-NormalGroupFilter) }
) }
$read = $specs | Where-Object Kind -eq 'Read'
$create = $specs | Where-Object Kind -eq 'Create'
$members = $specs | Where-Object RoleType -eq 'DistributionGroups'
$bypass = $specs | Where-Object RoleType -eq 'SecurityGroupCreationAndMembership'
Assert-Test 'bypass comes from correct role type' ($bypass.Kind -eq 'Members')
Assert-Test 'DC and manager bypass use compatible parent roles' ($members.Commands['Remove-DistributionGroupMember'] -contains 'DomainController' -and $bypass.Commands['Remove-DistributionGroupMember'] -notcontains 'DomainController' -and $bypass.Commands['Remove-DistributionGroupMember'] -notcontains 'Confirm')
$requiredEndpoint = Get-RequiredEndpointParameters $specs
Assert-Test 'endpoint check unions parameters from multiple roles' ($requiredEndpoint.Count -eq 8 -and $requiredEndpoint['Remove-DistributionGroupMember'] -contains 'DomainController' -and $requiredEndpoint['Remove-DistributionGroupMember'] -contains 'Confirm' -and $requiredEndpoint['Remove-DistributionGroupMember'] -contains 'BypassSecurityGroupManagerCheck')
$creationParameters = @($create.Commands['New-Mailbox']) + @('Shared', 'Room', 'Arbitration', 'AccountDisabled', 'Confirm', 'WhatIf', 'ErrorAction')
$allowed = @(Get-AllowedEntryParameters $create 'New-Mailbox' $creationParameters)
Assert-Test 'no special/disabled mailbox creation parameters' (@($allowed | Where-Object { $_ -in @('Shared', 'Room', 'Arbitration', 'AccountDisabled') }).Count -eq 0)
Assert-Test 'ordinary creation password and placement remain usable' ($allowed -contains 'Password' -and $allowed -contains 'Database' -and $allowed -contains 'OrganizationalUnit')
Assert-Test 'common parameters retained' ($allowed -contains 'ErrorAction' -and $allowed -contains 'WhatIf')
$readAllowed = @(Get-AllowedEntryParameters $read 'Get-Mailbox' @('Identity', 'DomainController', 'ResultSize', 'ReadFromDomainController'))
Assert-Test 'read parameter compatibility retained' ($readAllowed -contains 'ReadFromDomainController')
Assert-Throws 'missing required parameters rejected' { Get-AllowedEntryParameters $create 'New-Mailbox' @('Name') }
Assert-NoNameCollisions @('EA-unit-Read') @([pscustomobject]@{ Name = 'unrelated-role' }) 'Role'
Assert-Test 'unrelated existing role untouched' $true
Assert-Throws 'existing role collision rejected' { Assert-NoNameCollisions @('EA-unit-Read') @([pscustomobject]@{ Name = 'EA-unit-Read' }) 'Role' }

$script:Entries = @{}
$script:Writes = @()
$parents = @()
foreach ($spec in $specs) {
    $parentName = 'Localized-' + $spec.RoleType
    $parents += [pscustomobject]@{ Name = $parentName; RoleType = $spec.RoleType; IsRootRole = $true; ImplicitRecipientReadScope = 'Organization'; ImplicitRecipientWriteScope = 'Organization' }
    $script:Entries[$parentName] = @{}
    foreach ($name in $spec.Commands.Keys) { $script:Entries[$parentName][$name] = @($spec.Commands[$name]) + @('ErrorAction', 'WhatIf') }
    $script:Entries[$parentName]['Remove-Mailbox'] = @('Identity', 'Confirm')
}
$mockCommands = @'
function Get-ManagementRoleEntry {
    [CmdletBinding()] param($Identity, $DomainController)
    $role = $Identity.Split('\')[0]
    foreach ($name in $script:Entries[$role].Keys) { [pscustomobject]@{ Name = $name; Parameters = $script:Entries[$role][$name] } }
}
function New-ManagementRole {
    [CmdletBinding()] param($Name, $Parent, $DomainController)
    if ($script:Entries.ContainsKey($Name)) { throw 'collision' }
    $script:Entries[$Name] = @{}
    foreach ($key in $script:Entries[$Parent].Keys) { $script:Entries[$Name][$key] = @($script:Entries[$Parent][$key]) }
    $script:Writes += 'create-role:' + $Name
}
function Set-ManagementRoleEntry {
    [CmdletBinding(SupportsShouldProcess)] param($Identity, $Parameters, $DomainController)
    $role, $command = $Identity.Split('\')
    $script:Entries[$role][$command] = @($Parameters)
    $script:Writes += 'set-entry:' + $Identity
}
function Remove-ManagementRoleEntry {
    [CmdletBinding(SupportsShouldProcess)] param($Identity, $DomainController)
    $role, $command = $Identity.Split('\')
    $script:Entries[$role].Remove($command)
    $script:Writes += 'remove-entry:' + $Identity
}
'@
. ([scriptblock]::Create($mockCommands))
$plans = @(Resolve-RolePlans $specs $parents 'dc.example.com')
Assert-Test 'parents resolved by role type, not localized names' ($plans[0].Parent -like 'Localized-*')
Assert-Test 'planning is read-only' ($script:Writes.Count -eq 0)
foreach ($plan in $plans) { New-ApplicationRole $plan 'dc.example.com' }
Assert-Test 'four roles created' (@($script:Writes | Where-Object { $_ -like 'create-role:*' }).Count -eq 4)
Assert-Test 'dangerous inherited cmdlets removed' (@($plans | Where-Object { $script:Entries[$_.Name].ContainsKey('Remove-Mailbox') }).Count -eq 0)
Assert-Test 'built-in parent entries unchanged' ($script:Entries['Localized-MailRecipientCreation'].ContainsKey('Remove-Mailbox'))
$script:Entries[$plans[0].Name]['Remove-Mailbox'] = @('Identity')
Assert-Throws 'extra cmdlet detected by readback' { Assert-RoleContents $plans[0] 'dc.example.com' }
$script:Entries[$plans[0].Name].Remove('Remove-Mailbox')
$assignments = @($plans | ForEach-Object {
    [pscustomobject]@{ Name = "$($_.Name)-Assignment"; Role = [pscustomobject]@{ Name = $_.Name }; Enabled = $true; RoleAssignmentDelegationType = 'Regular'
        RecipientWriteScope = $(if ($_.Kind -eq 'Members') { 'CustomRecipientScope' } elseif ($_.Kind -eq 'Create') { 'Organization' } else { 'None' })
        CustomRecipientWriteScope = [pscustomobject]@{ Name = 'EA-unit-AllDistributionGroups' } }
})
Assert-ApplicationAssignments $plans $assignments 'EA-unit-AllDistributionGroups'
Assert-Test 'organization creation plus all normal-group membership accepted' $true
$memberAssignment = $assignments | Where-Object { $_.Name -like '*-Members-*' }
$memberAssignment.RecipientWriteScope = 'Organization'
Assert-Throws 'unfiltered group write scope rejected' { Assert-ApplicationAssignments $plans $assignments 'EA-unit-AllDistributionGroups' }
$memberAssignment.RecipientWriteScope = 'CustomRecipientScope'
$extra = [pscustomobject]@{ Name = 'Organization Management'; Enabled = $true; RoleAssignmentDelegationType = 'Regular' }
Assert-Throws 'unexpected effective role rejected' { Assert-ApplicationAssignments $plans @($assignments + $extra) 'EA-unit-AllDistributionGroups' }
$assignments[0].RoleAssignmentDelegationType = 'Delegating'
Assert-Throws 'permission delegation rejected' { Assert-ApplicationAssignments $plans $assignments 'EA-unit-AllDistributionGroups' }
$assignments[0].RoleAssignmentDelegationType = 'Regular'
foreach ($assignment in $assignments) {
    $assignment.Role = [string]$assignment.Role.Name
    $assignment.CustomRecipientWriteScope = [string]$assignment.CustomRecipientWriteScope.Name
}
Assert-ApplicationAssignments $plans $assignments 'EA-unit-AllDistributionGroups'
Assert-Test 'real EMS string role and scope projection supported' $true
$assignments[0].RoleAssignmentDelegationType = 'DelegatingOrgWide'
Assert-Throws 'organization-wide permission delegation rejected' { Assert-ApplicationAssignments $plans $assignments 'EA-unit-AllDistributionGroups' }
$assignments[0].RoleAssignmentDelegationType = 'Regular'
Assert-Throws 'unrecognized Exchange object name rejected' { Get-ExchangeObjectName ([pscustomobject]@{}) }

Assert-Test 'explicit account spelling is preserved' ((Resolve-ServiceAccountName 'Svc_App-01') -ceq 'Svc_App-01')
Assert-Test 'twenty-character account is accepted' ((Resolve-ServiceAccountName '12345678901234567890').Length -eq 20)
Assert-Throws 'account UPN is not accepted as a new short name' { Resolve-ServiceAccountName 'svc@example.com' }
Assert-Throws 'NetBIOS account form is not accepted as a new short name' { Resolve-ServiceAccountName 'EXAMPLE\svc' }
Assert-Throws 'invalid leading character rejected' { Resolve-ServiceAccountName '_svc' }
Assert-Throws 'long account name rejected' { Resolve-ServiceAccountName '123456789012345678901' }
Assert-Throws 'preview requires name without prompting' { Resolve-ServiceAccountName '' -Preview }
Assert-Test 'mail and database discovery are not installer prerequisites' ($SourceText -notmatch 'Get-AcceptedDomain|Get-MailboxDatabase|Select-SetupValue')
Assert-Test 'account-only setup does not enumerate forest domains or employee UPN suffixes' ($SourceText -notmatch '\$domain\.Forest|uPNSuffixes|configurationNamingContext|DomainCount')
Assert-Test 'handoff is explicitly connection-only' ($SourceText -match 'connection.env.example' -and $SourceText -notmatch 'application.env.example')

# Relevant parameter subsets transcribed from the production CU6 screenshots,
# not a complete export of the parent roles and not evidence of write access.
$productionCU6 = @{
    ViewOnlyRecipients = @{
        'Get-Mailbox' = @('Identity', 'DomainController')
        'Get-Recipient' = @('Identity', 'DomainController', 'ReadFromDomainController', 'ResultSize')
        'Get-User' = @('Identity', 'DomainController')
        'Get-DistributionGroup' = @('Identity', 'RecipientTypeDetails', 'ResultSize', 'DomainController')
        'Get-DistributionGroupMember' = @('Identity', 'ResultSize', 'DomainController')
    }
    MailRecipientCreation = @{
        'New-Mailbox' = @('Name', 'FirstName', 'Alias', 'SamAccountName', 'DisplayName', 'UserPrincipalName',
            'PrimarySmtpAddress', 'Password', 'ResetPasswordOnNextLogon', 'OrganizationalUnit', 'Database', 'DomainController')
    }
    DistributionGroups = @{
        'Add-DistributionGroupMember' = @('Identity', 'Member', 'DomainController')
        'Remove-DistributionGroupMember' = @('Identity', 'Member', 'DomainController', 'Confirm')
    }
    SecurityGroupCreationAndMembership = @{
        'Add-DistributionGroupMember' = @('Identity', 'Member', 'BypassSecurityGroupManagerCheck')
        'Remove-DistributionGroupMember' = @('Identity', 'Member', 'BypassSecurityGroupManagerCheck')
    }
}
foreach ($spec in $specs) {
    foreach ($commandName in $spec.Commands.Keys) {
        $available = @($productionCU6[$spec.RoleType][$commandName])
        Assert-Test "production CU6 exposes $($spec.RoleType)/$commandName" ($available.Count -gt 0)
        Assert-Test "production CU6 has required parameters for $commandName" (@($spec.Commands[$commandName] | Where-Object { $available -notcontains $_ }).Count -eq 0)
    }
}
Assert-Test 'production ViewOnlyRecipients Get-Recipient retains its DC parameter' (@(Get-AllowedEntryParameters $read 'Get-Recipient' $productionCU6.ViewOnlyRecipients['Get-Recipient']) -contains 'DomainController')
Assert-Test 'restricted Get-Recipient without DC remains compatible' (@(Get-AllowedEntryParameters $read 'Get-Recipient' @('Identity', 'ResultSize')) -notcontains 'DomainController')

# Construct metadata only: no runspace is opened and no DNS/HTTP request is made.
$testSecret = ConvertTo-SecureString 'Test-only-never-used-123!' -AsPlainText -Force
$connectionInfo = New-ExchangeConnectionInfo 'http://exchange.example.com/PowerShell/' ([pscredential]::new('unit@example.com', $testSecret))
Assert-Test 'connection destination is the supplied internal Exchange endpoint' ($connectionInfo.ConnectionUri.AbsoluteUri -ceq 'http://exchange.example.com/PowerShell/')
Assert-Test 'Microsoft URI is only the Exchange shell identifier' ($connectionInfo.ShellUri -ceq 'http://schemas.microsoft.com/powershell/Microsoft.Exchange')
Assert-Test 'internal endpoint check retains Kerberos authentication' ([string]$connectionInfo.AuthenticationMechanism -eq 'Kerberos')
Assert-Test 'internal endpoint check never uses a web proxy' ([string]$connectionInfo.ProxyAccessType -eq 'NoProxyServer')
Assert-Test 'internal endpoint check does not follow redirects' ($connectionInfo.MaximumConnectionRedirectionCount -eq 0)
$installerCommands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
$onlineCommands = @('Invoke-WebRequest', 'Invoke-RestMethod', 'iwr', 'irm', 'curl', 'wget', 'Start-BitsTransfer', 'Install-Module', 'Install-Package', 'Save-Module', 'Update-Help')
Assert-Test 'installer has no web probe or online installation commands' (@($installerCommands | Where-Object { $onlineCommands -contains $_ }).Count -eq 0)
Assert-Test 'installer never invokes mailbox creation or mailbox enablement' (@($installerCommands | Where-Object { $_ -in @('New-Mailbox', 'Enable-Mailbox', 'Enable-RemoteMailbox', 'New-RemoteMailbox') }).Count -eq 0)

# Exercise the real AD setup function against an in-memory principal only.
& {
    function New-ServicePrincipal {
        param($Context)
        $script:PrincipalEvents = @()
        $script:PrincipalDouble = [pscustomobject]@{
            SamAccountName = ''; Name = ''; UserPrincipalName = ''; DisplayName = ''; Description = ''
            Enabled = $true; PasswordNotRequired = $true; PasswordNeverExpires = $false; DelegationPermitted = $true
        }
        $script:PrincipalDouble | Add-Member ScriptMethod Save {
            $script:PrincipalEvents += 'save:' + $this.Enabled
        }
        $script:PrincipalDouble | Add-Member ScriptMethod SetPassword {
            param($Password)
            if ($script:PasswordFailure) { throw 'simulated domain password policy rejection' }
            if ($Password -ne 'Test-only-never-used-123!') { throw 'wrong password transfer' }
            $script:PrincipalEvents += 'password'
        }
        $script:PrincipalDouble | Add-Member ScriptMethod RefreshExpiredPassword {
            $script:PrincipalEvents += 'no-first-logon-change'
        }
        $script:PrincipalDouble | Add-Member ScriptMethod Dispose { $script:PrincipalEvents += 'dispose' }
        return $script:PrincipalDouble
    }
    $script:PasswordFailure = $false
    $result = New-DisabledServicePrincipal ([pscustomobject]@{Context = $null}) 'unit' 'unit@example.com' $testSecret
    Assert-Test 'service password never expires' $result.PasswordNeverExpires
    Assert-Test 'service initially disabled with password required and no delegation' (-not $result.Enabled -and -not $result.PasswordNotRequired -and -not $result.DelegationPermitted)
    Assert-Test 'set password then clear first-logon change before final save' (($script:PrincipalEvents -join ',') -ceq 'save:False,password,no-first-logon-change,save:False')
    $script:PasswordFailure = $true
    Assert-Throws 'domain password rejection propagates' { New-DisabledServicePrincipal ([pscustomobject]@{Context = $null}) 'unit' 'unit@example.com' $testSecret }
    Assert-Test 'password failure leaves disabled account and releases resource' (-not $script:PrincipalDouble.Enabled -and ($script:PrincipalEvents -join ',') -eq 'save:False,dispose')
}

# Real retry logic, simulated sessions: no authentication/network calls or sleeps.
& {
    function New-ExchangeRunspacePool {
        param($URL, $Credential)
        $pool = [pscustomobject]@{}
        $pool | Add-Member ScriptMethod Open {
            $script:OpenCount++
            if ($script:EndpointScenario -eq 'auth-error') { throw 'simulated authentication failure' }
        }
        $pool | Add-Member ScriptMethod Dispose { $script:DisposeCount++ }
        return $pool
    }
    function Start-Sleep { param($Seconds) $script:Sleeps += $Seconds }
    function Invoke-EndpointCommand {
        param($Pool, $Name, $Parameters)
        if ($Name -eq 'Get-Command') {
            if ($Parameters.Count -ne 0) { throw 'metadata discovery must include missing cmdlets without remote name errors' }
            if ($script:EndpointScenario -eq 'metadata-error') { throw 'simulated metadata query failure' }
            foreach ($commandName in $requiredEndpoint.Keys) {
                if ($commandName -eq 'New-Mailbox' -and ($script:EndpointScenario -eq 'permanent-missing' -or
                    ($script:EndpointScenario -eq 'command-lag' -and $script:OpenCount -eq 1))) { continue }
                $available = @{}
                foreach ($parameter in $requiredEndpoint[$commandName]) { $available[$parameter] = $true }
                if ($commandName -eq 'New-Mailbox' -and $script:EndpointScenario -eq 'parameter-lag' -and $script:OpenCount -eq 1) { $available.Remove('Password') }
                [pscustomobject]@{Name = $commandName; Parameters = $available}
            }
        }
        elseif ($Name -eq 'Get-DistributionGroup') {
            $script:ReadCount++
            if ($script:EndpointScenario -eq 'query-error') { throw 'simulated directory query failure' }
        }
        else { throw 'Unexpected command in read-only check.' }
    }
    foreach ($scenario in @('success', 'command-lag', 'parameter-lag', 'permanent-missing', 'auth-error', 'metadata-error', 'query-error')) {
        $script:EndpointScenario = $scenario
        $script:OpenCount = 0; $script:DisposeCount = 0; $script:ReadCount = 0; $script:Sleeps = @()
        $credential = [pscredential]::new('unit@example.com', $testSecret)
        if ($scenario -in @('success', 'command-lag', 'parameter-lag')) {
            $result = Test-ServiceEndpoint 'http://exchange.example.com/PowerShell/' $credential $specs 'dc.example.com'
            $expectedAttempts = if ($scenario -eq 'success') { 1 } else { 2 }
            Assert-Test "$scenario succeeds after bounded metadata checks" ($result.Attempts -eq $expectedAttempts -and $script:OpenCount -eq $expectedAttempts -and $result.BusinessWriteTest -eq 'NotRun' -and $script:ReadCount -eq 1)
        }
        else {
            Assert-Throws "$scenario fails closed" { Test-ServiceEndpoint 'http://exchange.example.com/PowerShell/' $credential $specs 'dc.example.com' }
            $expectedAttempts = if ($scenario -eq 'permanent-missing') { 3 } else { 1 }
            Assert-Test "$scenario has bounded or no retries" ($script:OpenCount -eq $expectedAttempts)
        }
        Assert-Test "$scenario releases every opened session" ($script:DisposeCount -eq $script:OpenCount)
        Assert-Test "$scenario waits only between permitted retries" ($script:Sleeps.Count -eq ($script:OpenCount - 1) -and @($script:Sleeps | Where-Object { $_ -ne 5 }).Count -eq 0)
    }
}
$testSecret.Dispose()

# Verify the complete MAIN order using mocks, including -WhatIf and failure handling.
$mainText = $SourceText.Substring($SourceText.IndexOf('# MAIN --'))
$mainMocks = @'
function Initialize-ManagementShell { }
function Get-DirectoryContext {
    $context = [pscustomobject]@{}
    $context | Add-Member ScriptMethod Dispose { }
    [pscustomobject]@{ Domain = 'example.com'; DC = 'dc.example.com'; Context = $context }
}
function Assert-NewAccount {
    if ($script:TestFailure -eq 'existing') { throw 'The requested AD account already exists.' }
}
function Get-ManagementRole { [CmdletBinding()] param($DomainController) $script:TestParents }
function Get-ManagementScope {
    [CmdletBinding()] param($Identity, $DomainController)
    if ($Identity) { [pscustomobject]@{ Name = $Identity; RecipientFilter = "(RecipientTypeDetails -eq 'MailUniversalDistributionGroup')"; RecipientRoot = $null; Exclusive = $false } }
}
function Get-ManagementRoleAssignment {
    [CmdletBinding()] param($DomainController, $RoleAssignee)
    if ($RoleAssignee) { $script:TestAssignments }
}
function Get-ExchangeServer { [CmdletBinding()] param($Identity, $DomainController) [pscustomobject]@{ Fqdn = 'exchange.example.com'; AdminDisplayVersion = 'Version 15.2 (Build 659.4)' } }
function Get-AcceptedDomain { throw 'Service account setup must not query employee mail domains.' }
function Get-MailboxDatabase { throw 'Service account setup must not query employee databases.' }
function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    $script:TestPrompts += [pscustomobject]@{ Text = $Prompt; Secure = [bool]$AsSecureString }
    if ($Prompt -eq '输入新服务账号名（不含域名，例如 svc_exchange_app）' -and -not $AsSecureString) {
        if ($script:TestFailure -eq 'invalid-name') { return 'bad@domain' }
        return 'unit'
    }
    if ($Prompt -eq '输入新服务账号密码（不是管理员密码）' -and $AsSecureString) {
        if ($script:TestFailure -eq 'empty-password') { return [securestring]::new() }
        return ConvertTo-SecureString 'Test-only-never-used-123!' -AsPlainText -Force
    }
    throw "Unexpected prompt: $Prompt"
}
function New-ApplicationRole { param($Plan, $DC) $script:TestEvents += 'role:' + $Plan.Name }
function Assert-RoleContents { }
function New-ManagementScope { [CmdletBinding()] param($Name, $RecipientRestrictionFilter, $DomainController) $script:TestEvents += 'scope' }
function New-DisabledServicePrincipal {
    $script:TestEvents += 'account-disabled'
    $script:TestPrincipal = [pscustomobject]@{ Guid = [guid]'11111111-1111-1111-1111-111111111111'; Enabled = $false; DistinguishedName = 'CN=unit,CN=Users,DC=example,DC=com' }
    $script:TestPrincipal | Add-Member ScriptMethod Save { $script:TestEvents += 'account-enabled:' + $this.Enabled }
    $script:TestPrincipal | Add-Member ScriptMethod Dispose { }
    return $script:TestPrincipal
}
function New-ManagementRoleAssignment {
    [CmdletBinding()] param($Name, $Role, $User, $DomainController, $CustomRecipientWriteScope)
    $script:TestEvents += 'assignment:' + $Name
    if ($script:TestFailure -eq 'assignment') { throw 'simulated assignment failure' }
    $script:TestAssignments += [pscustomobject]@{
        Name = $Name; Role = [pscustomobject]@{ Name = $Role }; Enabled = $true; RoleAssignmentDelegationType = 'Regular'
        RecipientWriteScope = $(if ($CustomRecipientWriteScope) { 'CustomRecipientScope' } elseif ($Role -like '*-Create') { 'Organization' } else { 'None' })
        CustomRecipientWriteScope = [pscustomobject]@{ Name = $CustomRecipientWriteScope }
    }
}
function Set-User { [CmdletBinding()] param($Identity, $RemotePowerShellEnabled, $DomainController) $script:TestEvents += 'remote-enabled' }
function Test-ServiceEndpoint {
    $script:TestEvents += 'read-check'
    if ($script:TestFailure -eq 'login') { throw 'simulated endpoint failure' }
    [pscustomobject]@{ ReadOnlyCheck = 'Passed'; BusinessWriteTest = 'NotRun' }
}
function Write-SetupHandoff {
    param($Directory, $Report, $Settings)
    $script:TestReport = $Report
    $script:TestSettings = $Settings
    $script:TestEvents += 'report:' + $Report.status
}
# Avoid ANY filesystem or AD mutation in main-path tests.
function Test-Path { param($LiteralPath) return $false }
function New-Item { [CmdletBinding()] param($ItemType, $Path) $script:TestEvents += 'output-directory' }
function Resolve-Path { param($LiteralPath) [pscustomobject]@{ Path = 'C:\mock-handoff' } }
'@
$header = @'
[CmdletBinding(SupportsShouldProcess=$true)]
param([switch]$Preview, [switch]$Interactive)
$ServiceAccountName = 'unit'
$Password = ConvertTo-SecureString 'Test-only-never-used-123!' -AsPlainText -Force
$DomainController = ''; $OutputDirectory = 'C:\mock-handoff'
if ($Interactive) { $ServiceAccountName = ''; $Password = $null }
if ($Preview) { $WhatIfPreference = $true }
'@
$script:TestParents = $parents
$mainCommand = [scriptblock]::Create($header + "`n" + $functionText + "`n" + $mainMocks + "`n" + $mainText)
foreach ($scenario in @('preview', 'success', 'interactive', 'existing', 'invalid-name', 'empty-password', 'assignment', 'login')) {
    $script:TestEvents = @(); $script:TestAssignments = @(); $script:TestFailure = $scenario
    $script:TestPrompts = @()
    $script:TestReport = $null; $script:TestSettings = $null; $script:TestPrincipal = $null
    if ($scenario -in @('assignment', 'login')) {
        Assert-Throws "$scenario failure propagates" { & $mainCommand -ErrorAction SilentlyContinue }
        Assert-Test "$scenario failure leaves new account disabled" (-not $script:TestPrincipal.Enabled)
        Assert-Test "$scenario failure not reported ready" ($script:TestReport.status -eq 'failed_not_ready')
    }
    elseif ($scenario -eq 'preview') {
        $returned = @(& $mainCommand -Preview)
        Assert-Test 'WhatIf performs no provisioning or file writes' ($script:TestEvents.Count -eq 0)
        Assert-Test 'WhatIf asks no password and returns no account' ($script:TestPrompts.Count -eq 0 -and $returned.Count -eq 0)
    }
    elseif ($scenario -in @('existing', 'invalid-name', 'empty-password')) {
        Assert-Throws "$scenario stops before provisioning" { & $mainCommand -Interactive -ErrorAction SilentlyContinue }
        Assert-Test "$scenario has no account role or file writes" ($script:TestEvents.Count -eq 0 -and $null -eq $script:TestPrincipal)
        if ($scenario -ne 'empty-password') {
            Assert-Test "$scenario never requests a password" (@($script:TestPrompts | Where-Object Secure).Count -eq 0)
        }
    }
    elseif ($scenario -eq 'interactive') {
        $returned = @(& $mainCommand -Interactive)
        Assert-Test 'interactive setup prompts only for name and password' ($script:TestPrompts.Count -eq 2 -and -not $script:TestPrompts[0].Secure -and $script:TestPrompts[1].Secure)
        Assert-Test 'interactive setup returns the completed account UPN' ($returned.Count -eq 1 -and $returned[0] -ceq 'unit@example.com')
        Assert-Test 'interactive setup validates login before returning' ($script:TestReport.status -eq 'provisioned_and_read_check_passed' -and $script:TestEvents -contains 'read-check')
    }
    else {
        $returned = @(& $mainCommand)
        Assert-Test 'main success produces honest readiness report' ($script:TestReport.status -eq 'provisioned_and_read_check_passed' -and -not $script:TestReport.business_write_verified)
        Assert-Test 'main does not select employee mailbox deployment settings' (@(@('EXCHANGE_MAIL_DOMAIN', 'EXCHANGE_MAILBOX_DATABASE', 'EXCHANGE_UPN_SUFFIX', 'EXCHANGE_ORGANIZATIONAL_UNIT', 'HTTP_ADDRESS', 'APP_ENV') | Where-Object { $script:TestSettings.ContainsKey($_) }).Count -eq 0)
        Assert-Test 'main returns only the service account UPN' ($returned.Count -eq 1 -and $returned[0] -ceq 'unit@example.com')
        Assert-Test 'main exports working connection identity and endpoint' ($script:TestSettings.EXCHANGE_USERNAME -ceq 'unit@example.com' -and $script:TestSettings.EXCHANGE_POWERSHELL_URL -eq 'http://exchange.example.com/PowerShell/' -and $script:TestSettings.EXCHANGE_DOMAIN_CONTROLLER -eq 'dc.example.com')
        Assert-Test 'main report distinguishes account setup from app configuration' ($script:TestReport.setup_mode -eq 'service_account_only')
        Assert-Test 'main report records discovered Exchange build' ($script:TestReport.exchange_server -eq 'exchange.example.com' -and $script:TestReport.exchange_version -eq 'Version 15.2 (Build 659.4)')
        Assert-Test 'main report records requested service password policy and no mailbox' ($script:TestReport.password_never_expires -and -not $script:TestReport.change_password_at_next_logon -and -not $script:TestReport.service_mailbox_created)
        Assert-Test 'roles prepared before account and assignments' ($script:TestEvents[0] -eq 'output-directory' -and $script:TestEvents[1] -like 'role:*' -and $script:TestEvents[6] -eq 'account-disabled')
        Assert-Test 'login happens after role assignment' ([array]::IndexOf($script:TestEvents, 'read-check') -gt [array]::IndexOf($script:TestEvents, 'account-enabled:True'))
        Assert-Test 'no password or token in handoff settings' (-not $script:TestSettings.ContainsKey('EXCHANGE_PASSWORD') -and -not $script:TestSettings.ContainsKey('API_TOKEN'))
    }
}
[pscustomobject]@{ passed = $script:Passed.Count; tests = $script:Passed; real_directory_writes = 0; real_exchange_writes = 0 } | ConvertTo-Json -Depth 5 -Compress
