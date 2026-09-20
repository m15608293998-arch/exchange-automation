try {
    Initialize-ExchangeShell
    $mailbox = Get-OptionalObject { Get-Mailbox -Identity $LoginName @script:DirectoryParameters }
    Assert-MailboxIdentity $mailbox
    $memberships = @()
    $groups = @(Get-DistributionGroup -RecipientTypeDetails MailUniversalDistributionGroup -ResultSize Unlimited @script:DirectoryParameters)
    foreach ($group in $groups) {
        Assert-DistributionGroup $group
        if (Test-GroupMembership $group $mailbox) {
            $memberships += @{ identity = [string]$group.Guid; label = (Get-GroupLabel $group) }
        }
    }
    Write-AutomationResult @{ mailbox_id = [string]$mailbox.Guid; groups = @($memberships | Sort-Object -Property label) }
}
catch { Write-AutomationFailure $_ }
finally { Close-ExchangeShell }
