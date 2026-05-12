param location string = resourceGroup().location
param appName string = 'order-api-demo'
param acrName string = 'acr${uniqueString(resourceGroup().id)}'
param keyVaultName string = 'kv-${uniqueString(resourceGroup().id)}'
param containerImageName string = 'order-api-demo'
param containerImageTag string = '1.2.0'
param useAcrImage bool = false

// ---------- Container Registry ----------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

// ---------- Managed Identity ----------
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${appName}-identity'
  location: location
}

// AcrPull role assignment so the Container App can pull images
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identity.id, acrPullRoleId)
  scope: acr
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
}

// ---------- Monitoring ----------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${appName}-logs'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${appName}-ai'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ---------- Container App Environment ----------
resource containerAppEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${appName}-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// ---------- Container App ----------
resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      registries: [
        {
          server: acr.properties.loginServer
          identity: identity.id
        }
      ]
      ingress: {
        external: true
        targetPort: 8080
      }
    }
    template: {
      containers: [
        {
          name: appName
          image: useAcrImage ? '${acr.properties.loginServer}/${containerImageName}:${containerImageTag}' : 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
  dependsOn: [
    acrPullRole
  ]
}

// ---------- Outputs ----------
output appUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
output appInsightsName string = appInsights.name
output appInsightsId string = appInsights.id
output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
output keyVaultName string = keyVault.name

// ---------- Key Vault with Near-Expiry Cert (Demo 4) ----------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// Key Vault Reader role so the SRE Agent can list and inspect certificates
// Role: Key Vault Reader (21090545-7ca7-4776-b22c-e363652d74d2)
param sreAgentPrincipalId string = ''
var keyVaultReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '21090545-7ca7-4776-b22c-e363652d74d2')

resource keyVaultReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(sreAgentPrincipalId)) {
  name: guid(keyVault.id, sreAgentPrincipalId, keyVaultReaderRoleId)
  scope: keyVault
  properties: {
    principalId: sreAgentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultReaderRoleId
  }
}

// Self-signed cert — created via CLI, not Bicep.
// The Key Vault certificates API doesn't work reliably with ARM deployments
// (returns NotFound even when the vault exists). Create manually:
//   az keyvault certificate create --vault-name <kv> -n order-api-tls --policy @cert-policy.json
// ⚠️ For the demo, the cert is created with 1-month validity (~30 days).
// The DailySecurityScan flags anything within 30 days, so it will be caught
// immediately after creation. No need to manually recreate.
// Check: az keyvault certificate show --vault-name <kv> -n order-api-tls --query 'attributes.expires'

// ---------- Alert Rule for Incident Trigger ----------
resource errorAlertRule 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${appName}-500-errors'
  location: 'global'
  properties: {
    description: 'Fires when the order-api container app returns HTTP 500 errors. Used by SRE Agent incident trigger.'
    severity: 2
    enabled: true
    scopes: [
      containerApp.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'High5xxRate'
          metricName: 'Requests'
          metricNamespace: 'Microsoft.App/containerApps'
          operator: 'GreaterThan'
          threshold: 5
          timeAggregation: 'Total'
          dimensions: [
            {
              name: 'statusCodeCategory'
              operator: 'Include'
              values: [ '5xx' ]
            }
          ]
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: []
  }
}

// ---------- Latency Alert Rule for Incident Trigger (Act 4) ----------
// Log-based alert using App Insights request duration data.
// Fires when average response time exceeds 3 seconds in a 5-minute window.
resource latencyAlertRule 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${appName}-high-latency'
  location: location
  properties: {
    description: 'Fires when average response time exceeds 3 seconds. Used by SRE Agent incident trigger for latency incidents.'
    severity: 2
    enabled: true
    scopes: [
      appInsights.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'requests | where duration > 3000'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 3
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {}
  }
}
