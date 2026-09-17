param(
    [Parameter(Mandatory = $true)]
    [string] $LoginName
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

function Write-AutomationResult {
    param([bool] $OK, [string] $Code, [string] $Message, [object] $Data)
    [ordered]@{ ok = $OK; code = $Code; message = $Message; data = $Data } | ConvertTo-Json -Depth 8 -Compress
}

try {
    Initialize-ExchangeShell

    $mailbox = Get-Mailbox -Identity $LoginName -ErrorAction SilentlyContinue
    if ($null -eq $mailbox) {
        Write-AutomationResult -OK $false -Code 'USER_NOT_FOUND' -Message 'The mailbox was not found.' -Data $null
        return
    }

    $memberships = @()
    $groups = @(Get-DistributionGroup -ResultSize Unlimited)
    foreach ($group in $groups) {
        $members = @(Get-DistributionGroupMember -Identity $group.Identity -ResultSize Unlimited)
        if (@($members | Where-Object { $_.Guid -eq $mailbox.Guid }).Count -gt 0) {
            $memberships += [ordered]@{
                identity = [string]$group.Guid
                label    = (Get-GroupLabel -Group $group)
            }
        }
    }

    $memberships = @($memberships | Sort-Object -Property label)
    Write-AutomationResult -OK $true -Code '' -Message 'Static distribution group memberships were discovered.' -Data ([ordered]@{ groups = $memberships })
}
catch {
    Write-AutomationResult -OK $false -Code 'EXCHANGE_COMMAND_FAILED' -Message $_.Exception.Message -Data $null
}
