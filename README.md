# KACE-SMA-v15-Scripts

PowerShell scripts and validation notes for moving from a legacy Quest KACE SMA environment to SMA v15. This repository supports team knowledge sharing and technical review with Quest KACE representatives.

## Agent migration pilot

`Migrate-KACE.ps1` removes legacy Windows agent **11.0.119** and installs agent **15.1.55** on one explicitly configured pilot computer. It stages its files locally and launches an independent scheduled task running as SYSTEM so migration can continue after removal of the legacy agent.

Both MSI operations use `/qn /norestart`. The script initiates no automatic reboot, retry, or rollback. Exit code **3010** stops the workflow for review because a reboot is required. If removal succeeds but installation fails, the endpoint may need recovery outside KACE.

## Files

- `Migrate-KACE.ps1`: pilot migration script. Use a sanitized copy for external review.
- `Sanitize-KACEMigration.ps1`: creates a separate review-only copy with configured identifiers replaced by placeholders.
- Agent ZIP: private deployment dependency containing the configured MSI directly at the ZIP root. Do not commit the ZIP or customized MSI.

Keep enrollment tokens, private configurations, and sensitive endpoint logs out of the repository.

## Configure and run

Verify the pilot computer name, destination hostname, ZIP and MSI filenames, installer SHA-256 hash, expected agent versions, and legacy MSI product code. The enrollment token is extracted from the customized MSI filename. Obtain the installer from the intended destination appliance.

Run as Local System using 64-bit Windows PowerShell on AMD64 Windows. The script checks for exactly one matching legacy agent, verifies the staged MSI hash, and checks TCP connectivity to the destination on port 443 before removal. Connectivity alone does not validate enrollment or certificate trust.

In the legacy SMA, create an Online KScript with one attempt, break on failure, and Local System execution. Attach the script and configured ZIP. Use **Always Fail** under Verify and **Launch a program** under Remediation, with **Wait for completion** enabled.

For the legacy 32-bit agent on 64-bit Windows:

| Field | Value |
| --- | --- |
| Directory | `C:\Windows\Sysnative\WindowsPowerShell\v1.0` |
| File | `powershell.exe` |
| Parameters | `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(KACE_DEPENDENCY_DIR)\Migrate-KACE.ps1"` |

Do not pass `-Worker` from KACE. The scheduled task uses it internally. Review the launch path if the launching agent architecture changes.

Existing staging folders or migration tasks stop a new attempt. Review the previous result before retrying. The script retains staging files and the task for inspection and restricts the staging folder to SYSTEM and local Administrators.

## Verify completion

**A successful KACE job confirms staging and worker launch only.** Verify the migration separately:

1. Review `Migration.log`, `Legacy-Uninstall.log`, and `Test-Agent-Install.log` in the configured staging folder.
2. Confirm the scheduled task finished successfully and both MSI operations returned 0.
3. Verify the installed agent version, running agent services, and destination hostname in `C:\ProgramData\Quest\KACE\amp.conf`.
4. Confirm a recent inventory record in the destination SMA and review device warnings.

## Validation status

Two controlled pilots reported successful removal and installation with no reboot reported. One reported normally to the test SMA; the other reported with an unresolved certificate-trust warning affecting agent modules. These results support further testing and do not establish compatibility across all endpoints. Production requires its own hostname, installer, token, and endpoint validation.

KACE patching work in this project is limited to **detection and reporting**. Patch deployment, feature-update deployment, rollback, and patch-related reboots are outside scope.

## Create a shareable copy

Run locally in Windows PowerShell:

```powershell
.\Sanitize-KACEMigration.ps1 -InputPath .\Migrate-KACE.ps1 -OutputPath .\Migrate-KACE.public.ps1
```

The sanitizer replaces the configured computer name, hostname, token-bearing MSI filename, enrollment token, installer hash, legacy product code, staging path, and task/mutex name throughout a separate copy. Standard Windows/KACE paths and product versions remain for technical review. An unconditional stop guard makes the public copy review-only until deliberately reconfigured.

The sanitizer targets this script's current structure and stops if expected assignments are missing or ambiguous. It checks output syntax without executing the migration. Review the complete output before sharing, especially after adding settings or comments. It does not sanitize installers, ZIP files, logs, or existing Git history.

Scripts are for controlled testing and vendor review. Vendor review alone does not establish vendor approval or support.
