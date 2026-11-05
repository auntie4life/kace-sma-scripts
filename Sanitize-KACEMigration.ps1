<#
Creates a separate review-only copy of the supplied migration pilot.
Never executes the migration or changes the original.
Example: .\Sanitize-KACEMigration.ps1 -InputPath .\Migrate-KACE.ps1 -OutputPath .\Migrate-KACE.public.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$Source = (Resolve-Path -LiteralPath $InputPath).ProviderPath
$Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ($Source -eq $Destination) { throw 'Choose a different output file.' }
if (Test-Path -LiteralPath $Destination) { throw 'Output already exists. Choose a new filename.' }
$Text = [IO.File]::ReadAllText($Source)
# Values come from the source. No real identifiers are embedded in this sanitizer.
$Settings = [ordered]@{
    PilotComputerName = 'REPLACE_WITH_PILOT_COMPUTER'
    ExpectedSha256 = 'REPLACE_WITH_MSI_SHA256'
    ZipName = 'Agent-Bundle.zip'
    MsiName = 'ampagent-15.1.55-x64_sma.example.invalid+REPLACE_WITH_AGENT_TOKEN.msi'
    TargetHost = 'sma.example.invalid'
    LegacyProductCode = '{REPLACE_WITH_LEGACY_PRODUCT_CODE}'
    Stage = 'C:\ProgramData\MigrationExample'
    TaskName = 'Example-KACE-Agent-Migration'
}
$Replacements = @{}
foreach ($Name in $Settings.Keys) {
    $Pattern = '(?m)^\s*\$' + [regex]::Escape($Name) + '\s*=\s*''(?<value>[^''\r\n]+)''\s*\r?$'
    $MatchesFound = [regex]::Matches($Text, $Pattern)
    if ($MatchesFound.Count -ne 1) {
        throw "Expected exactly one literal assignment for $Name. No output written."
    }
    $Old = $MatchesFound[0].Groups['value'].Value
    if ($Old.Length -lt 4) { throw "Unexpected short value for $Name. No output written." }
    $Replacements[$Old] = $Settings[$Name]
    if ($Name -eq 'MsiName') {
        $Parts = [IO.Path]::GetFileNameWithoutExtension($Old).Split('+', 2)
        if ($Parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($Parts[1])) {
            throw 'Expected a customized MSI filename containing a token. No output written.'
        }
        $Replacements[$Parts[1]] = 'REPLACE_WITH_AGENT_TOKEN'
    }
}
# Replace longer values first, including repetitions in comments and mutex names.
foreach ($Old in @($Replacements.Keys | Sort-Object -Property Length -Descending)) {
    $Text = $Text.Replace($Old, $Replacements[$Old])
}
foreach ($Old in $Replacements.Keys) {
    if ($Text.Contains($Old)) { throw 'A configured identifier remains. No output written.' }
}
# Insert after param(), preserving PowerShell's script parameter syntax.
$Guard = @'
# SANITIZED REVIEW COPY. Reconfigure and remove this guard only after review.
throw 'Review-only sanitized template. Configure and validate before deployment.'
'@
$Anchor = '$ErrorActionPreference = ''Stop'''
if (-not $Text.Contains($Anchor)) { throw 'Expected safety insertion point missing. No output written.' }
$Text = $Text.Replace($Anchor, $Guard + "`r`n" + $Anchor)
$Tokens = $null
$ParseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count -gt 0) { throw 'Sanitized output has syntax errors. No output written.' }
$Stream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
try {
    $Bytes = (New-Object System.Text.UTF8Encoding($true)).GetBytes($Text)
    $Stream.Write($Bytes, 0, $Bytes.Length)
}
finally { $Stream.Dispose() }
Write-Output "Created review-only copy: $Destination"
Write-Output 'Original unchanged. Review the entire copy before sharing.'
