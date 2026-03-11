output "resource_group_name" {
  description = "Resource group containing all resources."
  value       = azurerm_resource_group.main.name
}

output "frontdoor_url" {
  description = "Public URL for the application (Azure Front Door default domain)."
  value       = "https://${azurerm_cdn_frontdoor_endpoint.main.host_name}"
}

output "primary_web_app_name" {
  description = "Primary regional web app name."
  value       = azurerm_linux_web_app.primary.name
}

output "secondary_web_app_name" {
  description = "Secondary regional web app name."
  value       = azurerm_linux_web_app.secondary.name
}

output "sql_failover_group_listener" {
  description = "Failover group DNS listener used by the app."
  value       = local.failover_group_fqdn
}

output "sql_failover_group_name" {
  description = "Failover group resource name."
  value       = azurerm_mssql_failover_group.quotes.name
}

output "primary_sql_server_name" {
  description = "Primary SQL server name."
  value       = azurerm_mssql_server.primary.name
}

output "secondary_sql_server_name" {
  description = "Secondary SQL server name."
  value       = azurerm_mssql_server.secondary.name
}

output "key_vault_name" {
  description = "Key Vault name."
  value       = azurerm_key_vault.main.name
}

output "frontdoor_private_link_approval_note" {
  description = "Front Door private links to App Service origins are created in Pending state and must be approved."
  value       = "Run scripts/approve_frontdoor_private_link.sh after terraform apply to approve origin private endpoint connections."
}
