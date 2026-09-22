# Python sends one JSON request on stdin. No request data is used as PowerShell code.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$operations = @{
    resolve_groups = 'resolve_groups.ps1'
    ensure_mailbox = 'ensure_mailbox.ps1'
    ensure_group_member = 'ensure_group_member.ps1'
    discover_user_groups = 'discover_user_groups.ps1'
    remove_group_member = 'remove_group_member.ps1'
}
$mutation = $false
try {
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
    $operation = [string]$request.operation
    if (-not $operations.ContainsKey($operation) -or $null -eq $request.parameters) {
        throw 'Unsupported operation or missing parameters.'
    }
    $mutation = $operation -in @('ensure_mailbox', 'ensure_group_member', 'remove_group_member')

    $parameters = @{}
    foreach ($property in $request.parameters.PSObject.Properties) {
        $parameters[$property.Name] = $property.Value
    }
    if ($parameters.ContainsKey('InitialPassword') -and $parameters['InitialPassword']) {
        $parameters['InitialPassword'] = ConvertTo-SecureString ([string]$parameters['InitialPassword']) -AsPlainText -Force
    }
    elseif ($parameters.ContainsKey('InitialPassword')) {
        $null = $parameters.Remove('InitialPassword')
    }

    $scripts = Join-Path $PSScriptRoot '..\scripts'
    $common = Get-Content -LiteralPath (Join-Path $scripts 'common.ps1') -Raw -Encoding UTF8
    $business = Get-Content -LiteralPath (Join-Path $scripts $operations[$operation]) -Raw -Encoding UTF8
    $script = [scriptblock]::Create($common + "`n" + $business)
    $output = @(& $script @parameters)
    if ($output.Count -ne 1 -or $output[0] -isnot [string]) {
        throw 'Exchange operation returned an invalid result.'
    }
    [Console]::Out.WriteLine($output[0])
}
catch {
    # Raw errors can include bound arguments. Return only a fixed message and type.
    $failure = @{
        ok = $false
        code = 'EXCHANGE_COMMAND_FAILED'
        message = 'Exchange command failed; inspect server diagnostics.'
        error_type = [string]$_.Exception.GetType().Name
        state_unknown = $mutation
        data = $null
    }
    [Console]::Out.WriteLine(($failure | ConvertTo-Json -Compress))
}
