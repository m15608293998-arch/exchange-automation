# Environment-collector regression. No AD/Exchange queries or writes here.
param([string] $SourceText, [string] $SourcePath)
$ErrorActionPreference = 'Stop'
if (-not $SourceText) {
    if (-not $SourcePath) { $SourcePath = Join-Path $PSScriptRoot '../../deployment/Get-ExchangeEnvironment.ps1' }
    $SourceText = Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8
}
$SourceText = $SourceText.TrimStart([char]0xFEFF)
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($SourceText, [ref]$tokens, [ref]$errors)
$script:Tests = @()
function Assert-Test([string] $Name, [bool] $Condition) {
    if (-not $Condition) { throw "Collector regression failed: $Name" }
    $script:Tests += $Name
}
Assert-Test 'PowerShell 5.1 syntax' ($errors.Count -eq 0)
Assert-Test 'no administrator input parameters' ($ast.ParamBlock.Parameters.Count -eq 0)
$functions = @($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $true))
Assert-Test 'one output helper only' ($functions.Count -eq 1 -and $functions[0].Name -eq 'Show-Query')
$commands = @($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]}, $true))
$allowed = @('Get-Command', 'Write-Output', 'Format-List', 'Out-String', 'Show-Query',
    'Get-CimInstance', 'Select-Object', 'Get-ItemProperty', 'Get-ExecutionPolicy', 'Get-ExchangeServer',
    'Get-Item', 'Join-Path', 'ForEach-Object', 'Get-MailboxDatabase', 'Get-AcceptedDomain',
    'Get-EmailAddressPolicy', 'Get-PowerShellVirtualDirectory', 'Get-ExchangeCertificate',
    'Where-Object', 'Get-Service', 'Get-ManagementRole', 'Get-ManagementRoleEntry', 'Get-ManagementScope')
$static = @($commands | Where-Object { $null -ne $_.GetCommandName() })
Assert-Test 'all invoked commands are approved reads or output formatting' (@($static | Where-Object { $allowed -notcontains $_.GetCommandName() }).Count -eq 0)
$dynamic = @($commands | Where-Object { $null -eq $_.GetCommandName() })
Assert-Test 'only dynamic call executes a fixed query scriptblock' ($dynamic.Count -eq 1 -and $dynamic[0].Extent.Text -eq '& $Query')
$members = @($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]}, $true))
Assert-Test 'member calls cannot save mutate download or run processes' (@($members | Where-Object { $_.Member.Value -notin @('ToString', 'GetComputerDomain', 'FindDomainController', 'Dispose') }).Count -eq 0)
Assert-Test 'no file redirection in collector' (@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.RedirectionAst]}, $true)).Count -eq 0)
$sections = @($static | Where-Object { $_.GetCommandName() -eq 'Show-Query' })
Assert-Test 'thirteen explicit sections' ($sections.Count -eq 13)
foreach ($section in $sections) {
    Assert-Test ('fixed query block: ' + $section.CommandElements[1].Value) ($section.CommandElements.Count -eq 3 -and $section.CommandElements[2] -is [System.Management.Automation.Language.ScriptBlockExpressionAst])
    $number = $section.CommandElements[1].Value.Substring(0, 2)
    Assert-Test ('comment exists for section ' + $number) ($SourceText -match ('(?m)^# ' + $number + '[^\r\n]+'))
}
. ([scriptblock]::Create($functions[0].Extent.Text))
$sample = (Show-Query 'sample' { [pscustomobject]@{ Name = 'DB-A'; Mounted = $true } }) -join "`n"
Assert-Test 'query values remain readable' ($sample -match 'DB-A' -and $sample -match 'True')
$failure = (Show-Query 'expected-failure' { throw 'simulated-read-failure' }) -join "`n"
Assert-Test 'one failed query does not terminate collection' ($failure -match 'expected-failure' -and $failure -match 'simulated-read-failure')
$later = (Show-Query 'later' { 'subsequent-section-ran' }) -join "`n"
Assert-Test 'subsequent query still runs' ($later -match 'subsequent-section-ran')
$empty = (Show-Query 'empty' { }) -join "`n"
Assert-Test 'empty section retains its heading' ($empty -match 'empty')
$long = 'a' * 500 + 'end-of-role-parameters'
$longOutput = (Show-Query 'long' { [pscustomobject]@{ Parameters = $long } }) -join "`n"
Assert-Test 'role parameter text is not truncated' ($longOutput -match 'end-of-role-parameters')
[pscustomobject]@{ passed = $script:Tests.Count; tests = $script:Tests; directory_queries = 0; server_writes = 0 } | ConvertTo-Json -Depth 4 -Compress
