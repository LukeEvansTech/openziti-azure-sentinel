provider "azurerm" {
  subscription_id                 = var.subscription_id
  resource_provider_registrations = var.resource_provider_registrations
  storage_use_azuread             = true
  features {
    log_analytics_workspace {
      permanently_delete_on_destroy = true # no 14-day soft-delete shadow
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
}
