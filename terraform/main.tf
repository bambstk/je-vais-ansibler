# Référence au Resource Group existant
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

locals {
  prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    project     = var.project_name
    environment = var.environment
    managed_by  = "terraform"
  })
}

# ------------------------------------------------------------------
# Réseau
# ------------------------------------------------------------------

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${local.prefix}"
  address_space       = ["10.42.0.0/16"]
  location            = var.location_vm
  resource_group_name = data.azurerm_resource_group.rg.name
  tags                = local.common_tags
}

resource "azurerm_subnet" "runner" {
  name                 = "snet-runner"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.42.1.0/24"]
}

resource "azurerm_network_security_group" "runner" {
  name                = "nsg-${local.prefix}"
  location            = var.location_vm
  resource_group_name = data.azurerm_resource_group.rg.name
  tags                = local.common_tags
}

resource "azurerm_subnet_network_security_group_association" "runner" {
  subnet_id                 = azurerm_subnet.runner.id
  network_security_group_id = azurerm_network_security_group.runner.id
}

# Règle SSH permanente : uniquement depuis l'IP de l'admin.
# Les règles temporaires ouvertes par le pipeline (TP Partie 3) devront utiliser
# une priorité différente (ex : 200) pour ne pas entrer en conflit.
resource "azurerm_network_security_rule" "ssh_admin" {
  name                        = "AllowSSH-Admin"
  priority                    = 1000
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "${var.allowed_ssh_source_ip}/32"
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.runner.name
}

# ------------------------------------------------------------------
# IP publique + NIC
# ------------------------------------------------------------------

resource "azurerm_public_ip" "runner" {
  name                = "pip-${local.prefix}"
  location            = var.location_vm
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_network_interface" "runner" {
  name                = "nic-${local.prefix}"
  location            = var.location_vm
  resource_group_name = data.azurerm_resource_group.rg.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.runner.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.runner.id
  }
}

# ------------------------------------------------------------------
# Paire de clés SSH générée par Terraform
# ------------------------------------------------------------------

resource "tls_private_key" "runner" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ------------------------------------------------------------------
# VM
# ------------------------------------------------------------------

resource "azurerm_linux_virtual_machine" "runner" {
  name                = "vm-${local.prefix}"
  location            = var.location_vm
  resource_group_name = data.azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = local.common_tags

  network_interface_ids = [azurerm_network_interface.runner.id]

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.runner.public_key_openssh
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    name                 = "osdisk-${local.prefix}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.vm_os_disk_size_gb
  }

  identity {
    type = "SystemAssigned"
  }
}