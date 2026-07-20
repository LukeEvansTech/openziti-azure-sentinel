resource "azurerm_servicebus_namespace" "this" {
  name                = "sb-${var.prefix}-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_servicebus_queue" "events" {
  name         = local.queue_name
  namespace_id = azurerm_servicebus_namespace.this.id
}

# Least-privilege Send-only rule for the OpenZiti controller (sink is SAS-only).
resource "azurerm_servicebus_namespace_authorization_rule" "ziti_send" {
  name         = "ziti-send"
  namespace_id = azurerm_servicebus_namespace.this.id
  listen       = false
  send         = true
  manage       = false
}

# Listen-only rule for the Function's Service Bus trigger. A connection string is
# required because the Consumption scale controller cannot peek the queue via MI.
resource "azurerm_servicebus_namespace_authorization_rule" "func_listen" {
  name         = "func-listen"
  namespace_id = azurerm_servicebus_namespace.this.id
  listen       = true
  send         = false
  manage       = false
}
