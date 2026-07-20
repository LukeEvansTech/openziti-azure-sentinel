resource "azurerm_consumption_budget_resource_group" "this" {
  count             = var.budget_amount > 0 && var.budget_contact_email != "" ? 1 : 0
  name              = "budget-${var.prefix}"
  resource_group_id = azurerm_resource_group.this.id
  amount            = var.budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = local.budget_start_date
  }

  dynamic "notification" {
    for_each = var.budget_contact_email == "" ? [] : [80, 100]
    content {
      enabled        = true
      threshold      = notification.value
      operator       = "GreaterThanOrEqualTo"
      contact_emails = [var.budget_contact_email]
    }
  }
}
