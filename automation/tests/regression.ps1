# Run with PowerShell 5.1+ and a hashtable/PSCustomObject containing script texts.
# All Exchange commands below are mocks. This suite never changes AD/Exchange.
param($Sources, [string] $ScriptsPath)
$ErrorActionPreference = 'Stop'
if ($null -eq $Sources) {
    if ([string]::IsNullOrWhiteSpace($ScriptsPath)) { $ScriptsPath = Join-Path $PSScriptRoot '../scripts' }
    $loaded = @{}
    foreach ($file in Get-ChildItem -LiteralPath $ScriptsPath -Filter '*.ps1') {
        $loaded[$file.Name] = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    }
    $Sources = [pscustomobject]$loaded
}
$script:Passed = @()
$script:MockMailbox = [pscustomobject]@{
    Guid = '11111111-1111-1111-1111-111111111111'
    SamAccountName = 'slpeng'; UserPrincipalName = 'slpeng@example.com'
    DisplayName = 'Test {{ 7 * 7 }}'; PrimarySmtpAddress = 'slpeng@example.com'
    RecipientTypeDetails = 'UserMailbox'
}
$script:MockGroup = [pscustomobject]@{
    Guid = '22222222-2222-2222-2222-222222222222'
    Name = 'test'; PrimarySmtpAddress = 'test@example.com'
    RecipientTypeDetails = 'MailUniversalDistributionGroup'
}
$Mocks = @'
function Initialize-ExchangeShell { }
function Get-Mailbox {
    [CmdletBinding()] param($Identity, $DomainController)
    if ($script:Scenario -eq 'new' -and $script:Writes -eq 0) { return }
    if ($script:Scenario -eq 'missing-user') {
        $record = New-Object System.Management.Automation.ErrorRecord ([System.Exception]::new('not found')), 'ManagementObjectNotFoundException', 'ObjectNotFound', $Identity
        $PSCmdlet.ThrowTerminatingError($record)
    }
    return $script:MockMailbox
}
function Get-Recipient { [CmdletBinding()] param($Identity) }
function Get-User { [CmdletBinding()] param($Identity, $DomainController) }
function Get-DistributionGroup {
    [CmdletBinding()] param($Identity, $DomainController, $ResultSize, $RecipientTypeDetails)
    if ($script:Scenario -eq 'denied') { throw [System.UnauthorizedAccessException]::new('do not suppress this error') }
    if ($script:Scenario -eq 'missing-group') {
        $record = New-Object System.Management.Automation.ErrorRecord ([System.Exception]::new('not found')), 'ManagementObjectNotFoundException', 'ObjectNotFound', $Identity
        $PSCmdlet.ThrowTerminatingError($record)
    }
    return $script:MockGroup
}
function Get-DistributionGroupMember {
    [CmdletBinding()] param($Identity, $DomainController, $ResultSize)
    if ($script:Member) { return $script:MockMailbox }
}
function Add-DistributionGroupMember {
    [CmdletBinding()] param($Identity, $Member, $DomainController, [switch]$BypassSecurityGroupManagerCheck)
    $script:Writes++
    $script:Member = $true
}
function Remove-DistributionGroupMember {
    [CmdletBinding(SupportsShouldProcess)] param($Identity, $Member, $DomainController, [switch]$BypassSecurityGroupManagerCheck)
    $script:Writes++
    $script:Member = $false
}
function New-Mailbox {
    [CmdletBinding()] param($Name, $FirstName, $Alias, $SamAccountName, $DisplayName, $UserPrincipalName, $PrimarySmtpAddress,
        [System.Security.SecureString]$Password, $ResetPasswordOnNextLogon, $OrganizationalUnit, $Database, $DomainController)
    $script:Writes++
    if ($null -eq $Password) { throw 'missing secure password' }
    return $script:MockMailbox
}
'@

function Invoke-Scenario {
    param([string] $Operation, [string] $Scenario, [hashtable] $Parameters)
    $script:Scenario = $Scenario
    $script:Writes = 0
    $command = [scriptblock]::Create($Sources.'common.ps1' + "`n" + $Mocks + "`n" + $Sources.$Operation)
    $output = @(& $command @Parameters)
    if ($output.Count -ne 1) { throw "Expected one result, got $($output.Count)" }
    return ($output[0] | ConvertFrom-Json)
}
function Assert-Test {
    param([string] $Name, [bool] $Condition)
    if (-not $Condition) { throw "Regression failed: $Name" }
    $script:Passed += $Name
}

foreach ($property in $Sources.PSObject.Properties) {
    if ($property.Name -eq 'common.ps1') { continue }
    $tokens = $null; $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($Sources.'common.ps1' + "`n" + $property.Value, [ref]$tokens, [ref]$parseErrors)
    Assert-Test "syntax/$($property.Name)" ($parseErrors.Count -eq 0)
}
$identity = @{ LoginName = 'slpeng'; UserPrincipalName = 'slpeng@example.com' }
$membership = @{ MemberIdentity = [string]$script:MockMailbox.Guid; GroupIdentity = [string]$script:MockGroup.Guid }

$script:MockMailbox.SamAccountName = 'someoneelse'
$result = Invoke-Scenario 'discover_user_groups.ps1' 'normal' $identity
Assert-Test 'reject alias resolving to wrong account' (-not $result.ok -and $result.code -eq 'RECIPIENT_CONFLICT' -and $script:Writes -eq 0)
$script:MockMailbox.SamAccountName = 'slpeng'
$script:MockMailbox.UserPrincipalName = 'slpeng@another.example'
$result = Invoke-Scenario 'discover_user_groups.ps1' 'normal' $identity
Assert-Test 'reject wrong UPN' (-not $result.ok -and $result.code -eq 'RECIPIENT_CONFLICT')
$script:MockMailbox.UserPrincipalName = 'slpeng@example.com'

$result = Invoke-Scenario 'discover_user_groups.ps1' 'missing-user' $identity
Assert-Test 'classify explicit not found' (-not $result.ok -and $result.code -eq 'USER_NOT_FOUND')
$result = Invoke-Scenario 'remove_group_member.ps1' 'denied' $membership
Assert-Test 'do not treat denied lookup as removed group' (-not $result.ok -and $result.code -eq 'EXCHANGE_COMMAND_FAILED' -and $script:Writes -eq 0)
$result = Invoke-Scenario 'remove_group_member.ps1' 'missing-group' $membership
Assert-Test 'missing group removal is idempotent' ($result.ok -and -not $result.data.removed -and $script:Writes -eq 0)

$script:MockGroup.RecipientTypeDetails = 'MailUniversalSecurityGroup'
$result = Invoke-Scenario 'resolve_groups.ps1' 'normal' @{ GroupIdentities = @('test') }
Assert-Test 'reject mail-enabled security groups during preflight' (-not $result.ok -and $result.code -eq 'GROUP_TYPE_NOT_ALLOWED')
$result = Invoke-Scenario 'remove_group_member.ps1' 'normal' $membership
Assert-Test 'recheck group type before removal' (-not $result.ok -and $result.code -eq 'GROUP_TYPE_NOT_ALLOWED' -and $script:Writes -eq 0)
$script:MockGroup.RecipientTypeDetails = 'MailUniversalDistributionGroup'

$result = Invoke-Scenario 'resolve_groups.ps1' 'normal' @{ GroupIdentities = @('test', 'test@example.com') }
Assert-Test 'canonical GUID deduplication' ($result.ok -and $result.data.groups.Count -eq 1)
$script:Member = $false
$result = Invoke-Scenario 'ensure_group_member.ps1' 'normal' $membership
Assert-Test 'add exact GUID and verify membership' ($result.ok -and $result.data.added -and $script:Writes -eq 1)
$result = Invoke-Scenario 'ensure_group_member.ps1' 'normal' $membership
Assert-Test 'repeated add does not write' ($result.ok -and -not $result.data.added -and $script:Writes -eq 0)
$result = Invoke-Scenario 'remove_group_member.ps1' 'normal' $membership
Assert-Test 'remove exact GUID and verify absence' ($result.ok -and $result.data.removed -and $script:Writes -eq 1)
$result = Invoke-Scenario 'remove_group_member.ps1' 'normal' $membership
Assert-Test 'repeated removal does not write' ($result.ok -and -not $result.data.removed -and $script:Writes -eq 0)

$create = @{ LoginName = 'slpeng'; UserPrincipalName = 'slpeng@example.com'; PrimarySmtpAddress = 'slpeng@example.com'; DisplayName = 'Test {{ 7 * 7 }}'; DomainController = 'dc.example.com' }
$result = Invoke-Scenario 'ensure_mailbox.ps1' 'normal' $create
Assert-Test 'existing mailbox retry needs no password' ($result.ok -and -not $result.data.created -and $script:Writes -eq 0)
$create.DisplayName = 'Different'
$result = Invoke-Scenario 'ensure_mailbox.ps1' 'normal' $create
Assert-Test 'display name mismatch returns conflict' (-not $result.ok -and $result.code -eq 'RECIPIENT_CONFLICT')
$create.DisplayName = 'Test {{ 7 * 7 }}'
$result = Invoke-Scenario 'ensure_mailbox.ps1' 'new' $create
Assert-Test 'new account requires password before mutation' (-not $result.ok -and $result.code -eq 'INVALID_REQUEST' -and $script:Writes -eq 0)
$create.InitialPassword = ConvertTo-SecureString 'Test9!{{7*7}}' -AsPlainText -Force
$result = Invoke-Scenario 'ensure_mailbox.ps1' 'new' $create
Assert-Test 'new account creation confirmed by readback' ($result.ok -and $result.data.created -and $script:Writes -eq 1)
Assert-Test 'restricted recipient lookup does not require DomainController permission' $result.ok
@{ ok = $true; passed = $script:Passed; count = $script:Passed.Count } | ConvertTo-Json -Depth 4 -Compress
