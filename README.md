# KACE-SMA-v15-Scripts

Scripts and supporting documentation for the RSSI team and Quest KACE representatives reviewing our migration from legacy KACE SMA **11.0.273** to **15.1**.

The initial focus is an agent migration script that stages the installer locally, removes the legacy agent, and installs the new agent through an independent SYSTEM scheduled task, with automatic reboots suppressed and local logging.

Additional scripts will support inventory, custom inventory, administration, and patch detection and reporting.

## Validation and use

Scripts are developed and piloted in a test environment before production use. Successful pilot results do not guarantee compatibility with every endpoint, particularly sensitive instrument controllers. Suppressing automatic reboots does not guarantee that a reboot will never be required.

Each script should document its prerequisites, configuration, validation results, and known limitations. Vendor review does not imply Quest support or approval unless explicitly documented.

## Repository scope

- Support migration from legacy to current KACE SMA.
- Share implementation details and test results with RSSI colleagues and Quest representatives.
- Keep passwords, agent tokens, and customized installers containing tokens out of the repository.
- Use placeholders for environment-specific configuration.

**KACE patch functionality is intended strictly for detection and reporting. Patch deployment, rollback, feature-update deployment, and patch-related reboots are outside this repository’s scope.**
