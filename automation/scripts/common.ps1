# Prepended to each operation by the local Python bridge. Parameters are bound as data.
param(
    [string] $LoginName,
    [string] $DisplayName,
    [string] $UserPrincipalName,
    [string] $PrimarySmtpAddress,
    [System.Security.SecureString] $InitialPassword,
    [string] $OrganizationalUnit,
    [string] $MailboxDatabase,
    [string] $DomainController,
    [string[]] $GroupIdentities = @(),
    [string] $GroupIdentity,
    [string] $MemberIdentity,
    [bool] $ResetPasswordOnNextLogon = $false,
    [bool] $BypassGroupManagerCheck = $true
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:ExchangeSession = $null
$script:MutationStarted = $false
$script:DirectoryParameters = @{ ErrorAction = 'Stop' }
if (-not [string]::IsNullOrWhiteSpace($DomainController)) {
    $script:DirectoryParameters['DomainController'] = $DomainController
}

function Initialize-ExchangeShell {
    $serverFqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    $script:ExchangeSession = New-PSSession -ConfigurationName 'Microsoft.Exchange' -ConnectionUri "http://$serverFqdn/PowerShell/" -Authentication Kerberos -ErrorAction Stop
    $module = Import-PSSession -Session $script:ExchangeSession -DisableNameChecking -AllowClobber -WarningAction SilentlyContinue -ErrorAction Stop
    Import-Module $module -Global -Force -ErrorAction Stop
}

function Close-ExchangeShell {
    if ($null -ne $script:ExchangeSession) {
        Remove-PSSession -Session $script:ExchangeSession -ErrorAction SilentlyContinue
    }
}

function Stop-Automation {
    param([string] $Code)
    $exception = New-Object System.InvalidOperationException $Code
    $exception.Data['AutomationCode'] = $Code
    throw $exception
}

function Get-OptionalObject {
    param([scriptblock] $Query)
    try {
        $objects = @(& $Query)
        if ($objects.Count -gt 1) { Stop-Automation 'RECIPIENT_CONFLICT' }
        if ($objects.Count -eq 0) { return $null }
        return $objects[0]
    }
    catch {
        # Only this explicit Exchange exception denotes absence. Authorization,
        # ambiguous identity, DC and remoting errors must propagate.
        if ($_.CategoryInfo.Reason -eq 'ManagementObjectNotFoundException' -or
            $_.FullyQualifiedErrorId -match '(^|[,])ManagementObjectNotFoundException([,]|$)') {
            return $null
        }
        throw
    }
}

function Assert-MailboxIdentity {
    param([object] $Mailbox)
    if ($null -eq $Mailbox) { Stop-Automation 'USER_NOT_FOUND' }
    if ([string]$Mailbox.RecipientTypeDetails -ne 'UserMailbox' -or
        -not ([string]$Mailbox.SamAccountName).Equals($LoginName, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$Mailbox.UserPrincipalName).Equals($UserPrincipalName, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-Automation 'RECIPIENT_CONFLICT'
    }
}

function Get-OptionalRecipient {
    param([string] $Identity)
    $parameters = @{ ErrorAction = 'Stop' }
    # Some restricted Exchange RBAC roles omit DomainController specifically on
    # Get-Recipient. This read-only collision check can use its default scope.
    # Mailbox creation/readback and group mutations still use the configured DC.
    if (-not [string]::IsNullOrWhiteSpace($DomainController) -and
        (Get-Command Get-Recipient -ErrorAction Stop).Parameters.ContainsKey('DomainController')) {
        $parameters['DomainController'] = $DomainController
    }
    return (Get-OptionalObject { Get-Recipient -Identity $Identity @parameters })
}

function Assert-Guid {
    param([string] $Value)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        Stop-Automation 'INVALID_REQUEST'
    }
}

function Get-TargetMailbox {
    Assert-Guid $MemberIdentity
    $mailbox = Get-OptionalObject { Get-Mailbox -Identity $MemberIdentity @script:DirectoryParameters }
    if ($null -eq $mailbox) { Stop-Automation 'USER_NOT_FOUND' }
    if ([string]$mailbox.Guid -ne $MemberIdentity -or [string]$mailbox.RecipientTypeDetails -ne 'UserMailbox') {
        Stop-Automation 'RECIPIENT_CONFLICT'
    }
    return $mailbox
}

function Assert-DistributionGroup {
    param([object] $Group)
    if ([string]$Group.RecipientTypeDetails -ne 'MailUniversalDistributionGroup') {
        Stop-Automation 'GROUP_TYPE_NOT_ALLOWED'
    }
}

function Get-TargetGroup {
    Assert-Guid $GroupIdentity
    $group = Get-OptionalObject { Get-DistributionGroup -Identity $GroupIdentity @script:DirectoryParameters }
    if ($null -ne $group) {
        if ([string]$group.Guid -ne $GroupIdentity) { Stop-Automation 'RECIPIENT_CONFLICT' }
        Assert-DistributionGroup $group
    }
    return $group
}

function Get-GroupLabel {
    param([object] $Group)
    if (-not [string]::IsNullOrWhiteSpace([string]$Group.PrimarySmtpAddress)) { return [string]$Group.PrimarySmtpAddress }
    return [string]$Group.Name
}

function Test-GroupMembership {
    param([object] $Group, [object] $Recipient)
    $members = @(Get-DistributionGroupMember -Identity ([string]$Group.Guid) -ResultSize Unlimited @script:DirectoryParameters)
    return @($members | Where-Object { [string]$_.Guid -eq [string]$Recipient.Guid }).Count -gt 0
}

function Write-AutomationResult {
    param([object] $Data)
    [ordered]@{ ok = $true; data = $Data } | ConvertTo-Json -Depth 8 -Compress
}

function Write-AutomationFailure {
    param([System.Management.Automation.ErrorRecord] $Record)
    $code = [string]$Record.Exception.Data['AutomationCode']
    $messages = @{
        INVALID_REQUEST = 'A required parameter is missing or invalid; initial_password is required for a new account.'
        USER_NOT_FOUND = 'The mailbox was not found.'
        GROUP_NOT_FOUND = 'A requested distribution group was not found.'
        GROUP_TYPE_NOT_ALLOWED = 'Only ordinary static mail-enabled universal distribution groups are allowed.'
        RECIPIENT_CONFLICT = 'An existing object does not match the requested account, UPN, address, display name or object type.'
        EXCHANGE_COMMAND_FAILED = 'Exchange command failed; verify RBAC, directory connectivity and server diagnostics.'
    }
    if (-not $messages.ContainsKey($code)) { $code = 'EXCHANGE_COMMAND_FAILED' }
    # Never return raw Exchange exceptions, which can contain bound arguments.
    [ordered]@{ ok = $false; code = $code; message = $messages[$code]; error_type = [string]$Record.CategoryInfo.Reason; state_unknown = $script:MutationStarted; data = $null } | ConvertTo-Json -Depth 8 -Compress
}
