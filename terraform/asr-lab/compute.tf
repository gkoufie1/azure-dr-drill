# Explicit outbound path per VM. ASR's agent needs outbound access to Azure
# service endpoints, and Azure is retiring "default outbound access" for new
# virtual networks, so this doesn't rely on it. Inbound stays denied by the
# subnet's NSG — a public IP here is for egress, not exposure.
resource "azurerm_public_ip" "vm" {
  for_each            = var.vm_names
  name                = "pip-${var.prefix}-${each.key}"
  location            = var.source_location
  resource_group_name = data.azurerm_resource_group.source.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "vm" {
  for_each            = var.vm_names
  name                = "nic-${var.prefix}-${each.key}"
  location            = var.source_location
  resource_group_name = data.azurerm_resource_group.source.name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.source.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm[each.key].id
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each              = var.vm_names
  name                  = "vm-${var.prefix}-${each.key}"
  location              = var.source_location
  resource_group_name   = data.azurerm_resource_group.source.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.vm[each.key].id]
  tags                  = var.tags

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  # Explicit disk name so ASR can look the managed disk up by name below.
  os_disk {
    name                 = "osdisk-${var.prefix}-${each.key}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

data "azurerm_managed_disk" "os" {
  for_each            = var.vm_names
  name                = "osdisk-${var.prefix}-${each.key}"
  resource_group_name = data.azurerm_resource_group.source.name
  depends_on          = [azurerm_linux_virtual_machine.vm]
}
