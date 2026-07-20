resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  location = var.location
  suffix   = random_string.suffix.result

  rg_name           = "rg-${var.prefix}-${var.location}"
  compact_prefix    = replace(var.prefix, "-", "")
  storage_name      = substr("st${local.compact_prefix}${local.suffix}", 0, 24)
  ziti_storage_name = substr("stziti${local.compact_prefix}${local.suffix}", 0, 24)
  queue_name        = "openziti-events"
  table_name        = "OpenZitiEvents_CL"
  stream_name       = "Custom-OpenZitiEvents_CL"

  budget_start_date = var.budget_start_date != "" ? var.budget_start_date : formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())

  tags = merge({
    project   = "openziti-azure-sentinel"
    managedBy = "terraform"
  }, var.tags)
}
