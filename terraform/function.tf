resource "azurerm_storage_account" "fn" {
  name                     = local.storage_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  # The Functions runtime storage (AzureWebJobsStorage) uses a keyed connection
  # string, so shared keys must be enabled. Keyless host storage is a known
  # hardening gap of the Consumption-plan runtime.
  shared_access_key_enabled       = true
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  tags                            = local.tags
}

resource "azurerm_service_plan" "fn" {
  name                = "asp-${var.prefix}-${var.location}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  os_type             = "Linux"
  sku_name            = "Y1"
  tags                = local.tags
}

resource "azurerm_linux_function_app" "fn" {
  name                = "func-${var.prefix}-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  service_plan_id     = azurerm_service_plan.fn.id

  storage_account_name       = azurerm_storage_account.fn.name
  storage_account_access_key = azurerm_storage_account.fn.primary_access_key

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.12"
    }
    application_insights_connection_string = azurerm_application_insights.this.connection_string
  }

  app_settings = {
    # Service Bus trigger via a Listen connection string. The Consumption scale
    # controller cannot peek the queue with a managed identity, so a connection
    # string is required for scale-from-zero to work.
    "ServiceBusConnection"  = azurerm_servicebus_namespace_authorization_rule.func_listen.primary_connection_string
    "LOGS_DCE_ENDPOINT"     = azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint
    "LOGS_DCR_IMMUTABLE_ID" = azurerm_monitor_data_collection_rule.this.immutable_id
    "LOGS_STREAM_NAME"      = local.stream_name
  }

  tags = local.tags
}

# The Function forwards to the Logs Ingestion API using its managed identity,
# so it needs Monitoring Metrics Publisher on the DCR (Function -> DCR stays MI).
resource "azurerm_role_assignment" "fn_dcr_publish" {
  scope                = azurerm_monitor_data_collection_rule.this.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_linux_function_app.fn.identity[0].principal_id
}
