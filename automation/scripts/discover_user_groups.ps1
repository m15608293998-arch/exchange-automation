try {
    Initialize-ExchangeShell
    $mailbox = Get-OptionalObject { Get-Mailbox -Identity $LoginName @script:DirectoryParameters }
    Assert-MailboxIdentity $mailbox
    $memberships = @()
    # Query the member backlink on the server instead of reading every group's roster.
    # The DN comes from the verified mailbox; escape OPATH single-quoted literals.
    $memberDn = ([string]$mailbox.DistinguishedName).Replace("'", "''")
    if ([string]::IsNullOrWhiteSpace($memberDn)) { Stop-Automation 'EXCHANGE_COMMAND_FAILED' }
    $groups = @(Get-DistributionGroup -Filter "Members -eq '$memberDn'" -RecipientTypeDetails MailUniversalDistributionGroup -ResultSize Unlimited @script:DirectoryParameters)
    foreach ($group in $groups) {
        Assert-DistributionGroup $group
        $memberships += @{ identity = [string]$group.Guid; label = (Get-GroupLabel $group) }
    }
    Write-AutomationResult @{ mailbox_id = [string]$mailbox.Guid; groups = @($memberships | Sort-Object -Property label) }
}
catch { Write-AutomationFailure $_ }
finally { Close-ExchangeShell }
