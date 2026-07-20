resource "azurerm_resource_group" "this" {
  name     = local.rg_name
  location = local.location
  tags     = local.tags
}
