#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# AdBackup.psm1
# Shared helpers for the AD Backup & Restore solution. Used by the
# Backup, Compare, and Restore scripts and by the Azure Automation runbook.

# Attributes that are runtime-generated, replicated counters, or otherwise
# meaningless to diff/restore. Excluded from the snapshot to keep diffs signal-rich.
$script:VolatileAttributes = @(
    'whenChanged', 'uSNChanged', 'uSNCreated', 'dSCorePropagationData',
    'replPropertyMetaData', 'msDS-RevealedUsers', 'msDS-AuthenticatedAtDC',
    'badPasswordTime', 'badPwdCount', 'lastLogon', 'lastLogonTimestamp',
    'logonCount', 'pwdLastSet', 'msDS-LastSuccessfulInteractiveLogonTime',
    'msDS-FailedInteractiveLogonCount', 'msDS-LastFailedInteractiveLogonTime'
)

function Get-AdBackupSchemaVersion {
    # Bumped whenever the on-disk snapshot format changes. Restore refuses
    # to operate on snapshots from a newer schema than it understands.
    '1.0'
}

function New-AdSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [string] $OutputPath,
        [string[]] $SearchBase,
        [switch] $IncludeDeleted
    )

    Import-Module ActiveDirectory -ErrorAction Stop

    if (-not $SearchBase) {
        $rootDse = Get-ADRootDSE -Server $Server
        $SearchBase = @($rootDse.defaultNamingContext, $rootDse.configurationNamingContext)
    }

    $objects = New-Object System.Collections.Generic.List[object]
    foreach ($base in $SearchBase) {
        Write-Verbose "Enumerating $base on $Server"
        $params = @{
            Server      = $Server
            SearchBase  = $base
            Filter      = '*'
            Properties  = '*'
        }
        if ($IncludeDeleted) { $params['IncludeDeletedObjects'] = $true }

        Get-ADObject @params | ForEach-Object {
            $clean = [ordered]@{}
            foreach ($prop in $_.PSObject.Properties) {
                if ($script:VolatileAttributes -contains $prop.Name) { continue }
                $value = $prop.Value
                if ($null -eq $value) { continue }
                if ($value -is [byte[]]) {
                    $clean[$prop.Name] = @{ '__type' = 'binary'; '__b64' = [Convert]::ToBase64String($value) }
                } elseif ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
                    $clean[$prop.Name] = @($value | ForEach-Object { "$_" })
                } else {
                    $clean[$prop.Name] = "$value"
                }
            }
            $objects.Add([pscustomobject]$clean)
        }
    }

    $snapshot = [ordered]@{
        schemaVersion = Get-AdBackupSchemaVersion
        capturedAt    = (Get-Date).ToUniversalTime().ToString('o')
        sourceDc      = $Server
        domain        = (Get-ADDomain -Server $Server).DNSRoot
        searchBase    = $SearchBase
        objectCount   = $objects.Count
        objects       = $objects
    }

    $json = $snapshot | ConvertTo-Json -Depth 32 -Compress
    [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))

    [pscustomobject]@{
        Path        = $OutputPath
        ObjectCount = $objects.Count
        Sha256      = (Get-FileHash -Path $OutputPath -Algorithm SHA256).Hash
        SizeBytes   = (Get-Item $OutputPath).Length
    }
}

function Read-AdSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    $snapshot = $raw | ConvertFrom-Json
    if ($snapshot.schemaVersion -ne (Get-AdBackupSchemaVersion)) {
        throw "Snapshot schema $($snapshot.schemaVersion) is incompatible with module schema $(Get-AdBackupSchemaVersion)."
    }
    $snapshot
}

function ConvertTo-AdObjectIndex {
    # Turn the snapshot's object array into a hashtable keyed by distinguishedName
    # for O(1) lookup during diffs and restores.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Snapshot)

    $idx = @{}
    foreach ($obj in $Snapshot.objects) {
        $idx[$obj.distinguishedName] = $obj
    }
    $idx
}

function Compare-AdSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Baseline,
        [Parameter(Mandatory)] $Current,
        [string[]] $IgnoreAttribute = @()
    )

    $base = ConvertTo-AdObjectIndex -Snapshot $Baseline
    $curr = ConvertTo-AdObjectIndex -Snapshot $Current
    $ignore = [System.Collections.Generic.HashSet[string]]::new([string[]]($script:VolatileAttributes + $IgnoreAttribute))

    $added    = New-Object System.Collections.Generic.List[object]
    $removed  = New-Object System.Collections.Generic.List[object]
    $modified = New-Object System.Collections.Generic.List[object]

    foreach ($dn in $curr.Keys) {
        if (-not $base.ContainsKey($dn)) {
            $added.Add([pscustomobject]@{
                distinguishedName = $dn
                objectClass       = $curr[$dn].objectClass
                objectGUID        = $curr[$dn].objectGUID
            })
        }
    }

    foreach ($dn in $base.Keys) {
        if (-not $curr.ContainsKey($dn)) {
            $removed.Add([pscustomobject]@{
                distinguishedName = $dn
                objectClass       = $base[$dn].objectClass
                objectGUID        = $base[$dn].objectGUID
                snapshot          = $base[$dn]
            })
            continue
        }

        $b = $base[$dn]
        $c = $curr[$dn]
        $changes = New-Object System.Collections.Generic.List[object]
        $allAttrs = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($p in $b.PSObject.Properties) { $null = $allAttrs.Add($p.Name) }
        foreach ($p in $c.PSObject.Properties) { $null = $allAttrs.Add($p.Name) }

        foreach ($attr in $allAttrs) {
            if ($ignore.Contains($attr)) { continue }
            $bp = $b.PSObject.Properties[$attr]
            $cp = $c.PSObject.Properties[$attr]
            $bv = if ($bp) { $bp.Value } else { $null }
            $cv = if ($cp) { $cp.Value } else { $null }
            $bj = if ($null -eq $bv) { '' } else { ConvertTo-Json $bv -Depth 8 -Compress }
            $cj = if ($null -eq $cv) { '' } else { ConvertTo-Json $cv -Depth 8 -Compress }
            if ($bj -ne $cj) {
                $changes.Add([pscustomobject]@{
                    attribute = $attr
                    before    = $bv
                    after     = $cv
                })
            }
        }

        if ($changes.Count -gt 0) {
            $modified.Add([pscustomobject]@{
                distinguishedName = $dn
                objectClass       = $b.objectClass
                objectGUID        = $b.objectGUID
                changes           = $changes
            })
        }
    }

    [pscustomobject]@{
        baselineCapturedAt = $Baseline.capturedAt
        currentCapturedAt  = $Current.capturedAt
        domain             = $Current.domain
        added              = $added
        removed            = $removed
        modified           = $modified
        summary            = [pscustomobject]@{
            addedCount    = $added.Count
            removedCount  = $removed.Count
            modifiedCount = $modified.Count
        }
    }
}

function Resolve-AzureBlobClient {
    # Returns an authenticated Az.Storage context using managed identity if
    # available, otherwise the current Az session. Centralized so every
    # script gets the same auth path.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StorageAccountName)

    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Storage  -ErrorAction Stop

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        try { Connect-AzAccount -Identity -ErrorAction Stop | Out-Null }
        catch { Connect-AzAccount -ErrorAction Stop | Out-Null }
    }

    New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
}

function Publish-AdSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $BlobName,
        [hashtable] $Metadata = @{}
    )

    $ctx = Resolve-AzureBlobClient -StorageAccountName $StorageAccountName

    $blob = Set-AzStorageBlobContent `
        -File $Path `
        -Container $Container `
        -Blob $BlobName `
        -Context $ctx `
        -StandardBlobTier Hot `
        -Force

    if ($Metadata.Count -gt 0) {
        $cloud = $blob.ICloudBlob
        foreach ($k in $Metadata.Keys) { $cloud.Metadata[$k] = "$($Metadata[$k])" }
        $cloud.SetMetadata()
    }

    $blob
}

function Get-AdSnapshotFromBlob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $BlobName,
        [Parameter(Mandatory)] [string] $DestinationPath
    )

    $ctx = Resolve-AzureBlobClient -StorageAccountName $StorageAccountName
    Get-AzStorageBlobContent `
        -Container $Container `
        -Blob $BlobName `
        -Destination $DestinationPath `
        -Context $ctx `
        -Force | Out-Null
    $DestinationPath
}

function Write-AdAuditEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Backup','Compare','Restore')] [string] $Action,
        [Parameter(Mandatory)] [hashtable] $Details
    )

    $payload = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        action    = $Action
        host      = [System.Net.Dns]::GetHostName()
        user      = [Environment]::UserName
        details   = $Details
    } | ConvertTo-Json -Depth 8 -Compress

    Write-Output "AD-AUDIT $payload"
}

Export-ModuleMember -Function `
    Get-AdBackupSchemaVersion, New-AdSnapshot, Read-AdSnapshot, `
    ConvertTo-AdObjectIndex, Compare-AdSnapshot, Resolve-AzureBlobClient, `
    Publish-AdSnapshot, Get-AdSnapshotFromBlob, Write-AdAuditEvent
