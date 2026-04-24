#Requires -Version 5.1
#Requires -Modules ActiveDirectory, Az.Accounts, Az.Storage

<#
.SYNOPSIS
    Captures a full snapshot of an Active Directory domain and uploads it to
    immutable Azure Blob Storage.

.DESCRIPTION
    Run this on a domain controller (or a hybrid Automation worker that can
    reach one). It enumerates every object in the domain and configuration
    naming contexts, strips volatile attributes that would create noise in
    diffs, writes a JSON snapshot to a temp file, and uploads it to the
    backup container with version-locked immutability.

    A small index document is also updated so Compare-AdBackups.ps1 and
    Restore-AdObjects.ps1 can find snapshots quickly without listing the
    container.

.PARAMETER DomainController
    FQDN of the DC to query. Defaults to the local computer.

.PARAMETER StorageAccountName
    The Azure storage account that holds the backup container.

.PARAMETER BackupContainer
    Container name for snapshot blobs. Default: ad-backups.

.PARAMETER IndexContainer
    Container name for the index blob. Default: ad-backup-index.

.PARAMETER WorkingDirectory
    Local scratch directory. Default: $env:TEMP\ad-backup.

.EXAMPLE
    .\Backup-ActiveDirectory.ps1 -StorageAccountName contosobackups
#>
[CmdletBinding()]
param(
    [string] $DomainController = $env:COMPUTERNAME,
    [Parameter(Mandatory)] [string] $StorageAccountName,
    [string] $BackupContainer = 'ad-backups',
    [string] $IndexContainer  = 'ad-backup-index',
    [string] $WorkingDirectory = (Join-Path $env:TEMP 'ad-backup')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Modules\AdBackup.psm1') -Force

if (-not (Test-Path $WorkingDirectory)) {
    New-Item -ItemType Directory -Path $WorkingDirectory | Out-Null
}

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$domainShort = (Get-ADDomain -Server $DomainController).NetBIOSName.ToLower()
$snapshotFile = Join-Path $WorkingDirectory "$domainShort-$timestamp.json"
$blobName     = "$domainShort/$timestamp.json"

Write-Verbose "Capturing snapshot from $DomainController -> $snapshotFile"
$snapshot = New-AdSnapshot -Server $DomainController -OutputPath $snapshotFile -IncludeDeleted

$metadata = @{
    domain      = $domainShort
    sourceDc    = $DomainController
    capturedAt  = $timestamp
    sha256      = $snapshot.Sha256
    objectCount = $snapshot.ObjectCount
    schema      = Get-AdBackupSchemaVersion
}

Write-Verbose "Uploading snapshot to $StorageAccountName/$BackupContainer/$blobName"
$blob = Publish-AdSnapshot `
    -Path $snapshotFile `
    -StorageAccountName $StorageAccountName `
    -Container $BackupContainer `
    -BlobName $blobName `
    -Metadata $metadata

# Append to the index so consumers can list backups cheaply.
$ctx = Resolve-AzureBlobClient -StorageAccountName $StorageAccountName
$indexBlobName = "$domainShort/index.jsonl"
$indexLocal = Join-Path $WorkingDirectory "index-$domainShort.jsonl"
if (Test-Path $indexLocal) { Remove-Item $indexLocal -Force }

$existing = Get-AzStorageBlob -Container $IndexContainer -Blob $indexBlobName -Context $ctx -ErrorAction SilentlyContinue
if ($existing) {
    Get-AzStorageBlobContent -Container $IndexContainer -Blob $indexBlobName -Destination $indexLocal -Context $ctx -Force | Out-Null
}

$entry = [ordered]@{
    capturedAt  = $timestamp
    blob        = $blobName
    versionId   = $blob.VersionId
    sha256      = $snapshot.Sha256
    objectCount = $snapshot.ObjectCount
    sourceDc    = $DomainController
    sizeBytes   = $snapshot.SizeBytes
} | ConvertTo-Json -Compress
Add-Content -Path $indexLocal -Value $entry -Encoding UTF8

Set-AzStorageBlobContent -File $indexLocal -Container $IndexContainer -Blob $indexBlobName -Context $ctx -Force | Out-Null

Remove-Item $snapshotFile -Force -ErrorAction SilentlyContinue

Write-AdAuditEvent -Action 'Backup' -Details @{
    domain      = $domainShort
    blob        = $blobName
    versionId   = $blob.VersionId
    objectCount = $snapshot.ObjectCount
    sha256      = $snapshot.Sha256
}

[pscustomobject]@{
    Domain      = $domainShort
    Blob        = $blobName
    VersionId   = $blob.VersionId
    ObjectCount = $snapshot.ObjectCount
    Sha256      = $snapshot.Sha256
    SizeBytes   = $snapshot.SizeBytes
}
