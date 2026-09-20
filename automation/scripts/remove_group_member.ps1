try {
    Initialize-ExchangeShell
    $recipient = Get-TargetMailbox
    $group = Get-TargetGroup
    $data = @{ group = $GroupIdentity; group_id = $GroupIdentity; member_id = [string]$recipient.Guid; removed = $false }
    if ($null -ne $group) {
        $data.group = Get-GroupLabel $group
        if (Test-GroupMembership $group $recipient) {
            $parameters = @{ Identity = $GroupIdentity; Member = $MemberIdentity; Confirm = $false }
            if ($BypassGroupManagerCheck) { $parameters['BypassSecurityGroupManagerCheck'] = $true }
            $script:MutationStarted = $true
            try {
                Remove-DistributionGroupMember @parameters @script:DirectoryParameters
                $data.removed = $true
            }
            catch {
                if (Test-GroupMembership $group $recipient) { throw }
            }
            if (Test-GroupMembership $group $recipient) { throw 'Membership verification failed.' }
        }
    }
    Write-AutomationResult $data
}
catch { Write-AutomationFailure $_ }
finally { Close-ExchangeShell }
