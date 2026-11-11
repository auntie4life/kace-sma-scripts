
# Migrate-KACE.ps1
# Legacy SMA -> production SMA for devices selected in the legacy SMA.
#
# Dependencies:
#   Migrate-KACE.ps1
#   Production-KACE-Agent.zip
#
# ZIP contents: production 15.1.55 MSI directly inside the ZIP.
# Run as SYSTEM using 64-bit Windows PowerShell.
# Do not pass -Worker from KACE.
#
# No automatic reboot, retry, or rollback.
# Installation failure after removal can leave the device without an agent.
# Keep staged files and MSI logs private.

param(
    [switch]$Worker
)

$ErrorActionPreference = 'Stop'

$SourceHost = 'kam.fhcrc.org'
$TargetHost = 'kace.fhcrc.org'

$SourceVersion = '11.0.119'
$SourceProductCode = '{C0C1F33D-4660-4AEF-A07B-3B115B7CAE33}'

$TargetVersion = '15.1.55'
$TargetProductCode = '{947DE5F5-A2DC-4E00-8C3C-3B9DC68C779B}'
$ExpectedSha256 = 'EFC5C0D01B9F6E4DF25B88F1903488AA3D15379D762B2CDBA20791ABE3C04FFE'

$ZipName = 'Production-KACE-Agent.zip'
$Stage = 'C:\Tech\KACELegacyToProduction'
$TaskName = 'RSSI-KACE-Legacy-to-Production'
$StagedScript = Join-Path $Stage 'Migrate-KACE.ps1'
$LogPath = Join-Path $Stage 'Migration.log'
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$AgentConfig = 'C:\ProgramData\Quest\KACE\amp.conf'

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
        throw 'Installed agent does not match legacy 11.0.119 and its expected product code.'
    }

    if ((Get-AssignedHost) -ne $SourceHost) {
        throw 'Agent is not assigned to kam.fhcrc.org. No removal attempted.'
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
    $Pattern = '^ampagent-15\.1\.55-x64_kace\.fhcrc\.org\+(?<Token>[A-Za-z0-9_-]+)\.msi$'

    if ($Installer.Name -notmatch $Pattern) {
        throw 'MSI filename does not match the production 15.1.55 installer.'
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
    'Global\RSSI-KACE-Legacy-to-Production'
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

    Write-MigrationLog 'Agent 15.1.55 installed and production host assignment verified.'
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
