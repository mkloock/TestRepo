// Azure infrastructure for the AD Backup & Restore solution.
//
// Deploys:
//   * Storage account with versioning, soft delete, immutable container
//   * Key Vault holding the SAS / connection string and a backup-encryption key
//   * Log Analytics workspace for runbook output and audit trail
//   * Automation Account with a system-assigned identity, the backup runbook,
//     and a daily schedule
//   * Hybrid Worker group placeholder (the DC must be onboarded out of band)

@description('Base name used to derive resource names. Must be 3-15 lowercase alphanumerics.')
@minLength(3)
@maxLength(15)
param baseName string

@description('Region for all resources.')
param location string = resourceGroup().location

@description('Number of days to retain non-immutable backup blobs before tiering to archive.')
@minValue(7)
@maxValue(365)
param hotRetentionDays int = 30

@description('Immutability window in days. Backups inside this window cannot be deleted, even by an admin.')
@minValue(1)
@maxValue(3650)
param immutabilityDays int = 90

@description('Object ID of the principal that should be granted Key Vault admin rights (typically the deploying user).')
param keyVaultAdminObjectId string

@description('Tags applied to every resource.')
param tags object = {
  workload: 'ad-backup-restore'
  managedBy: 'bicep'
}

var storageName = toLower('${baseName}adbk${uniqueString(resourceGroup().id)}')
var vaultName = toLower('${baseName}-kv-${uniqueString(resourceGroup().id)}')
var lawName = '${baseName}-law'
var automationName = '${baseName}-aa'
var backupContainer = 'ad-backups'
var indexContainer = 'ad-backup-index'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_GZRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: true
    changeFeed: {
      enabled: true
      retentionInDays: 365
    }
    deleteRetentionPolicy: {
      enabled: true
      days: hotRetentionDays
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: hotRetentionDays
    }
  }
}

resource backups 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobServices
  name: backupContainer
  properties: {
    publicAccess: 'None'
    immutableStorageWithVersioning: {
      enabled: true
    }
  }
}

resource backupsImmutability 'Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies@2023-05-01' = {
  parent: backups
  name: 'default'
  properties: {
    immutabilityPeriodSinceCreationInDays: immutabilityDays
    allowProtectedAppendWrites: true
  }
}

resource indexes 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobServices
  name: indexContainer
  properties: {
    publicAccess: 'None'
  }
}

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 365
  }
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    sku: {
      family: 'A'
      name: 'standard'
    }
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource encryptionKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: vault
  name: 'ad-backup-encryption-key'
  properties: {
    kty: 'RSA'
    keySize: 4096
    keyOps: [
      'wrapKey'
      'unwrapKey'
      'encrypt'
      'decrypt'
    ]
    attributes: {
      enabled: true
    }
  }
}

resource automation 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: false
  }
}

resource backupSchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automation
  name: 'daily-ad-backup'
  properties: {
    description: 'Triggers a full AD snapshot every day at 02:00 UTC.'
    startTime: '2026-01-01T02:00:00Z'
    frequency: 'Day'
    interval: 1
    timeZone: 'UTC'
  }
}

// Role assignments. Built-in role IDs are well-known constants.
var storageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var keyVaultCryptoUser = '12338af0-0e69-4776-bea7-57ae8d297424'
var keyVaultAdmin = '00482a5a-887f-4fb3-b363-3b7fe8e74483'

resource automationStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, automation.id, storageBlobDataContributor)
  properties: {
    principalId: automation.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalType: 'ServicePrincipal'
  }
}

resource automationKeyRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, automation.id, keyVaultCryptoUser)
  properties: {
    principalId: automation.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultCryptoUser)
    principalType: 'ServicePrincipal'
  }
}

resource adminVaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, keyVaultAdminObjectId, keyVaultAdmin)
  properties: {
    principalId: keyVaultAdminObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultAdmin)
    principalType: 'User'
  }
}

output storageAccountName string = storage.name
output backupContainerName string = backupContainer
output indexContainerName string = indexContainer
output keyVaultName string = vault.name
output encryptionKeyName string = encryptionKey.name
output automationAccountName string = automation.name
output automationPrincipalId string = automation.identity.principalId
output logAnalyticsWorkspaceId string = law.id
