# AD Backup & Restore on Azure

A self-contained solution for backing up Active Directory domain controllers
to Azure, viewing what changed between any two backups, and rolling the
directory back to a clean state after a compromise.

## What it does

1. **Scheduled snapshots.** An Azure Automation runbook fires every day on a
   Hybrid Worker that lives on (or next to) a writable DC. The worker uses
   `Get-ADObject -Filter * -Properties *` across the default and configuration
   naming contexts (including tombstones) and writes a normalized JSON
   snapshot.
2. **Tamper-resistant storage.** Snapshots are uploaded to a GZRS storage
   account into a container with versioning + version-level immutability and
   a configurable WORM window. Even an attacker with subscription access
   cannot delete a backup inside its immutability period.
3. **Diff between any two backups.** `Compare-AdBackups.ps1` produces a
   structured added / removed / modified report with attribute-level changes,
   suitable for human review or for piping into a SIEM.
4. **Authoritative restore.** `Restore-AdObjects.ps1` re-snapshots the live
   directory, diffs it against a chosen baseline, and reverses the
   differences: AD Recycle Bin where possible, full recreation otherwise,
   plus optional removal of attacker-introduced objects.

## Repository layout

```
ad-backup/
├── infrastructure/
│   ├── main.bicep                 # Storage, KV, Automation, schedule, RBAC
│   └── parameters.example.json
├── scripts/
│   ├── Backup-ActiveDirectory.ps1 # Snapshot + upload (runs on the DC/HRW)
│   ├── Compare-AdBackups.ps1      # Diff two snapshots
│   ├── Restore-AdObjects.ps1      # Authoritative restore
│   └── Modules/
│       └── AdBackup.psm1          # Shared helpers
├── runbooks/
│   └── Daily-AdBackup.ps1         # Azure Automation orchestrator
└── deploy/
    └── Deploy-AdBackup.ps1        # End-to-end provisioning
```

## Deploying

Prerequisites: an Azure subscription, Owner rights on the target resource
group, the `Az` PowerShell module, and the Bicep CLI.

```powershell
# 1. Adjust parameters
cp infrastructure/parameters.example.json infrastructure/parameters.json
# edit baseName, immutabilityDays, and keyVaultAdminObjectId

# 2. Deploy
./deploy/Deploy-AdBackup.ps1 `
    -SubscriptionId      00000000-0000-0000-0000-000000000000 `
    -ResourceGroupName   rg-ad-backup `
    -Location            westeurope `
    -ParametersFile      ./infrastructure/parameters.json `
    -HybridWorkerGroup   hrw-domain-controllers
```

After deployment, onboard one or more domain controllers into the Hybrid
Worker group (`Add-HybridRunbookWorker`) so the scheduled runbook has
somewhere to execute.

## Usage

### Manual backup

Run on a DC for a one-off snapshot (also useful for post-deploy smoke tests):

```powershell
./scripts/Backup-ActiveDirectory.ps1 -StorageAccountName contosobackups -Verbose
```

### Diff two backups

The default form picks the two most recent snapshots for the given domain:

```powershell
./scripts/Compare-AdBackups.ps1 `
    -StorageAccountName contosobackups `
    -Domain contoso `
    -Format Text
```

Or compare two specific blobs:

```powershell
./scripts/Compare-AdBackups.ps1 `
    -StorageAccountName contosobackups -Domain contoso `
    -BaselineBlob "contoso/20260420T020000Z.json" `
    -CurrentBlob  "contoso/20260424T020000Z.json" `
    -OutputPath   ./diff.json
```

### Restore after a compromise

The restore script is dry-run by default. Review the plan before applying.

```powershell
# 1. Inspect the plan against the target DC
./scripts/Restore-AdObjects.ps1 `
    -StorageAccountName contosobackups `
    -Domain contoso `
    -BaselineBlob "contoso/20260420T020000Z.json" `
    -DomainController dc01.contoso.local `
    -ScopeFilter 'OU=Tier0'

# 2. Apply, including removal of attacker-added objects in scope
./scripts/Restore-AdObjects.ps1 `
    -StorageAccountName contosobackups `
    -Domain contoso `
    -BaselineBlob "contoso/20260420T020000Z.json" `
    -DomainController dc01.contoso.local `
    -ScopeFilter 'OU=Tier0' `
    -RemoveExtraneous `
    -Apply -Confirm:$false
```

## Design notes

- **Snapshot format.** JSON keyed by `distinguishedName`, with binary
  attributes base64-encoded. Volatile attributes (`uSNChanged`, `lastLogon`,
  replication metadata, etc.) are stripped at capture time so diffs surface
  real configuration drift rather than replication noise.
- **Immutability.** The `ad-backups` container uses
  `immutableStorageWithVersioning`. Each blob version is locked for
  `immutabilityDays` (default 90) - sufficient to outlast most discovery
  windows for AD attacks. `allowProtectedAppendWrites` is on so the index
  can be appended without breaking the WORM contract.
- **Auth.** The Automation Account uses a system-assigned managed identity
  with `Storage Blob Data Contributor` on the storage account and
  `Key Vault Crypto User` on the vault. The deploying user is granted
  `Key Vault Administrator`. Storage shared keys are disabled.
- **Restore safety.** `Restore-AdObjects.ps1` is dry-run by default,
  supports `-WhatIf`/`-Confirm`, and accepts a `-ScopeFilter` regex so a
  staged restore (Tier0 first, then Tier1, etc.) is the obvious workflow.
  It prefers AD Recycle Bin restores over recreation when possible.
- **Audit.** Every backup, compare, and restore emits a structured
  `AD-AUDIT` log line consumed by the Log Analytics workspace; pair it with
  Azure Monitor alerts on the `Restore` action for tamper detection on the
  detection pipeline itself.

## Limitations

- The snapshot is logical (objects + attributes), not a full system-state
  backup. It does not capture SYSVOL contents, group policy file payloads,
  or DNS zone files - point a separate file backup at SYSVOL for that.
- Restore cannot reconstruct relationships involving SIDs that have been
  re-issued; objects deleted past the AD tombstone lifetime get a new SID
  on recreation, so SID-based ACLs that referenced them must be reapplied.
- The runbook depends on a Hybrid Worker because the `ActiveDirectory`
  PowerShell module is not available in the Azure-hosted sandbox.
