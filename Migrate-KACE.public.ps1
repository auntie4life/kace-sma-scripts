# Migrate-KACE.ps1
#
# ONE-COMPUTER PILOT:
# Legacy agent 11.0.119 -> agent 15.1.55 on sma.example.invalid
#
# Legacy KACE dependencies:
#   Migrate-KACE.ps1
#   Agent-Bundle.zip
#
# ZIP contents: the specified MSI directly inside the ZIP.
#
# Run as Local System using 64-bit Windows PowerShell.
# Do not pass -Worker from KACE.
#
# No automatic reboot, retry, or rollback is performed.
# The independent scheduled task remains available for inspection.
# Protect the staged files and logs because they contain the test token.

param(
    [switch]$Worker
)

# SANITIZED REVIEW COPY. Reconfigure and remove this guard only after review.
throw 'Review-only sanitized template. Configure and validate before deployment.'
$ErrorActionPreference = 'Stop'

# ---------- Pilot configuration ----------
$PilotComputerName = 'REPLACE_WITH_PILOT_COMPUTER'
$ExpectedSha256 = 'REPLACE_WITH_MSI_SHA256'

$ZipName = 'Agent-Bundle.zip'
$MsiName = 'ampagent-15.1.55-x64_sma.example.invalid+REPLACE_WITH_AGENT_TOKEN.msi'

$TargetHost = 'sma.example.invalid'
$ExpectedNewVersion = '15.1.55'
$LegacyVersion = '11.0.119'
$LegacyProductCode = '{REPLACE_WITH_LEGACY_PRODUCT_CODE}'

$TargetToken = [IO.Path]::GetFileNameWithoutExtension($MsiName).Split('+', 2)[1]

$Stage = 'C:\ProgramData\MigrationExample'
$TaskName = 'Example-KACE-Agent-Migration'
$StagedScript = Join-Path $Stage 'Migrate-KACE.ps1'
$MsiPath = Join-Path $Stage $MsiName
$LogPath = Join-Path $Stage 'Migration.log'
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

# ---------- Functions ----------
function Write-MigrationLog {
    param([string]$Message)

    Add-Content -LiteralPath $LogPath -Value `
        "$(Get-Date -Format o) $Message"
}

function Get-KaceAgent {
    $Paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty -Path $Paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'KACE Agent' }
}

function Assert-LegacyAgent {
    $Agent = @(Get-KaceAgent)

    if ($Agent.Count -ne 1) {
        throw 'Expected exactly one installed KACE Agent. No uninstall attempted.'
    }

    if ($Agent[0].DisplayVersion -ne $LegacyVersion -or
        $Agent[0].PSChildName -ne $LegacyProductCode) {
        throw 'Installed agent does not match the expected legacy version and product code.'
    }
}

function Assert-StagedInstaller {
    if (-not (Test-Path -LiteralPath $MsiPath -PathType Leaf)) {
        throw "Expected MSI is missing: $MsiPath"
    }

    $ActualHash = (
        Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256
    ).Hash

    if ($ActualHash -ne $ExpectedSha256) {
        throw 'MSI hash mismatch. Stop before uninstalling anything.'
    }
}

function Assert-TargetReachable {
    # TCP reachability only. Does not validate the token or enrollment.
    $Reachable = Test-NetConnection -ComputerName $TargetHost `
        -Port 443 -InformationLevel Quiet `
        -WarningAction SilentlyContinue

    if (-not $Reachable) {
        throw 'Test SMA HTTPS connection failed. No uninstall attempted.'
    }
}

function Invoke-Msi {
    param(
        [string]$Arguments,
        [string]$Operation
    )

    $Process = Start-Process `
        -FilePath "$env:SystemRoot\System32\msiexec.exe" `
        -ArgumentList $Arguments -Wait -PassThru

    Write-MigrationLog "$Operation exit code: $($Process.ExitCode)"

    if ($Process.ExitCode -eq 3010) {
        throw "$Operation requires a reboot. No reboot initiated. Stop and review."
    }

    if ($Process.ExitCode -ne 0) {
        throw "$Operation failed with code $($Process.ExitCode). Review MSI logs."
    }
}

# ---------- Safety checks ----------
if ($env:COMPUTERNAME -ne $PilotComputerName) {
    throw "Wrong computer. This script is restricted to $PilotComputerName."
}

if (-not [Environment]::Is64BitProcess -or
    $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'Use 64-bit Windows PowerShell on an AMD64 Windows endpoint.'
}

$CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

if ($CurrentSid -ne 'S-1-5-18') {
    throw 'Run this script as Local System.'
}

if ([string]::IsNullOrWhiteSpace($TargetToken)) {
    throw 'Test token could not be read from the MSI filename.'
}

# ---------- Stage files and launch independent worker ----------
if (-not $Worker) {
    Assert-LegacyAgent

    if (Test-Path -LiteralPath $Stage) {
        throw "Staging folder already exists. Review the previous attempt: $Stage"
    }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        throw 'Migration task already exists. Review before retrying.'
    }

    $SourceZip = Join-Path $PSScriptRoot $ZipName

    if (-not (Test-Path -LiteralPath $SourceZip -PathType Leaf)) {
        throw "ZIP dependency is missing: $SourceZip"
    }

    New-Item -Path $Stage -ItemType Directory -Force | Out-Null

    # Restrict the staging folder to SYSTEM and Administrators.
    & "$env:SystemRoot\System32\icacls.exe" $Stage `
        /inheritance:r `
        /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' |
        Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to secure the staging folder.'
    }

    try {
        Expand-Archive -LiteralPath $SourceZip -DestinationPath $Stage

        Copy-Item -LiteralPath $PSCommandPath `
            -Destination $StagedScript -Force

        Assert-StagedInstaller
        Assert-TargetReachable

        $Action = New-ScheduledTaskAction `
            -Execute $PowerShellExe `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$StagedScript`" -Worker" `
            -WorkingDirectory $Stage

        $Principal = New-ScheduledTaskPrincipal `
            -UserId 'SYSTEM' `
            -LogonType ServiceAccount `
            -RunLevel Highest

        $Settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries

        Register-ScheduledTask -TaskName $TaskName `
            -Action $Action `
            -Principal $Principal `
            -Settings $Settings |
            Out-Null

        Write-MigrationLog 'Staging completed. Launching independent worker.'

        Start-ScheduledTask -TaskName $TaskName

        Write-Output 'Independent migration task launched.'
        Write-Output 'This confirms staging only, not completed migration.'
        Write-Output "Review $LogPath and inventory in the test SMA."
        exit 0
    }
    catch {
        Write-MigrationLog "STAGING STOPPED: $($_.Exception.Message)"
        throw
    }
}

# ---------- Independent migration worker ----------
$Mutex = New-Object System.Threading.Mutex(
    $false,
    'Global\Example-KACE-Agent-Migration'
)

$LockHeld = $false
$WorkerExitCode = 1

try {
    $LockHeld = $Mutex.WaitOne(0)

    if (-not $LockHeld) {
        throw 'Another migration worker is already running.'
    }

    Write-MigrationLog "Worker started on $env:COMPUTERNAME."

    Assert-StagedInstaller
    Assert-LegacyAgent
    Assert-TargetReachable

    # Remove legacy agent without initiating a Windows Installer reboot.
    $UninstallLog = Join-Path $Stage 'Legacy-Uninstall.log'

    Invoke-Msi -Operation 'Legacy uninstall' -Arguments `
        "/x $LegacyProductCode /qn /norestart /L*v `"$UninstallLog`""

    if (@(Get-KaceAgent).Count -ne 0) {
        throw 'KACE Agent registration remains after uninstall. Stop and review.'
    }

    # Install test agent without initiating a Windows Installer reboot.
    $InstallLog = Join-Path $Stage 'Test-Agent-Install.log'

    Invoke-Msi -Operation 'Test agent install' -Arguments `
        "/i `"$MsiPath`" /qn /norestart HOST=`"$TargetHost`" TOKEN=`"$TargetToken`" /L*v `"$InstallLog`""

    $Agent = @(Get-KaceAgent)

    if ($Agent.Count -ne 1 -or
        $Agent[0].DisplayVersion -ne $ExpectedNewVersion) {
        throw 'Expected test agent version was not found after installation.'
    }

    Write-MigrationLog 'Agent 15.1.55 installation completed.'
    Write-MigrationLog 'Verify server assignment, running services, and successful inventory in the test SMA.'

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