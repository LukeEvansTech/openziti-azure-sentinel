output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "servicebus_namespace_name" {
  value = azurerm_servicebus_namespace.this.name
}

output "servicebus_namespace_fqdn" {
  value = "${azurerm_servicebus_namespace.this.name}.servicebus.windows.net"
}

output "queue_name" {
  value = local.queue_name
}

output "servicebus_send_connection_string" {
  value     = azurerm_servicebus_namespace_authorization_rule.ziti_send.primary_connection_string
  sensitive = true
}

output "workspace_id" {
  value = local.workspace_id
}

output "workspace_name" {
  value = var.create_workspace ? azurerm_log_analytics_workspace.this[0].name : ""
}

output "dce_logs_ingestion_endpoint" {
  value = azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint
}

output "dcr_immutable_id" {
  value = azurerm_monitor_data_collection_rule.this.immutable_id
}

output "stream_name" {
  value = local.stream_name
}

output "function_app_name" {
  value = azurerm_linux_function_app.fn.name
}

output "controller_fqdn" {
  value = var.deploy_demo_controller ? azurerm_container_group.ziti[0].fqdn : ""
}

output "controller_admin_password" {
  value     = var.deploy_demo_controller ? random_password.ziti[0].result : ""
  sensitive = true
}
