param(
    [Parameter(Mandatory = $true)]
    [string] $GroupIdentity,

    [Parameter(Mandatory = $true)]
    [string] $MemberIdentity,

    [bool] $BypassGroupManagerCheck = $true
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Initialize-ExchangeShell {
    if ($null -ne (Get-Command 'Get-DistributionGroup' -ErrorAction SilentlyContinue)) {
        return
    }
    $serverFqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    $exchangeUri = "http://$serverFqdn/PowerShell/"
    $exchangeSession = New-PSSession -ConfigurationName 'Microsoft.Exchange' -ConnectionUri $exchangeUri -Authentication Kerberos
    $null = Import-PSSession -Session $exchangeSession -DisableNameChecking -AllowClobber -WarningAction SilentlyContinue
}

function Get-GroupLabel {
    param([object] $Group)
    if (-not [string]::IsNullOrWhiteSpace([string]$Group.PrimarySmtpAddress)) {
        return [string]$Group.PrimarySmtpAddress
    }
    return [string]$Group.Name
}

function Test-GroupMembership {
    param([object] $Group, [object] $Recipient)
    $members = @(Get-DistributionGroupMember -Identity $Group.Identity -ResultSize Unlimited)
    return @($members | Where-Object { $_.Guid -eq $Recipient.Guid }).Count -gt 0
}

function Write-AutomationResult {
    param([bool] $OK, [string] $Code, [string] $Message, [object] $Data)
    [ordered]@{ ok = $OK; code = $Code; message = $Message; data = $Data } | ConvertTo-Json -Depth 8 -Compress
}

try {
    Initialize-ExchangeShell

    $recipient = Get-Mailbox -Identity $MemberIdentity -ErrorAction SilentlyContinue
    if ($null -eq $recipient) {
        Write-AutomationResult -OK $false -Code 'USER_NOT_FOUND' -Message 'The mailbox was not found.' -Data $null
        return
    }

    $group = Get-DistributionGroup -Identity $GroupIdentity -ErrorAction SilentlyContinue
    if ($null -eq $group) {
        Write-AutomationResult -OK $true -Code '' -Message 'The group no longer exists; no membership remains.' -Data ([ordered]@{ group = $GroupIdentity; removed = $false })
        return
    }

    $groupLabel = Get-GroupLabel -Group $group
    if (-not (Test-GroupMembership -Group $group -Recipient $recipient)) {
        Write-AutomationResult -OK $true -Code '' -Message 'Recipient is already absent from the group.' -Data ([ordered]@{ group = $groupLabel; removed = $false })
        return
    }

    $removeParameters = @{ Identity = $group.Identity; Member = $recipient.Identity; Confirm = $false }
    if ($BypassGroupManagerCheck) {
        $removeParameters['BypassSecurityGroupManagerCheck'] = $true
    }

    try {
        Remove-DistributionGroupMember @removeParameters
    }
    catch {
        if (-not (Test-GroupMembership -Group $group -Recipient $recipient)) {
            Write-AutomationResult -OK $true -Code '' -Message 'Recipient was removed from the group concurrently.' -Data ([ordered]@{ group = $groupLabel; removed = $false })
            return
        }
        throw
    }

    Write-AutomationResult -OK $true -Code '' -Message 'Recipient was removed from the group.' -Data ([ordered]@{ group = $groupLabel; removed = $true })
}
catch {
    Write-AutomationResult -OK $false -Code 'EXCHANGE_COMMAND_FAILED' -Message $_.Exception.Message -Data $null
}
