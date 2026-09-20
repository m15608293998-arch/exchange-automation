try {
    Initialize-ExchangeShell
    $resolved = @()
    $seen = @{}
    foreach ($identity in $GroupIdentities) {
        $group = Get-OptionalObject { Get-DistributionGroup -Identity $identity @script:DirectoryParameters }
        if ($null -eq $group) { Stop-Automation 'GROUP_NOT_FOUND' }
        Assert-DistributionGroup $group
        $guid = [string]$group.Guid
        if (-not $seen.ContainsKey($guid)) {
            $resolved += @{ identity = $guid; label = (Get-GroupLabel $group) }
            $seen[$guid] = $true
        }
    }
    Write-AutomationResult @{ groups = @($resolved) }
}
catch { Write-AutomationFailure $_ }
finally { Close-ExchangeShell }
