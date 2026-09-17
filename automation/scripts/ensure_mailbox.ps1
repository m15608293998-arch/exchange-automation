param(
    [Parameter(Mandatory = $true)]
    [string] $LoginName,

    [Parameter(Mandatory = $true)]
    [string] $DisplayName,

    [Parameter(Mandatory = $true)]
    [string] $UserPrincipalName,

    [Parameter(Mandatory = $true)]
    [string] $PrimarySmtpAddress,

    [Parameter(Mandatory = $true)]
    [System.Security.SecureString] $InitialPassword,

    [AllowEmptyString()]
    [string] $OrganizationalUnit = '',

    [AllowEmptyString()]
    [string] $MailboxDatabase = '',

    [bool] $ResetPasswordOnNextLogon = $false
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Initialize-ExchangeShell {
    if ($null -ne (Get-Command 'Get-Mailbox' -ErrorAction SilentlyContinue)) {
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

    if ($null -eq (Get-Command 'Get-Mailbox' -ErrorAction SilentlyContinue)) {
        throw 'Exchange Management Shell cmdlets are unavailable.'
    }
}

function Write-AutomationResult {
    param(
        [bool] $OK,
        [string] $Code,
        [string] $Message,
        [object] $Data
    )

    [ordered]@{
        ok      = $OK
        code    = $Code
        message = $Message
        data    = $Data
    } | ConvertTo-Json -Depth 8 -Compress
}

try {
    Initialize-ExchangeShell

    $mailbox = Get-Mailbox -Identity $LoginName -ErrorAction SilentlyContinue
    if ($null -eq $mailbox) {
        $mailbox = Get-Mailbox -Identity $UserPrincipalName -ErrorAction SilentlyContinue
    }

    if ($null -ne $mailbox) {
        $sameLogin = ([string]$mailbox.SamAccountName).Equals($LoginName, [System.StringComparison]::OrdinalIgnoreCase)
        $sameAddress = ([string]$mailbox.PrimarySmtpAddress).Equals($PrimarySmtpAddress, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not ($sameLogin -and $sameAddress)) {
            Write-AutomationResult -OK $false -Code 'RECIPIENT_CONFLICT' -Message 'An existing mailbox uses the requested login name or address but does not match the requested identity.' -Data $null
            return
        }

        Write-AutomationResult -OK $true -Code '' -Message 'Mailbox already exists.' -Data ([ordered]@{
            created              = $false
            login_name           = [string]$mailbox.SamAccountName
            display_name         = [string]$mailbox.DisplayName
            primary_smtp_address = [string]$mailbox.PrimarySmtpAddress
        })
        return
    }

    $recipientByLogin = Get-Recipient -Identity $LoginName -ErrorAction SilentlyContinue
    $recipientByAddress = Get-Recipient -Identity $PrimarySmtpAddress -ErrorAction SilentlyContinue
    $userByLogin = Get-User -Identity $LoginName -ErrorAction SilentlyContinue
    if (($null -ne $recipientByLogin) -or ($null -ne $recipientByAddress) -or ($null -ne $userByLogin)) {
        Write-AutomationResult -OK $false -Code 'RECIPIENT_CONFLICT' -Message 'The requested login name or email address is already assigned to another AD or Exchange recipient.' -Data $null
        return
    }

    $newMailboxParameters = @{
        Name                     = $LoginName
        FirstName                = $LoginName
        DisplayName              = $DisplayName
        Alias                    = $LoginName
        SamAccountName           = $LoginName
        UserPrincipalName        = $UserPrincipalName
        PrimarySmtpAddress       = $PrimarySmtpAddress
        Password                 = $InitialPassword
        ResetPasswordOnNextLogon = $ResetPasswordOnNextLogon
    }
    if (-not [string]::IsNullOrWhiteSpace($OrganizationalUnit)) {
        $newMailboxParameters['OrganizationalUnit'] = $OrganizationalUnit
    }
    if (-not [string]::IsNullOrWhiteSpace($MailboxDatabase)) {
        $newMailboxParameters['Database'] = $MailboxDatabase
    }

    try {
        $mailbox = New-Mailbox @newMailboxParameters
    }
    catch {
        $newMailboxError = $_
        $mailbox = Get-Mailbox -Identity $LoginName -ErrorAction SilentlyContinue
        if ($null -eq $mailbox) {
            throw $newMailboxError
        }

        $sameLogin = ([string]$mailbox.SamAccountName).Equals($LoginName, [System.StringComparison]::OrdinalIgnoreCase)
        $sameAddress = ([string]$mailbox.PrimarySmtpAddress).Equals($PrimarySmtpAddress, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not ($sameLogin -and $sameAddress)) {
            throw $newMailboxError
        }

        Write-AutomationResult -OK $true -Code '' -Message 'Mailbox was created concurrently by another request.' -Data ([ordered]@{
            created              = $false
            login_name           = [string]$mailbox.SamAccountName
            display_name         = [string]$mailbox.DisplayName
            primary_smtp_address = [string]$mailbox.PrimarySmtpAddress
        })
        return
    }

    Write-AutomationResult -OK $true -Code '' -Message 'Mailbox was created.' -Data ([ordered]@{
        created              = $true
        login_name           = [string]$mailbox.SamAccountName
        display_name         = [string]$mailbox.DisplayName
        primary_smtp_address = [string]$mailbox.PrimarySmtpAddress
    })
}
catch {
    Write-AutomationResult -OK $false -Code 'EXCHANGE_COMMAND_FAILED' -Message $_.Exception.Message -Data $null
}
