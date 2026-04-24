#Requires -Version 5.1
#Requires -Modules ActiveDirectory, Az.Accounts, Az.Storage

<#
.SYNOPSIS
    Restores Active Directory objects and attributes from a snapshot blob.

.DESCRIPTION
    Compares the live directory against a clean baseline snapshot and reverts
    the differences. Three reversion classes are handled:

      * Objects present in the baseline but missing live -> recreated
        (preferring AD Recycle Bin restore when the tombstone is reachable).
      * Objects absent from the baseline but present live -> optionally
        deleted as suspected attacker artifacts (-RemoveExtraneous).
      * Objects present in both with attribute drift -> attributes reverted
        to the baseline values.

    The script is dry-run by default. Pass -Confirm:$false -WhatIf:$false
    -Apply to actually mutate the directory. Every action is logged through
    Write-AdAuditEvent.

.PARAMETER BaselineBlob
    Blob path of the snapshot to restore from (e.g. "contoso/20260420T020000Z.json").

.PARAMETER BaselinePath
    Local snapshot file (alternative to -BaselineBlob).

.PARAMETER Domain
    NetBIOS domain name. Required with -BaselineBlob.

.PARAMETER StorageAccountName
    Storage account holding the backup. Required with -BaselineBlob.

.PARAMETER BackupContainer
    Container holding snapshot blobs. Default: ad-backups.

.PARAMETER DomainController
    DC to write changes to. Defaults to the local machine.

.PARAMETER ScopeFilter
    Optional regex applied to distinguishedName. Only matching objects are
    touched. Useful for staged restores ("only the Tier0 OU first").

.PARAMETER RemoveExtraneous
    If set, objects that exist live but not in the baseline are deleted.
    Off by default - recreating data is safer than removing it.

.PARAMETER Apply
    Required to actually mutate the directory. Without it the script reports
    what it would do.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High', DefaultParameterSetName='Blob')]
param(
    [Parameter(ParameterSetName='Blob', Mandatory)] [string] $BaselineBlob,
    [Parameter(ParameterSetName='Blob', Mandatory)] [string] $Domain,
    [Parameter(ParameterSetName='Blob', Mandatory)] [string] $StorageAccountName,
    [Parameter(ParameterSetName='Blob')] [string] $BackupContainer = 'ad-backups',

    [Parameter(ParameterSetName='Path', Mandatory)] [string] $BaselinePath,

    [string] $DomainController = $env:COMPUTERNAME,
    [string] $ScopeFilter,
    [switch] $RemoveExtraneous,
    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Modules\AdBackup.psm1') -Force
Import-Module ActiveDirectory -ErrorAction Stop

# Attributes the directory manages itself or that are illegal to set via Set-ADObject.
$systemManagedAttrs = @(
    'distinguishedName','objectClass','objectGUID','objectSid','whenCreated',
    'whenChanged','uSNCreated','uSNChanged','sAMAccountType','primaryGroupToken',
    'instanceType','isDeleted','isRecycled','dSCorePropagationData',
    'replPropertyMetaData','nTSecurityDescriptor','msDS-RevealedUsers'
)

if ($PSCmdlet.ParameterSetName -eq 'Blob') {
    $work = Join-Path $env:TEMP "ad-restore-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $work | Out-Null
    $BaselinePath = Join-Path $work 'baseline.json'
    Get-AdSnapshotFromBlob -StorageAccountName $StorageAccountName -Container $BackupContainer `
        -BlobName $BaselineBlob -DestinationPath $BaselinePath | Out-Null
}

$baseline = Read-AdSnapshot -Path $BaselinePath
Write-Verbose "Baseline captured at $($baseline.capturedAt) from $($baseline.sourceDc) - $($baseline.objectCount) objects"

# Capture the current state from the target DC and diff against the baseline.
$liveFile = Join-Path ([System.IO.Path]::GetDirectoryName($BaselinePath)) 'live.json'
New-AdSnapshot -Server $DomainController -OutputPath $liveFile -IncludeDeleted | Out-Null
$current = Read-AdSnapshot -Path $liveFile
$diff = Compare-AdSnapshot -Baseline $baseline -Current $current

if ($ScopeFilter) {
    Write-Verbose "Applying scope filter: $ScopeFilter"
    $diff.removed  = @($diff.removed  | Where-Object { $_.distinguishedName -match $ScopeFilter })
    $diff.added    = @($diff.added    | Where-Object { $_.distinguishedName -match $ScopeFilter })
    $diff.modified = @($diff.modified | Where-Object { $_.distinguishedName -match $ScopeFilter })
}

$plan = [pscustomobject]@{
    Recreate = $diff.removed
    Revert   = $diff.modified
    Delete   = if ($RemoveExtraneous) { $diff.added } else { @() }
}

Write-Output "Restore plan against $DomainController (baseline $($baseline.capturedAt)):"
Write-Output ("  Recreate: {0}" -f $plan.Recreate.Count)
Write-Output ("  Revert:   {0}" -f $plan.Revert.Count)
Write-Output ("  Delete:   {0}" -f $plan.Delete.Count)

if (-not $Apply) {
    Write-Output ''
    Write-Output 'Dry run - no changes applied. Re-run with -Apply (and -Confirm:$false to skip prompts).'
    return $plan
}

function Restore-AdObjectFromSnapshot {
    param($Server, $Snapshot)

    $dn = $Snapshot.distinguishedName
    $guid = $Snapshot.objectGUID
    $deleted = Get-ADObject -Server $Server -Filter "objectGUID -eq '$guid'" -IncludeDeletedObjects -Properties isDeleted -ErrorAction SilentlyContinue
    if ($deleted -and $deleted.isDeleted) {
        Restore-ADObject -Server $Server -Identity $deleted.objectGUID -ErrorAction Stop
        Write-Verbose "Restored from recycle bin: $dn"
        return
    }

    # Object is gone from the recycle bin too - recreate from the snapshot.
    $parent = ($dn -split '(?<!\\),', 2)[1]
    $nameProp = $Snapshot.PSObject.Properties['name']
    $name = if ($nameProp) { $nameProp.Value } else { ($dn -split '(?<!\\),', 2)[0] -replace '^[A-Za-z]+=','' }
    $class = $Snapshot.objectClass
    if ($class -is [System.Array]) { $class = $class[-1] }

    $other = @{}
    foreach ($p in $Snapshot.PSObject.Properties) {
        if ($systemManagedAttrs -contains $p.Name) { continue }
        if ($p.Name -in @('name','cn','ou')) { continue }
        if ($null -ne $p.Value) { $other[$p.Name] = $p.Value }
    }

    New-ADObject -Server $Server -Name $name -Type $class -Path $parent -OtherAttributes $other -ErrorAction Stop
    Write-Verbose "Recreated: $dn"
}

function Revert-AdAttributes {
    param($Server, $Modified)

    $replace = @{}
    $clear   = @()
    foreach ($c in $Modified.changes) {
        if ($systemManagedAttrs -contains $c.attribute) { continue }
        if ($null -eq $c.before -or ($c.before -is [string] -and $c.before -eq '')) {
            $clear += $c.attribute
        } else {
            $replace[$c.attribute] = $c.before
        }
    }

    $params = @{ Server = $Server; Identity = $Modified.objectGUID }
    if ($replace.Count -gt 0) { $params['Replace'] = $replace }
    if ($clear.Count -gt 0)   { $params['Clear']   = $clear }
    if ($params.ContainsKey('Replace') -or $params.ContainsKey('Clear')) {
        Set-ADObject @params -ErrorAction Stop
    }
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($r in $plan.Recreate) {
    if ($PSCmdlet.ShouldProcess($r.distinguishedName, 'Recreate from baseline')) {
        try {
            Restore-AdObjectFromSnapshot -Server $DomainController -Snapshot $r.snapshot
            $results.Add([pscustomobject]@{ Action='Recreate'; DN=$r.distinguishedName; Status='Success' })
        } catch {
            $results.Add([pscustomobject]@{ Action='Recreate'; DN=$r.distinguishedName; Status="Failed: $_" })
        }
    }
}

foreach ($m in $plan.Revert) {
    if ($PSCmdlet.ShouldProcess($m.distinguishedName, 'Revert attributes to baseline')) {
        try {
            Revert-AdAttributes -Server $DomainController -Modified $m
            $results.Add([pscustomobject]@{ Action='Revert'; DN=$m.distinguishedName; Status='Success' })
        } catch {
            $results.Add([pscustomobject]@{ Action='Revert'; DN=$m.distinguishedName; Status="Failed: $_" })
        }
    }
}

foreach ($d in $plan.Delete) {
    if ($PSCmdlet.ShouldProcess($d.distinguishedName, 'Delete (extraneous since baseline)')) {
        try {
            Remove-ADObject -Server $DomainController -Identity $d.objectGUID -Recursive -Confirm:$false -ErrorAction Stop
            $results.Add([pscustomobject]@{ Action='Delete'; DN=$d.distinguishedName; Status='Success' })
        } catch {
            $results.Add([pscustomobject]@{ Action='Delete'; DN=$d.distinguishedName; Status="Failed: $_" })
        }
    }
}

Write-AdAuditEvent -Action 'Restore' -Details @{
    domain     = $baseline.domain
    baseline   = $baseline.capturedAt
    targetDc   = $DomainController
    scope      = $ScopeFilter
    recreate   = $plan.Recreate.Count
    revert     = $plan.Revert.Count
    delete     = $plan.Delete.Count
    failures   = ($results | Where-Object { $_.Status -ne 'Success' }).Count
}

$results
