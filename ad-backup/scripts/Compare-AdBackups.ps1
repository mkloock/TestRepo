#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Storage

<#
.SYNOPSIS
    Diffs two AD backups and reports added, removed, and modified objects.

.DESCRIPTION
    Backups can be referenced either by local file path or by their blob path
    in the configured storage account (e.g. "contoso/20260424T020000Z.json").
    The comparison ignores noisy attributes (uSN counters, login timestamps,
    replication metadata) so results focus on real configuration drift.

.PARAMETER BaselineBlob
    Blob path of the older snapshot to compare against.

.PARAMETER CurrentBlob
    Blob path of the newer snapshot. If omitted, the latest snapshot for
    -Domain is used.

.PARAMETER BaselinePath
    Local path to a snapshot file (alternative to -BaselineBlob).

.PARAMETER CurrentPath
    Local path to a snapshot file (alternative to -CurrentBlob).

.PARAMETER Domain
    NetBIOS domain name. Required when using blob references.

.PARAMETER StorageAccountName
    Storage account holding the snapshots. Required when using blob references.

.PARAMETER BackupContainer
    Container holding snapshot blobs. Default: ad-backups.

.PARAMETER IndexContainer
    Container holding the per-domain index. Default: ad-backup-index.

.PARAMETER OutputPath
    If supplied, writes the full diff as JSON to this path. Otherwise the
    diff is printed to stdout as a structured object.

.PARAMETER Format
    Output format: Object (default), Json, or Text.

.EXAMPLE
    .\Compare-AdBackups.ps1 -StorageAccountName contosobackups -Domain contoso

.EXAMPLE
    .\Compare-AdBackups.ps1 -BaselinePath .\baseline.json -CurrentPath .\current.json -Format Text
#>
[CmdletBinding(DefaultParameterSetName='Blob')]
param(
    [Parameter(ParameterSetName='Blob')] [string] $BaselineBlob,
    [Parameter(ParameterSetName='Blob')] [string] $CurrentBlob,
    [Parameter(ParameterSetName='Blob', Mandatory)] [string] $Domain,
    [Parameter(ParameterSetName='Blob', Mandatory)] [string] $StorageAccountName,
    [Parameter(ParameterSetName='Blob')] [string] $BackupContainer = 'ad-backups',
    [Parameter(ParameterSetName='Blob')] [string] $IndexContainer  = 'ad-backup-index',

    [Parameter(ParameterSetName='Path', Mandatory)] [string] $BaselinePath,
    [Parameter(ParameterSetName='Path', Mandatory)] [string] $CurrentPath,

    [string] $OutputPath,
    [ValidateSet('Object','Json','Text')] [string] $Format = 'Object'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Modules\AdBackup.psm1') -Force

function Get-IndexEntries {
    param($StorageAccountName, $IndexContainer, $Domain)

    $ctx = Resolve-AzureBlobClient -StorageAccountName $StorageAccountName
    $tmp = New-TemporaryFile
    Get-AzStorageBlobContent -Container $IndexContainer -Blob "$Domain/index.jsonl" `
        -Destination $tmp.FullName -Context $ctx -Force | Out-Null
    Get-Content $tmp.FullName | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
}

if ($PSCmdlet.ParameterSetName -eq 'Blob') {
    $entries = @(Get-IndexEntries -StorageAccountName $StorageAccountName -IndexContainer $IndexContainer -Domain $Domain | Sort-Object capturedAt)
    if ($entries.Count -lt 2) { throw "Domain '$Domain' has fewer than two snapshots; nothing to compare." }
    if (-not $CurrentBlob)  { $CurrentBlob  = $entries[-1].blob }
    if (-not $BaselineBlob) { $BaselineBlob = $entries[-2].blob }

    $work = Join-Path $env:TEMP "ad-backup-diff-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $work | Out-Null
    $BaselinePath = Join-Path $work 'baseline.json'
    $CurrentPath  = Join-Path $work 'current.json'
    Get-AdSnapshotFromBlob -StorageAccountName $StorageAccountName -Container $BackupContainer -BlobName $BaselineBlob -DestinationPath $BaselinePath | Out-Null
    Get-AdSnapshotFromBlob -StorageAccountName $StorageAccountName -Container $BackupContainer -BlobName $CurrentBlob  -DestinationPath $CurrentPath  | Out-Null
}

$baseline = Read-AdSnapshot -Path $BaselinePath
$current  = Read-AdSnapshot -Path $CurrentPath
$diff     = Compare-AdSnapshot -Baseline $baseline -Current $current

Write-AdAuditEvent -Action 'Compare' -Details @{
    baseline = $baseline.capturedAt
    current  = $current.capturedAt
    added    = $diff.summary.addedCount
    removed  = $diff.summary.removedCount
    modified = $diff.summary.modifiedCount
}

if ($OutputPath) {
    $diff | ConvertTo-Json -Depth 32 | Out-File -FilePath $OutputPath -Encoding UTF8
    Write-Verbose "Wrote diff to $OutputPath"
}

switch ($Format) {
    'Json'   { $diff | ConvertTo-Json -Depth 32 }
    'Text'   {
        Write-Output "Diff: $($baseline.capturedAt)  ->  $($current.capturedAt)"
        Write-Output ("  Added:    {0}" -f $diff.summary.addedCount)
        Write-Output ("  Removed:  {0}" -f $diff.summary.removedCount)
        Write-Output ("  Modified: {0}" -f $diff.summary.modifiedCount)
        Write-Output ''
        if ($diff.added.Count) {
            Write-Output 'ADDED'
            $diff.added | ForEach-Object { Write-Output "  + [$($_.objectClass)] $($_.distinguishedName)" }
            Write-Output ''
        }
        if ($diff.removed.Count) {
            Write-Output 'REMOVED'
            $diff.removed | ForEach-Object { Write-Output "  - [$($_.objectClass)] $($_.distinguishedName)" }
            Write-Output ''
        }
        if ($diff.modified.Count) {
            Write-Output 'MODIFIED'
            foreach ($m in $diff.modified) {
                Write-Output "  ~ [$($m.objectClass)] $($m.distinguishedName)"
                foreach ($c in $m.changes) {
                    $b = if ($null -eq $c.before) { '<absent>' } else { ($c.before | Out-String).Trim() }
                    $a = if ($null -eq $c.after)  { '<absent>' } else { ($c.after  | Out-String).Trim() }
                    Write-Output "      $($c.attribute): $b => $a"
                }
            }
        }
    }
    default  { $diff }
}
