# Run in Windows PowerShell 5.1. All Exchange file reads and commands are mocked.
param([string] $BridgeText)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($BridgeText)) {
    $BridgeText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\local\Invoke-ExchangeOperation.ps1') -Raw -Encoding UTF8
}
$tokens = $null; $errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput($BridgeText, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw "Bridge syntax errors: $($errors.Count)" }

# Replace only console I/O and the source directory so the bridge can run inside
# this isolated test runspace without reading files or creating an Exchange session.
$testBridge = $BridgeText.Replace('[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)', '')
$testBridge = $testBridge.Replace('[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)', '')
$testBridge = $testBridge.Replace('[Console]::In.ReadToEnd()', '$RequestJSON')
$testBridge = $testBridge.Replace('$PSScriptRoot', "'C:\bridge'")
$testBridge = $testBridge.Replace('[Console]::Out.WriteLine($output[0])', 'Write-Output $output[0]')
$testBridge = $testBridge.Replace('[Console]::Out.WriteLine(($failure | ConvertTo-Json -Compress))', 'Write-Output ($failure | ConvertTo-Json -Compress)')
$mockCommon = @'
param([string]$LoginName, [string]$DisplayName, [securestring]$InitialPassword,
      [string[]]$GroupIdentities, [string]$DomainController)
'@
$mockBusiness = @'
@{ ok = $true; data = @{
    login_name = $LoginName
    display_name = $DisplayName
    secure_password = ($InitialPassword -is [securestring])
    group_count = @($GroupIdentities).Count
    domain_controller = $DomainController
} } | ConvertTo-Json -Depth 4 -Compress
'@
function Get-Content {
    param($LiteralPath, [switch]$Raw, $Encoding)
    if ([string]$LiteralPath -like '*common.ps1') { return $mockCommon }
    return $mockBusiness
}
$RequestJSON = '{"operation":"ensure_mailbox","parameters":{"LoginName":"alice","DisplayName":"测试员工","InitialPassword":"Test!123","DomainController":"dc.example.com"}}'
$result = & ([scriptblock]::Create($testBridge)) | ConvertFrom-Json
if (-not $result.ok -or -not $result.data.secure_password -or $result.data.display_name -ne '测试员工' -or
    $result.data.domain_controller -ne 'dc.example.com') { throw "SecureString/Unicode parameter binding failed: $($result | ConvertTo-Json -Compress -Depth 4)" }
$RequestJSON = '{"operation":"resolve_groups","parameters":{"GroupIdentities":["app","dev"],"DomainController":"dc.example.com"}}'
$result = & ([scriptblock]::Create($testBridge)) | ConvertFrom-Json
if (-not $result.ok -or $result.data.group_count -ne 2) { throw 'Group array parameter binding failed.' }
$RequestJSON = '{"operation":"ensure_mailbox","parameters":{"LoginName":"alice","InitialPassword":"","DomainController":"dc.example.com"}}'
$output = @(& ([scriptblock]::Create($testBridge)))
if ($output.Count -ne 1) { throw 'Empty-password retry emitted extra output.' }
$result = $output[0] | ConvertFrom-Json
if (-not $result.ok -or $result.data.secure_password) { throw 'Empty-password retry was not bound as optional.' }
@{ ok = $true; checks = 4 } | ConvertTo-Json -Compress
