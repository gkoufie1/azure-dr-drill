output "listener" {
  description = "Read-write listener: the connection string host that never changes across failovers"
  value       = "${azurerm_mssql_failover_group.fog.name}.database.windows.net"
}

output "primary_server" {
  value = azurerm_mssql_server.primary.name
}

output "secondary_server" {
  value = azurerm_mssql_server.secondary.name
}

output "failover_group" {
  value = azurerm_mssql_failover_group.fog.name
}
