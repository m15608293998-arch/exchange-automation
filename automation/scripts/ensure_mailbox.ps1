function Write-MailboxResult {
    param([object] $Mailbox, [bool] $Created)
    Assert-MailboxIdentity $Mailbox
    if (-not ([string]$Mailbox.PrimarySmtpAddress).Equals($PrimarySmtpAddress, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$Mailbox.DisplayName).Equals($DisplayName, [System.StringComparison]::Ordinal)) {
        Stop-Automation 'RECIPIENT_CONFLICT'
    }
    Write-AutomationResult @{
        created = $Created
        mailbox_id = [string]$Mailbox.Guid
        login_name = [string]$Mailbox.SamAccountName
        display_name = [string]$Mailbox.DisplayName
        user_principal_name = [string]$Mailbox.UserPrincipalName
        primary_smtp_address = [string]$Mailbox.PrimarySmtpAddress
    }
}
try {
    Initialize-ExchangeShell
    $mailbox = Get-OptionalObject { Get-Mailbox -Identity $LoginName @script:DirectoryParameters }
    if ($null -eq $mailbox) {
        $mailbox = Get-OptionalObject { Get-Mailbox -Identity $UserPrincipalName @script:DirectoryParameters }
    }
    if ($null -ne $mailbox) {
        Write-MailboxResult $mailbox $false
        return
    }
    $recipientByLogin = Get-OptionalRecipient $LoginName
    $recipientByAddress = Get-OptionalRecipient $PrimarySmtpAddress
    $userByLogin = Get-OptionalObject { Get-User -Identity $LoginName @script:DirectoryParameters }
    $userByUPN = Get-OptionalObject { Get-User -Identity $UserPrincipalName @script:DirectoryParameters }
    if ($null -ne $recipientByLogin -or $null -ne $recipientByAddress -or $null -ne $userByLogin -or $null -ne $userByUPN) {
        Stop-Automation 'RECIPIENT_CONFLICT'
    }
    if ($null -eq $InitialPassword -or $InitialPassword.Length -eq 0) { Stop-Automation 'INVALID_REQUEST' }
    $parameters = @{
        Name = $LoginName
        FirstName = $LoginName
        Alias = $LoginName
        SamAccountName = $LoginName
        DisplayName = $DisplayName
        UserPrincipalName = $UserPrincipalName
        PrimarySmtpAddress = $PrimarySmtpAddress
        Password = $InitialPassword
        ResetPasswordOnNextLogon = $ResetPasswordOnNextLogon
    }
    if (-not [string]::IsNullOrWhiteSpace($OrganizationalUnit)) { $parameters['OrganizationalUnit'] = $OrganizationalUnit }
    if (-not [string]::IsNullOrWhiteSpace($MailboxDatabase)) { $parameters['Database'] = $MailboxDatabase }
    $script:MutationStarted = $true
    $created = New-Mailbox @parameters @script:DirectoryParameters
    $mailbox = Get-Mailbox -Identity ([string]$created.Guid) @script:DirectoryParameters
    Write-MailboxResult $mailbox $true
}
catch { Write-AutomationFailure $_ }
finally { Close-ExchangeShell }
