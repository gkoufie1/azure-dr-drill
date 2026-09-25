data "azurerm_resource_group" "source" {
  name = var.source_rg_name
}

data "azurerm_resource_group" "target" {
  name = var.target_rg_name
}

# ── SOURCE NETWORK (West US) ─────────────────────────────────────
resource "azurerm_virtual_network" "source" {
  name                = "vnet-${var.prefix}-source"
  location            = var.source_location
  resource_group_name = data.azurerm_resource_group.source.name
  address_space       = ["10.10.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "source" {
  name                 = "snet-app"
  resource_group_name  = data.azurerm_resource_group.source.name
  virtual_network_name = azurerm_virtual_network.source.name
  address_prefixes     = ["10.10.1.0/24"]
}

# No custom rules: the default rules deny all inbound traffic from the
# internet. Nothing in this lab needs to be reachable from outside.
resource "azurerm_network_security_group" "source" {
  name                = "nsg-${var.prefix}-source"
  location            = var.source_location
  resource_group_name = data.azurerm_resource_group.source.name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "source" {
  subnet_id                 = azurerm_subnet.source.id
  network_security_group_id = azurerm_network_security_group.source.id
}

# ── TARGET NETWORK (Central US) ──────────────────────────────────
# Non-overlapping address space on purpose: it's what a real DR network
# looks like, and it keeps a later peering or VPN option open.
resource "azurerm_virtual_network" "target" {
  name                = "vnet-${var.prefix}-target"
  location            = var.target_location
  resource_group_name = data.azurerm_resource_group.target.name
  address_space       = ["10.20.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "target" {
  name                 = "snet-app"
  resource_group_name  = data.azurerm_resource_group.target.name
  virtual_network_name = azurerm_virtual_network.target.name
  address_prefixes     = ["10.20.1.0/24"]
}

resource "azurerm_network_security_group" "target" {
  name                = "nsg-${var.prefix}-target"
  location            = var.target_location
  resource_group_name = data.azurerm_resource_group.target.name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "target" {
  subnet_id                 = azurerm_subnet.target.id
  network_security_group_id = azurerm_network_security_group.target.id
}
