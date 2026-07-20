resource "azurerm_sentinel_alert_rule_scheduled" "auth_failures" {
  count                      = var.enable_analytics_rules ? 1 : 0
  name                       = "openziti-auth-failure-spike-${local.suffix}"
  log_analytics_workspace_id = local.workspace_id
  display_name               = "OpenZiti authentication failure spike"
  severity                   = "Medium"
  query_frequency            = "PT15M"
  query_period               = "PT1H"
  trigger_operator           = "GreaterThan"
  trigger_threshold          = 5
  tactics                    = ["CredentialAccess"]
  query                      = <<-KQL
    OpenZitiEvents_CL
    | where Namespace == "authentication" and EventType in ("fail", "failed")
    | summarize Failures = count() by IdentityId, bin(TimeGenerated, 5m)
    | where Failures > 5
  KQL

  # Preserve onboarding-before-rules ordering in the create_workspace = true path;
  # a no-op when create_workspace = false (onboarding count 0, external workspace
  # is already Sentinel-onboarded).
  # The table must exist AND be query-resolvable before Sentinel will validate
  # the rule KQL; without this the rules race the table and 400 with "one of the
  # tables does not exist". The deploy.sh retry loop covers the residual
  # query-propagation lag after the table is created.
  depends_on = [
    azurerm_sentinel_log_analytics_workspace_onboarding.this,
    azapi_resource.table,
  ]
}

resource "azurerm_sentinel_alert_rule_scheduled" "entity_change" {
  count                      = var.enable_analytics_rules ? 1 : 0
  name                       = "openziti-config-change-${local.suffix}"
  log_analytics_workspace_id = local.workspace_id
  display_name               = "OpenZiti policy/service configuration change"
  severity                   = "Low"
  query_frequency            = "PT15M"
  query_period               = "PT1H"
  trigger_operator           = "GreaterThan"
  trigger_threshold          = 0
  tactics                    = ["Persistence"]
  query                      = <<-KQL
    OpenZitiEvents_CL
    | where Namespace == "entityChange"
    | where EntityType in ("services", "service-policies", "edge-router-policies", "identities")
    | project TimeGenerated, EventType, EntityType, IdentityId, RawData
  KQL

  # The table must exist AND be query-resolvable before Sentinel will validate
  # the rule KQL; without this the rules race the table and 400 with "one of the
  # tables does not exist". The deploy.sh retry loop covers the residual
  # query-propagation lag after the table is created.
  depends_on = [
    azurerm_sentinel_log_analytics_workspace_onboarding.this,
    azapi_resource.table,
  ]
}

resource "random_uuid" "workbook" {}

resource "azurerm_application_insights_workbook" "ziti" {
  name                = random_uuid.workbook.result
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  display_name        = "OpenZiti telemetry"
  source_id           = lower(local.workspace_id)
  category            = "sentinel"
  tags                = local.tags

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        content = {
          json = "## OpenZiti -> Sentinel\nEvents landing in OpenZitiEvents_CL."
        }
      },
      {
        type = 3
        content = {
          version = "KqlItem/1.0"
          query   = "OpenZitiEvents_CL | summarize count() by Namespace, bin(TimeGenerated, 5m) | render timechart"
          size    = 0
          title   = "Event volume by namespace"
        }
      },
      {
        type = 3
        content = {
          version = "KqlItem/1.0"
          query   = "OpenZitiEvents_CL | where Namespace == 'authentication' | summarize count() by EventType | render piechart"
          size    = 0
          title   = "Authentication success vs failure"
        }
      },
      {
        type = 3
        content = {
          version = "KqlItem/1.0"
          query   = "OpenZitiEvents_CL | where Namespace == 'entityChange' | summarize count() by EntityType"
          size    = 0
          title   = "Config changes by entity type"
        }
      }
    ]
    "$schema" = "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
  })
}
