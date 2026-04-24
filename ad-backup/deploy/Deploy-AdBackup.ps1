#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Resources, Az.Automation

<#
.SYNOPSIS
    Provisions the AD Backup & Restore solution into an Azure subscription.

.DESCRIPTION
    1. Creates (or updates) the resource group.
    2. Deploys infrastructure/main.bicep.
    3. Imports Backup-ActiveDirectory.ps1 and Daily-AdBackup.ps1 as runbooks.
    4. Links the daily schedule to Daily-AdBackup.
    5. Publishes a runbook variable holding the storage account name.

.PARAMETER SubscriptionId
    Subscription to deploy into.

.PARAMETER ResourceGroupName
    Target resource group. Created if it does not exist.

.PARAMETER Location
    Azure region.

.PARAMETER ParametersFile
    Path to a Bicep parameters file (see infrastructure/parameters.example.json).

.PARAMETER HybridWorkerGroup
    Name of the Hybrid Worker group that will execute the backup runbook on
    the domain controller. Onboard the DC into this group before scheduling.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $Location,
    [Parameter(Mandatory)] [string] $ParametersFile,
    [Parameter(Mandatory)] [string] $HybridWorkerGroup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$bicep      = Join-Path $repoRoot 'infrastructure\main.bicep'
$backupRb   = Join-Path $repoRoot 'scripts\Backup-ActiveDirectory.ps1'
$dailyRb    = Join-Path $repoRoot 'runbooks\Daily-AdBackup.ps1'

if (-not (Test-Path $bicep))    { throw "Missing $bicep" }
if (-not (Test-Path $backupRb)) { throw "Missing $backupRb" }
if (-not (Test-Path $dailyRb))  { throw "Missing $dailyRb" }

Write-Verbose "Setting subscription context to $SubscriptionId"
Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null

if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
}

Write-Verbose "Deploying infrastructure..."
$deployment = New-AzResourceGroupDeployment `
    -Name "ad-backup-$(Get-Date -Format 'yyyyMMddHHmmss')" `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile $bicep `
    -TemplateParameterFile $ParametersFile

$automationName    = $deployment.Outputs.automationAccountName.Value
$storageAccount    = $deployment.Outputs.storageAccountName.Value

Write-Verbose "Importing runbooks into $automationName..."
Import-AzAutomationRunbook `
    -Name 'Backup-ActiveDirectory' `
    -Path $backupRb `
    -Type PowerShell `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $automationName `
    -Force | Out-Null
Publish-AzAutomationRunbook -Name 'Backup-ActiveDirectory' `
    -ResourceGroupName $ResourceGroupName -AutomationAccountName $automationName | Out-Null

Import-AzAutomationRunbook `
    -Name 'Daily-AdBackup' `
    -Path $dailyRb `
    -Type PowerShell `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $automationName `
    -Force | Out-Null
Publish-AzAutomationRunbook -Name 'Daily-AdBackup' `
    -ResourceGroupName $ResourceGroupName -AutomationAccountName $automationName | Out-Null

Write-Verbose "Publishing automation variables..."
New-AzAutomationVariable `
    -Name 'BackupStorageAccount' `
    -Value $storageAccount `
    -Encrypted $false `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $automationName -ErrorAction SilentlyContinue | Out-Null

Write-Verbose "Linking daily schedule to Daily-AdBackup..."
Register-AzAutomationScheduledRunbook `
    -RunbookName 'Daily-AdBackup' `
    -ScheduleName 'daily-ad-backup' `
    -Parameters @{ HybridWorkerGroup = $HybridWorkerGroup } `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $automationName | Out-Null

Write-Output "Deployment complete."
Write-Output "  Storage account:   $storageAccount"
Write-Output "  Automation:        $automationName"
Write-Output "  Hybrid worker:     $HybridWorkerGroup"
Write-Output ""
Write-Output "Next: onboard your DC(s) into the Hybrid Worker group '$HybridWorkerGroup'."
