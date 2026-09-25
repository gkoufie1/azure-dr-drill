# The Recovery Services vault lives in the TARGET region (Central US) — that's
# where ASR expects it, so that it survives a failure of the source region.
resource "azurerm_recovery_services_vault" "vault" {
  name                = "rsv-${var.prefix}-target"
  location            = var.target_location
  resource_group_name = data.azurerm_resource_group.target.name
  sku                 = "Standard"
  tags                = var.tags

  # Soft delete stays on: the provider rejects `soft_delete_enabled = false`
  # ("a required security feature and cannot be disabled" — Azure's
  # secure-by-default policy). An earlier draft of this file tried to turn
  # it off to make teardown easier; that was wrong, and this is the
  # correction. It only affects Azure Backup items, not ASR replicated
  # items, so ASR-only teardown should still be clean — but if the
  # backup/restore add-on gets built, deleted backup data lingers in the
  # vault for the soft-delete retention window and the vault can't be
  # destroyed until that's purged.
  storage_mode_type = "LocallyRedundant"
}

resource "azurerm_site_recovery_fabric" "primary" {
  name                = "fabric-primary"
  resource_group_name = data.azurerm_resource_group.target.name
  recovery_vault_name = azurerm_recovery_services_vault.vault.name
  location            = var.source_location
}

resource "azurerm_site_recovery_fabric" "secondary" {
  name                = "fabric-secondary"
  resource_group_name = data.azurerm_resource_group.target.name
  recovery_vault_name = azurerm_recovery_services_vault.vault.name
  location            = var.target_location
  depends_on          = [azurerm_site_recovery_fabric.primary]
}

resource "azurerm_site_recovery_protection_container" "primary" {
  name                 = "container-primary"
  resource_group_name  = data.azurerm_resource_group.target.name
  recovery_vault_name  = azurerm_recovery_services_vault.vault.name
  recovery_fabric_name = azurerm_site_recovery_fabric.primary.name
}

resource "azurerm_site_recovery_protection_container" "secondary" {
  name                 = "container-secondary"
  resource_group_name  = data.azurerm_resource_group.target.name
  recovery_vault_name  = azurerm_recovery_services_vault.vault.name
  recovery_fabric_name = azurerm_site_recovery_fabric.secondary.name
}

# 24h of recovery points, app-consistent snapshot every 4h. These are also
# the numbers that bound the RPO this lab can honestly claim.
resource "azurerm_site_recovery_replication_policy" "policy" {
  name                                                 = "policy-24h-retention"
  resource_group_name                                  = data.azurerm_resource_group.target.name
  recovery_vault_name                                  = azurerm_recovery_services_vault.vault.name
  recovery_point_retention_in_minutes                  = 24 * 60
  application_consistent_snapshot_frequency_in_minutes = 4 * 60
}

resource "azurerm_site_recovery_protection_container_mapping" "mapping" {
  name                                      = "container-mapping"
  resource_group_name                       = data.azurerm_resource_group.target.name
  recovery_vault_name                       = azurerm_recovery_services_vault.vault.name
  recovery_fabric_name                      = azurerm_site_recovery_fabric.primary.name
  recovery_source_protection_container_name = azurerm_site_recovery_protection_container.primary.name
  recovery_target_protection_container_id   = azurerm_site_recovery_protection_container.secondary.id
  recovery_replication_policy_id            = azurerm_site_recovery_replication_policy.policy.id
}

resource "azurerm_site_recovery_network_mapping" "mapping" {
  name                        = "network-mapping"
  resource_group_name         = data.azurerm_resource_group.target.name
  recovery_vault_name         = azurerm_recovery_services_vault.vault.name
  source_recovery_fabric_name = azurerm_site_recovery_fabric.primary.name
  target_recovery_fabric_name = azurerm_site_recovery_fabric.secondary.name
  source_network_id           = azurerm_virtual_network.source.id
  target_network_id           = azurerm_virtual_network.target.id
}

# ASR stages replication data through a cache storage account in the SOURCE
# region. Name is globally unique; derived from the subscription ID so it's
# stable across applies without needing a random provider.
resource "azurerm_storage_account" "cache" {
  name                     = "st${var.prefix}${substr(replace(var.subscription_id, "-", ""), 0, 10)}"
  location                 = var.source_location
  resource_group_name      = data.azurerm_resource_group.source.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = var.tags
}

resource "azurerm_site_recovery_replicated_vm" "vm" {
  for_each = var.vm_names

  name                                      = "replication-${var.prefix}-${each.key}"
  resource_group_name                       = data.azurerm_resource_group.target.name
  recovery_vault_name                       = azurerm_recovery_services_vault.vault.name
  source_recovery_fabric_name               = azurerm_site_recovery_fabric.primary.name
  source_vm_id                              = azurerm_linux_virtual_machine.vm[each.key].id
  recovery_replication_policy_id            = azurerm_site_recovery_replication_policy.policy.id
  source_recovery_protection_container_name = azurerm_site_recovery_protection_container.primary.name

  target_resource_group_id                = data.azurerm_resource_group.target.id
  target_recovery_fabric_id               = azurerm_site_recovery_fabric.secondary.id
  target_recovery_protection_container_id = azurerm_site_recovery_protection_container.secondary.id

  managed_disk {
    disk_id                    = data.azurerm_managed_disk.os[each.key].id
    staging_storage_account_id = azurerm_storage_account.cache.id
    target_resource_group_id   = data.azurerm_resource_group.target.id
    target_disk_type           = "StandardSSD_LRS"
    target_replica_disk_type   = "StandardSSD_LRS"
  }

  network_interface {
    source_network_interface_id = azurerm_network_interface.vm[each.key].id
    target_subnet_name          = azurerm_subnet.target.name
  }

  depends_on = [
    azurerm_site_recovery_protection_container_mapping.mapping,
    azurerm_site_recovery_network_mapping.mapping,
  ]
}
