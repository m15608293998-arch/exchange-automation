try {
    Initialize-ExchangeShell
    $recipient = Get-TargetMailbox
    $group = Get-TargetGroup
    if ($null -eq $group) { Stop-Automation 'GROUP_NOT_FOUND' }
    $data = @{ group = (Get-GroupLabel $group); group_id = [string]$group.Guid; member_id = [string]$recipient.Guid; added = $false }
    if (-not (Test-GroupMembership $group $recipient)) {
        $parameters = @{ Identity = $GroupIdentity; Member = $MemberIdentity }
        if ($BypassGroupManagerCheck) { $parameters['BypassSecurityGroupManagerCheck'] = $true }
        $script:MutationStarted = $true
        try {
            Add-DistributionGroupMember @parameters @script:DirectoryParameters
            $data.added = $true
        }
        catch {
            if (-not (Test-GroupMembership $group $recipient)) { throw }
        }
        if (-not (Test-GroupMembership $group $recipient)) { throw 'Membership verification failed.' }
    }
    Write-AutomationResult $data
}
catch { Write-AutomationFailure $_ }
finally { Close-ExchangeShell }
