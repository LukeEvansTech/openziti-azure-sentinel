# Workspace-based Application Insights for the Function (execution logs, traces,
# exceptions). Shares the central Log Analytics workspace.
resource "azurerm_application_insights" "this" {
  name                = "appi-${var.prefix}-${var.location}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  application_type    = "web"
  workspace_id        = local.workspace_id
  tags                = local.tags
}
