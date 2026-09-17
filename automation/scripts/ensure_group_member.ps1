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
    if ([string]::IsNullOrWhiteSpace($env:ExchangeInstallPath)) {
        throw 'ExchangeInstallPath is not defined on the target server.'
    }
    $remoteExchange = Join-Path $env:ExchangeInstallPath 'bin\RemoteExchange.ps1'
    if (-not (Test-Path -LiteralPath $remoteExchange)) {
        throw 'Exchange Management Shell bootstrap script was not found.'
    }
    . $remoteExchange *> $null
    Connect-ExchangeServer -Auto -ClientApplication:ManagementShell *> $null
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

    $group = Get-DistributionGroup -Identity $GroupIdentity -ErrorAction SilentlyContinue
    if ($null -eq $group) {
        Write-AutomationResult -OK $false -Code 'GROUP_NOT_FOUND' -Message 'The static Exchange distribution group was not found.' -Data $null
        return
    }

    $recipient = Get-Recipient -Identity $MemberIdentity -ErrorAction SilentlyContinue
    if ($null -eq $recipient) {
        Write-AutomationResult -OK $false -Code 'USER_NOT_FOUND' -Message 'The Exchange recipient was not found.' -Data $null
        return
    }

    $groupLabel = Get-GroupLabel -Group $group
    if (Test-GroupMembership -Group $group -Recipient $recipient) {
        Write-AutomationResult -OK $true -Code '' -Message 'Recipient is already a group member.' -Data ([ordered]@{ group = $groupLabel; added = $false })
        return
    }

    $addParameters = @{ Identity = $group.Identity; Member = $recipient.Identity }
    if ($BypassGroupManagerCheck) {
        $addParameters['BypassSecurityGroupManagerCheck'] = $true
    }

    try {
        Add-DistributionGroupMember @addParameters
    }
    catch {
        if (Test-GroupMembership -Group $group -Recipient $recipient) {
            Write-AutomationResult -OK $true -Code '' -Message 'Recipient became a group member concurrently.' -Data ([ordered]@{ group = $groupLabel; added = $false })
            return
        }
        throw
    }

    Write-AutomationResult -OK $true -Code '' -Message 'Recipient was added to the group.' -Data ([ordered]@{ group = $groupLabel; added = $true })
}
catch {
    Write-AutomationResult -OK $false -Code 'EXCHANGE_COMMAND_FAILED' -Message $_.Exception.Message -Data $null
}
