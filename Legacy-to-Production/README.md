# KACE Agent Migration: Legacy SMA to Production

## Purpose and deployment history

`Migrate-KACE.ps1` removes a specific legacy KACE Agent and installs a token-bearing production agent on Windows endpoints selected in the legacy SMA.

This repository contains an environment-neutral version of the migration approach. A test-SMA-to-production migration using this approach was reported successful by the operator. This legacy-to-production variant uses the same independent-worker approach, with legacy-specific version, product-code, and source-host checks. That prior success does not establish compatibility with every legacy endpoint. The placeholder version is a sanitized template, not a separate record of a completed deployment.

The deployment packages discussed for this workflow used legacy agent **11.0.119** and destination agent **15.1.55**. The destination SMA server version was **15.1.177**. Server and agent versions are different; this script installs the agent, not an SMA server update.

## Why an independent worker is used

The legacy agent delivers the migration script, but it cannot remain the controlling process throughout its own removal. The script first stages the installer and a copy of itself locally, then launches a Windows scheduled task running as SYSTEM. That task performs the uninstall and install independently of the legacy SMA agent.

No remote file share is required once the legacy agent has delivered both dependencies.

## Repository and private deployment files

Commit the sanitized `Migrate-KACE.ps1` and this README. Keep the production ZIP, token-bearing MSI, endpoint logs, and any environment-specific copy containing private configuration outside the repository.

The legacy SMA script requires two dependencies:

| File | Purpose |
| --- | --- |
| `Migrate-KACE.ps1` | Configured deployment copy of the script |
| `Production-KACE-Agent.zip` | Contains exactly one production MSI at the ZIP root |

Keep the MSI's original filename. The script expects `ampagent-<AGENT_VERSION>-x64_<PRODUCTION_SMA_FQDN>+<TOKEN>.msi` and extracts the enrollment token from it at runtime. Do not rename the MSI to a generic name or place it inside a nested folder in the ZIP.

## Configure the placeholders

Replace all placeholders in a private deployment copy before uploading it to the legacy SMA. The script refuses to run if required values still contain angle brackets or are blank.

| Variable | Required value |
| --- | --- |
| `$SourceHost` | Exact legacy SMA hostname recorded in the endpoint's `amp.conf` |
| `$TargetHost` | Production SMA hostname matching the token-bearing MSI filename |
| `$SourceVersion` | Exact installed legacy agent version |
| `$SourceProductCode` | Legacy MSI product GUID, including braces |
| `$TargetVersion` | Production agent version, not the SMA server version |
| `$TargetProductCode` | Expected production MSI product GUID, including braces |
| `$ExpectedSha256` | SHA-256 of the actual production MSI inside the ZIP |

Obtain source version and product code from the Windows uninstall registry entries, not `Win32_Product`. Verify the source host in `C:\ProgramData\Quest\KACE\amp.conf`. Use `Get-FileHash -Algorithm SHA256` against the production MSI before packaging it.

The hash is checked against the extracted MSI, not the ZIP. The script validates the configured GUID and hash formats, but those checks cannot establish that the values belong to the intended package. Verify them against the actual deployment files.

## Legacy SMA script configuration

Use the legacy SMA to target the intended Windows devices or device label. The script contains no individual computer-name restriction. Each selected endpoint must satisfy its source-agent and source-host checks.

Configure the script as follows:

| Setting | Value |
| --- | --- |
| Execution identity | Local System |
| Dependencies | Configured `Migrate-KACE.ps1` and `Production-KACE-Agent.zip` |
| Attempts | 1 |
| On failure | Break |
| Verify | Always Fail, so the remediation launches |
| Remediation | Launch 64-bit Windows PowerShell and wait for completion |

For the 32-bit legacy agent on 64-bit Windows, the launch path used for this workflow is:

```text
C:\Windows\Sysnative\WindowsPowerShell\v1.0\powershell.exe
```

Parameters:

```text
-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(KACE_DEPENDENCY_DIR)\Migrate-KACE.ps1"
```

Do not add `-Worker` to the SMA launch command. Only the locally created scheduled task passes that switch. If the launching process is already 64-bit, use the native `System32` PowerShell path instead of `Sysnative`.

## Execution sequence

1. Require a 64-bit AMD64 Windows PowerShell process running as SYSTEM.
2. Require exactly one KACE Agent matching the configured legacy version, product code, and source SMA hostname.
3. Stop if the staging folder or migration task already exists.
4. Create the staging folder and restrict inherited permissions, granting SYSTEM and local Administrators full control.
5. Extract the ZIP and copy the script to the staging folder.
6. Verify the MSI filename, extract its enrollment token, and verify its SHA-256.
7. Check TCP 443 connectivity to the production hostname.
8. Register and start an independent SYSTEM scheduled task.
9. The worker acquires a named mutex, waits 15 seconds, and repeats the installer, legacy-agent, and production-connectivity checks.
10. Uninstall the legacy agent silently and verify that its uninstall registration is gone.
11. Install the production agent silently with the production `HOST` and extracted `TOKEN` properties.
12. Verify the production agent's version and product code, then poll `amp.conf` for the production hostname for approximately one minute.
13. Write the outcome to the local migration log.

## Completion and evidence

**A successful legacy SMA script result means that staging completed and the independent worker was launched. It does not prove migration completion.**

The sanitized template uses:

| Item | Default |
| --- | --- |
| Staging folder | `C:\ProgramData\KACE-AgentMigration` |
| Scheduled task | `KACE-Legacy-to-Production` |
| Migration log | `Migration.log` in the staging folder |
| Uninstall log | `Legacy-Agent-Uninstall.log` in the staging folder |
| Install log | `Production-Agent-Install.log` in the staging folder |

These generic names differ from the private environment-specific script's staging path and task name. When troubleshooting an actual deployment, use the values in the deployed script.

Confirm all of the following:

- The migration log reports the expected agent version installed and production host assignment verified.
- The installed agent registry entry matches the destination version and product code.
- `amp.conf` points to the production SMA.
- The device appears in production inventory and reports a fresh inventory/check-in.

The final inventory check is required because a successful installation and local host assignment do not prove successful enrollment or communication with the production SMA.

## Stop conditions and limitations

- A mismatched source agent or hostname stops the script before removal. An already migrated agent therefore fails the source checks rather than being deliberately removed again.
- Failed production DNS resolution or TCP 443 connectivity stops the script before removal. Reachability can still change after this check.
- TCP 443 reachability does not verify TLS trust, enrollment-token validity, or all agent communication requirements.
- Any nonzero MSI exit code stops the worker. Exit code `3010` is recorded as requiring a reboot; the script does not reboot or automatically continue. After an install returning `3010`, the new agent may already be installed, so inspect the logs before acting.
- A failed installation after a successful uninstall can leave the endpoint without a KACE Agent. There is no automatic rollback or retry.
- Existing staging files or a task block a new staging attempt. Review the previous outcome before manually removing them. The script does not automatically clean up its artifacts.
- The scheduled task has a two-hour execution limit. It has no recurring trigger; the script starts it on demand.
- Other deployment systems must not reinstall the legacy agent during migration. In the earlier migration work, conflicting SCCM agent deployment was disabled on affected devices.
- The script checks one configured source agent version and product code. Other legacy versions require their own verified configuration.
- This script does not migrate asset assignments, labels, custom fields, patch policies, or SMA configuration. Those are separate appliance-side migration tasks.

## Handling secrets and logs

The installer filename contains an enrollment token. The extracted token is also passed to Windows Installer, and verbose MSI logs may expose sensitive properties or filenames. Treat the ZIP, MSI, staging folder, and all migration logs as private. Redact them before sharing with support or committing any troubleshooting evidence.

## Scope of this README

This document describes the supplied script and the operator-reported successful migration approach. It does not claim Quest certification or independent testing of the sanitized template. A KACE technician reviewing a specific run should receive the deployed script version, redacted logs, and production inventory evidence through an appropriate private channel.
