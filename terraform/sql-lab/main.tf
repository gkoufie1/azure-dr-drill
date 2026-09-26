data "azurerm_resource_group" "primary" {
  name = var.primary_rg_name
}

data "azurerm_resource_group" "secondary" {
  name = var.secondary_rg_name
}

# SQL server and failover group names are globally unique across Azure
# (<name>.database.windows.net), so they get a random suffix.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# The admin password is generated here and never printed or committed. It lives
# in local Terraform state (gitignored) and in .sql-admin-password (gitignored)
# so the writer script can read it.
resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "-_.~"
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
}

resource "local_sensitive_file" "admin_password" {
  content  = random_password.admin.result
  filename = "${path.module}/.sql-admin-password"
}

resource "azurerm_mssql_server" "primary" {
  name                         = "sql-drdrill-w-${random_string.suffix.result}"
  resource_group_name          = data.azurerm_resource_group.primary.name
  location                     = var.primary_location
  version                      = "12.0"
  administrator_login          = var.admin_username
  administrator_login_password = random_password.admin.result
  minimum_tls_version          = "1.2"
  tags                         = var.tags
}

resource "azurerm_mssql_server" "secondary" {
  name                         = "sql-drdrill-c-${random_string.suffix.result}"
  resource_group_name          = data.azurerm_resource_group.secondary.name
  location                     = var.secondary_location
  version                      = "12.0"
  administrator_login          = var.admin_username
  administrator_login_password = random_password.admin.result
  minimum_tls_version          = "1.2"
  tags                         = var.tags
}

# Both servers accept the writer's IP so it can keep connecting after roles swap.
resource "azurerm_mssql_firewall_rule" "client_primary" {
  name             = "drill-client"
  server_id        = azurerm_mssql_server.primary.id
  start_ip_address = var.client_ip
  end_ip_address   = var.client_ip
}

resource "azurerm_mssql_firewall_rule" "client_secondary" {
  name             = "drill-client"
  server_id        = azurerm_mssql_server.secondary.id
  start_ip_address = var.client_ip
  end_ip_address   = var.client_ip
}

resource "azurerm_mssql_database" "db" {
  name        = var.database_name
  server_id   = azurerm_mssql_server.primary.id
  sku_name    = var.database_sku
  max_size_gb = 2

  # Local redundancy is enough for a same-day lab; cross-region protection is
  # what the failover group provides.
  storage_account_type = "Local"
  tags                 = var.tags
}

# The failover group creates the geo-secondary database itself, with the same
# tier as the primary. That secondary is therefore NOT in Terraform state, and
# teardown has to remove the replication link by hand (see the runbook).
resource "azurerm_mssql_failover_group" "fog" {
  name      = "fog-drdrill-${random_string.suffix.result}"
  server_id = azurerm_mssql_server.primary.id
  databases = [azurerm_mssql_database.db.id]

  partner_server {
    id = azurerm_mssql_server.secondary.id
  }

  # Customer-managed ("Manual"): Microsoft's recommendation, and the only policy
  # that lets a drill choose when to fail over.
  read_write_endpoint_failover_policy {
    mode = "Manual"
  }

  tags = var.tags
}
