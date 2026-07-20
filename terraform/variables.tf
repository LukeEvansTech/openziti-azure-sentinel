variable "subscription_id" {
  type        = string
  description = "Target Azure subscription ID."
}

variable "location" {
  type        = string
  description = "Azure region."
  default     = "uksouth"
}

variable "prefix" {
  type        = string
  description = "Short name prefix for resources (dash-style)."
  default     = "ozsent"
}

variable "resource_provider_registrations" {
  type        = string
  description = "azurerm resource-provider registration mode. \"extended\" (default) covers the providers this deployment uses, except Microsoft.Consumption (optional budget alert; normally pre-registered). Use \"none\" on governed subscriptions with pre-registered providers - the full list is in docs/troubleshooting.md."
  default     = "extended"
}

variable "deploy_demo_controller" {
  type        = bool
  description = "Deploy a self-contained OpenZiti demo controller on Azure Container Instances (plus an event-generator sidecar) wired to the pipeline. Set false in production and point your own controller's Service Bus event sink at the queue instead."
  default     = true
}

variable "create_workspace" {
  type        = bool
  description = "Create a Log Analytics workspace + Sentinel. Set false to target an existing central workspace via workspace_resource_id."
  default     = true
}

variable "workspace_resource_id" {
  type        = string
  description = "Existing Log Analytics workspace resource ID to target when create_workspace = false."
  default     = ""
}

variable "enable_analytics_rules" {
  type        = bool
  description = "Deploy the two Sentinel scheduled analytics rules. Requires the target workspace to be Sentinel-onboarded (always true when create_workspace = true; set true when pointing at an already-onboarded central workspace)."
  default     = true
}

variable "retention_in_days" {
  type        = number
  description = "Workspace retention (PerGB2018 floor is 30). Moot at teardown."
  default     = 30
}

variable "budget_amount" {
  type        = number
  description = "Monthly resource-group budget amount (in your billing currency) for the alert. 0 disables the budget."
  default     = 20
}

variable "budget_start_date" {
  type        = string
  description = "Optional override for the budget start date (first of a month). Empty = derive the first of the current month."
  default     = ""
}

variable "budget_contact_email" {
  type        = string
  description = "Email for the budget alert. Empty disables notifications."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged over the defaults."
  default     = {}
}
