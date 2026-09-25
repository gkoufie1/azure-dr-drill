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

  # Ubuntu 24.04, not 22.04, and it matters: the v7 VM sizes use an NVMe disk
  # controller, and ASR only supports NVMe with specific guest OSes —
  # RHEL 9.0-9.7, Ubuntu 24.04 LTS, SLES 15 SP4-SP7 (Microsoft's ASR
  # support matrix, "Linux distributions supported for NVMe"). The first
  # apply used 22.04 and ASR rejected enabling replication with error
  # 151273 ("does not support protection of virtual machines using an NVMe
  # disk controller when the guest operating system is not compatible").
  # Ubuntu 24.04 because the v7 sizes use an NVMe disk controller and ASR
  # only supports NVMe with RHEL 9.x, Ubuntu 24.04 or SLES 15 SP4-SP7
  # (first failure: error 151273 on 22.04).
  #
  # The image version is pinned for reproducibility only. It does NOT fix the
  # kernel problem — a first attempt assumed an older image would ship an
  # older kernel, and even the April 2026 image already runs 6.17. The
  # kernel is fixed by pinned_kernel below.
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = var.ubuntu_image_version
  }

  # Second failure (error 151141): the Mobility service build this vault
  # installs (9.67.7789.1, published 2026-05-04) "doesn't support the
  # operating system kernel version 6.17.0-1022-azure". ASR keeps an exact
  # per-kernel support list per agent build (Azure/Azure-SiteRecovery on
  # GitHub); that build tops out at 6.14.0-1017-azure for Ubuntu 24.04, and
  # the first build listing 6.17.0-1022 is 7893 (2026-08-13). So this boots a
  # supported kernel instead, and switches automatic updates off so the
  # kernel can't drift past what ASR supports mid-lab.
  custom_data = base64encode(<<-EOT
    #cloud-config
    package_update: false
    package_upgrade: false
    write_files:
      - path: /etc/apt/apt.conf.d/20auto-upgrades
        permissions: "0644"
        content: |
          APT::Periodic::Update-Package-Lists "0";
          APT::Periodic::Unattended-Upgrade "0";
      - path: /etc/default/grub.d/99-lab-default.cfg
        permissions: "0644"
        content: |
          GRUB_DEFAULT=saved
    runcmd:
      - systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
      - apt-get update -qq
      - DEBIAN_FRONTEND=noninteractive apt-get install -y linux-image-${var.pinned_kernel}
      - update-grub
      - grub-set-default "Advanced options for Ubuntu>Ubuntu, with Linux ${var.pinned_kernel}"
    power_state:
      mode: reboot
      message: "Rebooting into the ASR-supported kernel"
      condition: true
  EOT
  )

  # The live canary VM got this same kernel pin by hand (run-command) while
  # it was being debugged. Ignoring custom_data here means adding this block
  # doesn't plan a replacement of a VM that ASR is actively protecting.
  # New builds still get it, because custom_data is applied at creation.
  lifecycle {
    ignore_changes = [custom_data]
  }
}

data "azurerm_managed_disk" "os" {
  for_each            = var.vm_names
  name                = "osdisk-${var.prefix}-${each.key}"
  resource_group_name = data.azurerm_resource_group.source.name
  depends_on          = [azurerm_linux_virtual_machine.vm]
}
