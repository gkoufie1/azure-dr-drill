output "vault_name" {
  value = azurerm_recovery_services_vault.vault.name
}

output "vault_resource_group" {
  value = data.azurerm_resource_group.target.name
}

output "replicated_vms" {
  value = { for k, v in azurerm_site_recovery_replicated_vm.vm : k => v.name }
}

output "source_vm_ids" {
  value = { for k, v in azurerm_linux_virtual_machine.vm : k => v.id }
}
