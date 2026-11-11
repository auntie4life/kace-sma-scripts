
# Migrate-KACE.ps1
# Migrates a supported legacy KACE Agent to a production SMA.
#
# Dependencies, stored together:
#   Migrate-KACE.ps1
#   Production-KACE-Agent.zip
#
# ZIP contents:
#   Exactly one production MSI directly inside the ZIP.
#   Preserve its original token-bearing filename.
#
# Run as SYSTEM using 64-bit Windows PowerShell.
# Do not pass -Worker from KACE.
#
# No automatic reboot, retry, or rollback.
# Installation failure after removal can leave the device without an agent.
#
# Git:
#   Commit this script only.
#   Keep token-bearing installers, ZIP files, and migration logs out of Git.

param(
    [switch]$Worker
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Environment configuration: replace every <PLACEHOLDER> before deployment.
# Agent versions are separate from the SMA server version.
# ---------------------------------------------------------------------------

$SourceHost = '<LEGACY_SMA_FQDN>'
$TargetHost = '<PRODUCTION_SMA_FQDN>'

$SourceVersion = '<LEGACY_AGENT_VERSION>'
$SourceProductCode = '<LEGACY_AGENT_PRODUCT_CODE_WITH_BRACES>'

$TargetVersion = '<PRODUCTION_AGENT_VERSION>'
$TargetProductCode = '<PRODUCTION_AGENT_PRODUCT_CODE_WITH_BRACES>'
$ExpectedSha256 = '<PRODUCTION_MSI_SHA256>'

# ---------------------------------------------------------------------------
# Deployment configuration
# ---------------------------------------------------------------------------

$ZipName = 'Production-KACE-Agent.zip'
$Stage = 'C:\ProgramData\KACE-AgentMigration'
$TaskName = 'KACE-Legacy-to-Production'
$MutexName = 'Global\KACE-Legacy-to-Production'

$StagedScript = Join-Path $Stage 'Migrate-KACE.ps1'
$LogPath = Join-Path $Stage 'Migration.log'
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$AgentConfig = 'C:\ProgramData\Quest\KACE\amp.conf'

# Stop before making changes if placeholders remain.
$RequiredValues = @{
    SourceHost        = $SourceHost
    TargetHost        = $TargetHost
    SourceVersion     = $SourceVersion
    SourceProductCode = $SourceProductCode
    TargetVersion     = $TargetVersion
    TargetProductCode = $TargetProductCode
    ExpectedSha256    = $ExpectedSha256
}

foreach ($Entry in $RequiredValues.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($Entry.Value) -or
        $Entry.Value -match '[<>]') {
        throw "Configure $($Entry.Key) before deployment."
    }
}

foreach ($ProductCode in @($SourceProductCode, $TargetProductCode)) {
    if ($ProductCode -notmatch '^\{[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$') {
        throw 'Product codes must be valid GUIDs enclosed in braces.'
    }
}

if ($ExpectedSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
    throw 'ExpectedSha256 must contain exactly 64 hexadecimal characters.'
}

function Write-MigrationLog {
    param([string]$Message)

    Add-Content -LiteralPath $LogPath -Value (
        '{0} {1}' -f (Get-Date -Format o), $Message
    )
}

function Get-KaceAgent {
    Get-ItemProperty -Path @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    ) -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'KACE Agent' }
}

function Get-AssignedHost {
    $Entries = @(
        Get-Content -LiteralPath $AgentConfig -ErrorAction Stop |
            Where-Object { $_ -match '^\s*host\s*=' }
    )

    if ($Entries.Count -ne 1) {
        throw 'Expected exactly one host entry in amp.conf.'
    }

    return (($Entries[0] -split '=', 2)[1]).Trim()
}

function Assert-LegacyAgent {
    $Agent = @(Get-KaceAgent)

    if ($Agent.Count -ne 1) {
        throw 'Expected exactly one installed KACE Agent.'
    }

    if ($Agent[0].DisplayVersion -ne $SourceVersion -or
        $Agent[0].PSChildName -ne $SourceProductCode) {
        throw 'Installed agent does not match the configured legacy version and product code.'
    }

    if ((Get-AssignedHost) -ne $SourceHost) {
        throw 'Agent is not assigned to the configured legacy SMA. No removal attempted.'
    }
}

function Get-VerifiedInstaller {
    $Installers = @(
        Get-ChildItem -LiteralPath $Stage -File -Filter '*.msi'
    )

    if ($Installers.Count -ne 1) {
        throw 'Expected exactly one MSI directly inside the staging folder.'
    }

    $Installer = $Installers[0]
    $VersionPattern = [regex]::Escape($TargetVersion)
    $HostPattern = [regex]::Escape($TargetHost)

    $Pattern = (
        '^ampagent-{0}-x64_{1}\+(?<Token>[A-Za-z0-9_-]+)\.msi$' -f
        $VersionPattern, $HostPattern
    )

    if ($Installer.Name -notmatch $Pattern) {
        throw 'MSI filename does not match the configured production host and agent version.'
    }

    $EnrollmentToken = $Matches['Token']

    if ((Get-FileHash -LiteralPath $Installer.FullName -Algorithm SHA256).Hash -ne
        $ExpectedSha256) {
        throw 'Production MSI SHA-256 mismatch. No removal attempted.'
    }

    return [PSCustomObject]@{
        Path  = $Installer.FullName
        Token = $EnrollmentToken
    }
}

function Assert-ProductionReachable {
    if (-not (Test-NetConnection -ComputerName $TargetHost -Port 443 `
        -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        throw 'Production SMA TCP port 443 is unreachable. No removal attempted.'
    }

    # TCP reachability does not validate certificates or enrollment.
}

function Invoke-Msi {
    param(
        [string]$Arguments,
        [string]$Operation
    )

    $Process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" `
        -ArgumentList $Arguments -Wait -PassThru

    Write-MigrationLog "$Operation exit code: $($Process.ExitCode)"

    if ($Process.ExitCode -eq 3010) {
        throw "$Operation requires a reboot. No reboot initiated. Review before continuing."
    }

    if ($Process.ExitCode -ne 0) {
        throw "$Operation returned $($Process.ExitCode). Review the MSI log."
    }
}

if (-not [Environment]::Is64BitProcess -or
    $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'Use 64-bit Windows PowerShell on an AMD64 Windows endpoint.'
}

if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') {
    throw 'Run this script as Local System.'
}

if (-not $Worker) {
    Assert-LegacyAgent

    if (Test-Path -LiteralPath $Stage) {
        throw "Staging folder already exists. Review before retrying: $Stage"
    }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        throw 'Migration task already exists. Review before retrying.'
    }

    $SourceZip = Join-Path $PSScriptRoot $ZipName

    if (-not (Test-Path -LiteralPath $SourceZip -PathType Leaf)) {
        throw "Missing dependency: $ZipName"
    }

    New-Item -Path $Stage -ItemType Directory | Out-Null

    & "$env:SystemRoot\System32\icacls.exe" $Stage /inheritance:r `
        /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' |
        Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to secure the staging folder.'
    }

    try {
        Expand-Archive -LiteralPath $SourceZip -DestinationPath $Stage
        Copy-Item -LiteralPath $PSCommandPath -Destination $StagedScript -Force

        $null = Get-VerifiedInstaller
        Assert-ProductionReachable

        $Action = New-ScheduledTaskAction -Execute $PowerShellExe `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$StagedScript`" -Worker" `
            -WorkingDirectory $Stage

        $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
            -LogonType ServiceAccount -RunLevel Highest

        $Settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

        Register-ScheduledTask -TaskName $TaskName -Action $Action `
            -Principal $Principal -Settings $Settings | Out-Null

        Write-MigrationLog "Staged on $env:COMPUTERNAME. Launching independent worker."
        Start-ScheduledTask -TaskName $TaskName

        Write-Output 'Independent worker launched. This confirms staging only.'
        Write-Output "Review $LogPath and verify inventory in the production SMA."
        exit 0
    }
    catch {
        Write-MigrationLog "STAGING STOPPED: $($_.Exception.Message)"
        throw
    }
}

$Mutex = New-Object System.Threading.Mutex(
    $false,
    $MutexName
)

$LockHeld = $false
$WorkerExitCode = 1

try {
    $LockHeld = $Mutex.WaitOne(0)

    if (-not $LockHeld) {
        throw 'Another migration worker is already running.'
    }

    Start-Sleep -Seconds 15
    Write-MigrationLog "Worker started on $env:COMPUTERNAME."

    $Installer = Get-VerifiedInstaller
    Assert-LegacyAgent
    Assert-ProductionReachable

    $UninstallLog = Join-Path $Stage 'Legacy-Agent-Uninstall.log'

    Invoke-Msi -Operation 'Legacy agent uninstall' -Arguments (
        "/x $SourceProductCode /qn /norestart REBOOT=ReallySuppress /L*v `"$UninstallLog`""
    )

    if (@(Get-KaceAgent).Count -ne 0) {
        throw 'KACE Agent registration remains after uninstall. Stop and review.'
    }

    $InstallLog = Join-Path $Stage 'Production-Agent-Install.log'

    Invoke-Msi -Operation 'Production agent install' -Arguments (
        "/i `"$($Installer.Path)`" /qn /norestart REBOOT=ReallySuppress " +
        "HOST=`"$TargetHost`" TOKEN=`"$($Installer.Token)`" /L*v `"$InstallLog`""
    )

    $Agent = @(Get-KaceAgent)

    if ($Agent.Count -ne 1 -or
        $Agent[0].DisplayVersion -ne $TargetVersion -or
        $Agent[0].PSChildName -ne $TargetProductCode) {
        throw 'Expected production agent registration was not found after installation.'
    }

    $AssignmentVerified = $false

    for ($Attempt = 0; $Attempt -lt 12; $Attempt++) {
        try {
            if ((Get-AssignedHost) -eq $TargetHost) {
                $AssignmentVerified = $true
                break
            }
        }
        catch {
            # Configuration may not exist yet.
        }

        Start-Sleep -Seconds 5
    }

    if (-not $AssignmentVerified) {
        throw 'Installation returned success, but production host assignment was not verified.'
    }

    Write-MigrationLog "Agent $TargetVersion installed and production host assignment verified."
    Write-MigrationLog 'Enrollment and successful inventory must still be verified in production.'

    $WorkerExitCode = 0
}
catch {
    Write-MigrationLog "WORKER STOPPED: $($_.Exception.Message)"
}
finally {
    if ($LockHeld) {
        $Mutex.ReleaseMutex()
    }

    $Mutex.Dispose()
}

exit $WorkerExitCode
