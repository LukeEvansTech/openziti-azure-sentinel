resource "azurerm_log_analytics_workspace" "this" {
  count               = var.create_workspace ? 1 : 0
  name                = "law-${var.prefix}-${var.location}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_in_days
  tags                = local.tags
}

locals {
  workspace_id = var.create_workspace ? azurerm_log_analytics_workspace.this[0].id : var.workspace_resource_id
}

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "this" {
  count                        = var.create_workspace ? 1 : 0
  workspace_id                 = local.workspace_id
  customer_managed_key_enabled = false
}

# Custom table - azurerm cannot create custom tables, so use azapi.
resource "azapi_resource" "table" {
  type                      = "Microsoft.OperationalInsights/workspaces/tables@2023-09-01"
  name                      = local.table_name
  parent_id                 = local.workspace_id
  schema_validation_enabled = false

  body = {
    properties = {
      totalRetentionInDays = var.retention_in_days
      plan                 = "Analytics"
      schema = {
        name = local.table_name
        columns = [
          { name = "TimeGenerated", type = "dateTime" },
          { name = "Namespace", type = "string" },
          { name = "EventType", type = "string" },
          { name = "EventSrcId", type = "string" },
          { name = "IdentityId", type = "string" },
          { name = "ServiceId", type = "string" },
          { name = "EntityType", type = "string" },
          { name = "Success", type = "boolean" },
          { name = "RawData", type = "dynamic" }
        ]
      }
    }
  }
}

resource "azurerm_monitor_data_collection_endpoint" "this" {
  name                          = "dce-${var.prefix}-${var.location}"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  kind                          = "Linux"
  public_network_access_enabled = true
  tags                          = local.tags
}

resource "azurerm_monitor_data_collection_rule" "this" {
  name                        = "dcr-${var.prefix}-${var.location}"
  resource_group_name         = azurerm_resource_group.this.name
  location                    = azurerm_resource_group.this.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.this.id
  tags                        = local.tags

  destinations {
    log_analytics {
      name                  = "central-la"
      workspace_resource_id = local.workspace_id
    }
  }

  stream_declaration {
    stream_name = local.stream_name
    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "RawData"
      type = "dynamic"
    }
  }

  data_flow {
    streams       = [local.stream_name]
    destinations  = ["central-la"]
    output_stream = local.stream_name
    transform_kql = <<-KQL
      source
      | extend TimeGenerated = todatetime(RawData.timestamp)
      | extend Namespace  = tostring(RawData.namespace)
      | extend EventType  = iif(isnotempty(tostring(RawData.event_type)), tostring(RawData.event_type), tostring(RawData.eventType))
      | extend EventSrcId = tostring(RawData.event_src_id)
      | extend IdentityId = tostring(RawData.identity_id)
      | extend ServiceId  = tostring(RawData.service_id)
      | extend EntityType = tostring(RawData.entityType)
      | extend Success    = tobool(RawData.success)
      | project TimeGenerated, Namespace, EventType, EventSrcId, IdentityId, ServiceId, EntityType, Success, RawData
    KQL
  }

  depends_on = [azapi_resource.table]
}
