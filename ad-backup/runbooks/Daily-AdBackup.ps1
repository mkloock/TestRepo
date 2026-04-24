<#
.SYNOPSIS
    Azure Automation runbook that triggers a daily AD snapshot.

.DESCRIPTION
    Imported into the Automation Account by the deployment script and bound
    to the daily-ad-backup schedule. The runbook itself only orchestrates -
    it dispatches Backup-ActiveDirectory.ps1 onto the Hybrid Worker that lives
    on (or near) the domain controller, because the AD module is not available
    in the Azure-hosted sandbox.

.PARAMETER StorageAccountName
    Storage account holding the backup container. Resolved from a runbook
    variable if not passed explicitly.

.PARAMETER HybridWorkerGroup
    Hybrid Worker group name to execute against.

.PARAMETER DomainControllers
    Comma-separated list of DC FQDNs. If omitted, the runbook backs up
    whatever DC the worker is running on.
#>
[CmdletBinding()]
param(
    [string] $StorageAccountName = (Get-AutomationVariable -Name 'BackupStorageAccount'),
    [Parameter(Mandatory)] [string] $HybridWorkerGroup,
    [string[]] $DomainControllers
)

$ErrorActionPreference = 'Stop'

Write-Output "Connecting with system-assigned managed identity..."
Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity | Out-Null

$dcList = if ($DomainControllers) { $DomainControllers } else { @($env:COMPUTERNAME) }

foreach ($dc in $dcList) {
    Write-Output "Dispatching backup for $dc on hybrid worker $HybridWorkerGroup..."
    $jobParams = @{
        DomainController   = $dc
        StorageAccountName = $StorageAccountName
    }

    # Backup-ActiveDirectory.ps1 must be imported into the Automation Account
    # as a child runbook with the same name.
    Start-AutomationRunbook `
        -Name 'Backup-ActiveDirectory' `
        -Parameters $jobParams `
        -RunOn $HybridWorkerGroup
}

Write-Output "Dispatched $($dcList.Count) backup job(s)."
